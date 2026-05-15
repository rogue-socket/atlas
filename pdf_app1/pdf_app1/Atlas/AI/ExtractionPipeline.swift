//
//  ExtractionPipeline.swift
//  Atlas
//
//  End-to-end pipeline: PDF pages -> concepts -> graph nodes
//  Orchestrates TextExtractor -> LayoutAnalyzer -> AI extraction -> graph integration
//

import Foundation
import PDFKit
import Observation
import os.log

private let log = AtlasLogger.pipeline

@Observable
class ExtractionPipeline {
    var isProcessing: Bool = false
    var currentPage: Int = 0
    var totalPages: Int = 0
    var statusMessage: String = ""
    var scannedPDFDetected: Bool = false
    var extractionMode: ExtractionMode = .fast

    var progress: Double {
        guard totalPages > 0 else { return 0 }
        return Double(currentPage) / Double(totalPages)
    }

    private var processingTask: Task<Void, Never>?
    private let textExtractor = TextExtractor()
    private let layoutAnalyzer = LayoutAnalyzer()
    private let deepPipeline = DeepExtractionPipeline()
    private let batchSize = 5

    func cancel() {
        log.info("[Pipeline] cancel() called, isProcessing=\(self.isProcessing)")
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
    }

    // MARK: - Progressive Extraction

    func processPages(
        document: PDFDocument,
        documentURL: URL,
        pageRange: Range<Int>,
        graph: KnowledgeGraph,
        aiService: AIServiceManager,
        projectID: UUID? = nil,
        mode: ExtractionMode = .fast
    ) async {
        log.info("=== Starting extraction for \(documentURL.lastPathComponent), pages \(pageRange.lowerBound+1)-\(pageRange.upperBound) ===")

        guard let backend = aiService.createBackend() else {
            log.error("No AI backend configured (type=\(aiService.selectedBackendType.rawValue), model=\(aiService.selectedModel))")
            statusMessage = "AI backend not configured"
            isProcessing = false
            return
        }

        log.info("Using backend: \(backend.displayName) / \(backend.modelIdentifier)")

        if mode == .deep {
            statusMessage = "Deep extraction: extracting text..."
            log.info("Using Deep mode (3-pass pipeline)")

            let chunks = extractTextChunks(
                document: document,
                documentURL: documentURL,
                pageRange: pageRange
            )

            await deepPipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: documentURL)

            // Same 4-level fold construction as the fast pipeline:
            // chapters → concept-to-chapter attachment → Document node.
            statusMessage = "Identifying chapters..."
            await ChapterExtraction.extract(
                document: document,
                documentURL: documentURL,
                graph: graph,
                backend: backend,
                textExtractor: textExtractor,
                layoutAnalyzer: layoutAnalyzer
            )
            ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: documentURL)
            statusMessage = "Generating document summary..."
            await Self.appendDocumentSummary(graph: graph, documentURL: documentURL, backend: backend)

            statusMessage = deepPipeline.statusMessage
            isProcessing = false
            graph.documentProcessingState[documentURL] = .complete
            GraphStore.shared.scheduleSave(graph, for: documentURL)
            return
        }

        totalPages = pageRange.count

        var existingLabels = graph.allNodes.map { $0.label }
        let outlineEntries = layoutAnalyzer.extractOutline(from: document)
        let outlineHints = outlineEntries.map { $0.title }
        log.info("Outline entries: \(outlineEntries.count), existing concepts: \(existingLabels.count)")

        var pageIndex = pageRange.lowerBound
        var batchNumber = 0
        while pageIndex < pageRange.upperBound {
            // Check for cancellation before each batch
            if Task.isCancelled {
                log.info("Extraction cancelled by user after \(batchNumber) batches")
                statusMessage = "Cancelled — \(graph.nodeCount) concepts extracted"
                break
            }

            let batchEnd = min(pageIndex + batchSize, pageRange.upperBound)
            let batchRange = pageIndex..<batchEnd
            batchNumber += 1

            currentPage = pageIndex
            statusMessage = "Analyzing pages \(batchRange.lowerBound + 1)-\(batchEnd) of \(pageRange.upperBound)..."
            log.info("--- Batch \(batchNumber): pages \(batchRange.lowerBound+1)-\(batchEnd) ---")

            do {
                try await processBatch(
                    document: document,
                    documentURL: documentURL,
                    pageRange: batchRange,
                    graph: graph,
                    backend: backend,
                    existingLabels: existingLabels,
                    outlineHints: outlineHints,
                    projectID: projectID
                )
                // Update existing labels for next batch so the LLM doesn't re-extract
                existingLabels = graph.allNodes.map { $0.label }
                log.info("Batch \(batchNumber) done. Graph now has \(graph.nodeCount) nodes, \(graph.edgeCount) edges")
            } catch is CancellationError {
                log.info("Extraction cancelled during batch \(batchNumber)")
                statusMessage = "Cancelled — \(graph.nodeCount) concepts extracted"
                break
            } catch {
                log.error("Batch \(batchNumber) FAILED: \(error.localizedDescription)")
                statusMessage = "Error: \(error.localizedDescription)"
                break
            }

            pageIndex = batchEnd
        }

        if Task.isCancelled {
            isProcessing = false
            graph.documentProcessingState[documentURL] = .unprocessed
            log.info("=== Extraction cancelled for \(documentURL.lastPathComponent) ===")
            return
        }

        // Chapter extraction (PDF outline if present, else LLM).
        statusMessage = "Identifying chapters..."
        await ChapterExtraction.extract(
            document: document,
            documentURL: documentURL,
            graph: graph,
            backend: backend,
            textExtractor: textExtractor,
            layoutAnalyzer: layoutAnalyzer
        )

        // Attach concepts to their containing chapter(s) by page-range overlap.
        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: documentURL)

        // Final step: create the Document node (top fold) and link it to
        // its chapters via containsChapter edges.
        statusMessage = "Generating document summary..."
        await Self.appendDocumentSummary(graph: graph, documentURL: documentURL, backend: backend)

        isProcessing = false
        statusMessage = "Done — \(graph.nodeCount) concepts extracted"
        graph.documentProcessingState[documentURL] = .complete
        log.info("=== Extraction complete: \(graph.nodeCount) nodes, \(graph.edgeCount) edges ===")
    }

    func processFullDocument(
        document: PDFDocument,
        documentURL: URL,
        graph: KnowledgeGraph,
        aiService: AIServiceManager,
        projectID: UUID? = nil,
        mode: ExtractionMode = .fast
    ) {
        guard !isProcessing else {
            log.warning("processFullDocument called while already processing — queued by caller")
            return
        }
        log.info("processFullDocument: \(documentURL.lastPathComponent), \(document.pageCount) pages, mode=\(mode.rawValue)")
        isProcessing = true
        graph.documentProcessingState[documentURL] = .processing
        scannedPDFDetected = false
        processingTask = Task {
            await processPages(
                document: document,
                documentURL: documentURL,
                pageRange: 0..<document.pageCount,
                graph: graph,
                aiService: aiService,
                projectID: projectID,
                mode: mode
            )
        }
    }

    // MARK: - Batch Processing

    private func processBatch(
        document: PDFDocument,
        documentURL: URL,
        pageRange: Range<Int>,
        graph: KnowledgeGraph,
        backend: any AtlasModel,
        existingLabels: [String],
        outlineHints: [String],
        projectID: UUID? = nil
    ) async throws {
        // Step 1: Extract text
        let pageResults = textExtractor.extractPages(from: document, pageRange: pageRange)
        let totalChars = pageResults.reduce(0) { $0 + $1.fullText.count }
        log.info("[Step 1] Text extraction: \(pageResults.count) pages, \(totalChars) chars total")
        for r in pageResults {
            log.debug("  Page \(r.pageIndex+1): \(r.blocks.count) blocks, \(r.fullText.count) chars")
        }

        var effectiveResults = pageResults

        if totalChars == 0 {
            log.warning("[Step 1] No text extracted from pages — attempting OCR fallback")
            statusMessage = "No embedded text — running OCR..."
            let ocrResults = await textExtractor.ocrExtractPages(from: document, pageRange: pageRange)
            let ocrChars = ocrResults.reduce(0) { $0 + $1.fullText.count }
            log.info("[Step 1-OCR] OCR extracted \(ocrChars) chars from \(ocrResults.count) pages")

            if ocrChars == 0 {
                scannedPDFDetected = true
                log.warning("[Step 1-OCR] OCR also yielded no text")
                statusMessage = "No text could be extracted from this PDF"
                return
            }
            effectiveResults = ocrResults
        } else {
            // Detect low-density text (< 10 chars/page avg)
            let avgCharsPerPage = totalChars / max(1, pageResults.count)
            if avgCharsPerPage < 10 {
                scannedPDFDetected = true
                log.warning("[Step 1] Low-density text (\(avgCharsPerPage) chars/page avg) — possibly a scanned PDF")
            }
        }

        // Step 2: Layout classification
        var classifiedBlocks: [PageTextBlock] = []
        for result in effectiveResults {
            guard let page = document.page(at: result.pageIndex) else { continue }
            let pageSize = page.bounds(for: .mediaBox).size
            let classified = layoutAnalyzer.classify(blocks: result.blocks, pageSize: pageSize)
            classifiedBlocks.append(contentsOf: classified)
        }
        log.info("[Step 2] Layout analysis: \(classifiedBlocks.count) classified blocks")

        // Step 3: Build context
        let centerPage = (pageRange.lowerBound + pageRange.upperBound) / 2
        let contextText: String
        if effectiveResults.first?.fullText != pageResults.first?.fullText {
            // OCR path: build context from OCR results directly
            contextText = effectiveResults.map { "--- Page \($0.pageIndex + 1) ---\n\($0.fullText)" }.joined(separator: "\n\n")
            log.info("[Step 3] Context built from OCR: \(contextText.count) chars")
        } else {
            let contextExtraction = textExtractor.extractWithContext(from: document, centerPage: centerPage, contextPages: 2)
            contextText = contextExtraction.contextText
            log.info("[Step 3] Context built: \(contextText.count) chars, center=page \(centerPage+1)")
        }

        let context = ExtractionContext(
            documentTitle: documentURL.lastPathComponent,
            pageRange: pageRange,
            existingConcepts: existingLabels,
            outlineHints: outlineHints
        )

        // Step 4: AI concept extraction (hierarchical)
        log.info("[Step 4] Sending to AI for hierarchical concept extraction...")
        let rawConcepts: [RawConcept]
        do {
            rawConcepts = try await backend.extractConcepts(from: contextText, context: context)
            log.info("[Step 4] AI returned \(rawConcepts.count) raw concepts")
            for (i, c) in rawConcepts.enumerated() {
                let entityCount = c.entities?.count ?? 0
                log.debug("  [\(i)] label=\"\(c.label)\" level=\(c.level ?? "nil") entities=\(entityCount) span=\(c.textSpan.prefix(60))...")
            }
        } catch {
            log.error("[Step 4] AI extraction failed: \(error)")
            throw error
        }

        if rawConcepts.isEmpty {
            log.warning("[Step 4] AI returned 0 concepts — check prompt or model output")
            return
        }

        // Step 5: Anchor resolution + hierarchical graph integration
        var anchored = 0
        var rejected = 0

        for rawConcept in rawConcepts {
            // Resolve concept-level node
            guard let conceptAnchor = findSourceAnchor(
                for: rawConcept.textSpan,
                in: classifiedBlocks,
                documentURL: documentURL,
                document: document
            ) else {
                rejected += 1
                log.debug("[Step 5] REJECTED concept (no anchor): \"\(rawConcept.label)\"")
                continue
            }
            anchored += 1

            let conceptType = rawConcept.type.asConceptType()

            // Top-level items are always concept-level. Only nested items (inner loop) are entities.
            // This prevents orphan entities when the LLM returns a flat list.
            let effectiveLevel: NodeLevel = .concept

            // Check for existing concept node with same label
            let existingNode = graph.node(matching: rawConcept.label)
            let conceptNodeID: UUID

            if var existing = existingNode {
                existing.sourceAnchors.append(conceptAnchor)
                if let summary = rawConcept.summary, existing.summary == nil {
                    existing.summary = summary
                }
                existing.lastModified = Date()
                graph.updateNode(existing)
                conceptNodeID = existing.id
                log.debug("[Step 5] Updated existing concept: \"\(existing.label)\"")
            } else {
                let colorIndex = effectiveLevel == .concept ? graph.nextHighlightColorIndex() : nil
                let node = ConceptNode(
                    label: rawConcept.label,
                    type: conceptType,
                    summary: rawConcept.summary,
                    sourceAnchors: [conceptAnchor],
                    confidence: rawConcept.confidence ?? 0.8,
                    level: effectiveLevel,
                    highlightColorIndex: colorIndex
                )
                graph.addNode(node)
                conceptNodeID = node.id
                log.debug("[Step 5] Added concept: \"\(node.label)\"")
            }

            // Note: `rawConcept.subtopicOf` is ignored under the 4-level model.
            // Concept→Chapter relationships are recorded via `containsConcept`
            // edges originating from Chapter nodes — created in the post-
            // extraction Concept-to-Chapter attachment pass, not here.

            // Process nested entities
            guard let entities = rawConcept.entities, !entities.isEmpty else { continue }

            for rawEntity in entities {
                guard let entityAnchor = findSourceAnchor(
                    for: rawEntity.textSpan,
                    in: classifiedBlocks,
                    documentURL: documentURL,
                    document: document
                ) else {
                    rejected += 1
                    log.debug("[Step 5] REJECTED entity (no anchor): \"\(rawEntity.label)\" under \"\(rawConcept.label)\"")
                    continue
                }
                anchored += 1

                let entityType = rawEntity.type.asConceptType(default: .definition)

                // Check if entity already exists
                let existingEntity = graph.node(matching: rawEntity.label)

                let entityNodeID: UUID
                if var existing = existingEntity {
                    existing.sourceAnchors.append(entityAnchor)
                    if let summary = rawEntity.summary, existing.summary == nil {
                        existing.summary = summary
                    }
                    existing.lastModified = Date()
                    graph.updateNode(existing)
                    entityNodeID = existing.id
                    log.debug("[Step 5] Updated existing entity: \"\(existing.label)\"")
                } else {
                    // Inherit highlight color from parent concept
                    let parentColor = graph.node(for: conceptNodeID)?.highlightColorIndex
                    let entity = ConceptNode(
                        label: rawEntity.label,
                        type: entityType,
                        summary: rawEntity.summary,
                        sourceAnchors: [entityAnchor],
                        confidence: rawEntity.confidence ?? 0.8,
                        level: .entity,
                        highlightColorIndex: parentColor
                    )
                    graph.addNode(entity)
                    entityNodeID = entity.id
                    log.debug("[Step 5] Added entity: \"\(entity.label)\" under \"\(rawConcept.label)\"")
                }

                // Ensure containsEntity edge exists (concept → entity).
                let alreadyLinked = graph.allEdges.contains { e in
                    e.type == .containsEntity &&
                    e.sourceNodeID == conceptNodeID &&
                    e.targetNodeID == entityNodeID
                }
                if !alreadyLinked {
                    let containsEdge = GraphEdge(
                        sourceNodeID: conceptNodeID,
                        targetNodeID: entityNodeID,
                        type: .containsEntity,
                        confidence: 1.0
                    )
                    graph.addEdge(containsEdge)
                }
            }
        }
        log.info("[Step 5] Anchor resolution: \(anchored) anchored, \(rejected) rejected")

        // Step 6: Edge proposal
        let conceptLabels = graph.allNodes.map { $0.label }
        if conceptLabels.count >= 2 {
            log.info("[Step 6] Requesting edge proposals for \(conceptLabels.count) concepts...")
            do {
                let rawEdges = try await backend.proposeEdges(between: conceptLabels, context: contextText)
                log.info("[Step 6] AI returned \(rawEdges.count) raw edges")

                var added = 0
                for rawEdge in rawEdges {
                    guard let sourceNode = graph.node(matching: rawEdge.sourceLabel),
                          let targetNode = graph.node(matching: rawEdge.targetLabel) else {
                        log.debug("[Step 6] Edge skipped (node not found): \"\(rawEdge.sourceLabel)\" -> \"\(rawEdge.targetLabel)\"")
                        continue
                    }

                    // Skip if edge already exists or if it's a containsEntity edge (those are implicit)
                    let exists = graph.allEdges.contains {
                        ($0.sourceNodeID == sourceNode.id && $0.targetNodeID == targetNode.id) ||
                        ($0.sourceNodeID == targetNode.id && $0.targetNodeID == sourceNode.id && $0.type == .containsEntity)
                    }
                    guard !exists else { continue }

                    let edgeType = rawEdge.type.asEdgeType()
                    // Don't create duplicate containsEntity edges from LLM suggestions
                    guard edgeType != .containsEntity else { continue }
                    let edge = GraphEdge(
                        sourceNodeID: sourceNode.id,
                        targetNodeID: targetNode.id,
                        type: edgeType,
                        confidence: rawEdge.confidence ?? 0.7,
                        label: rawEdge.linkingPhrase
                    )
                    graph.addEdge(edge)
                    added += 1
                }
                log.info("[Step 6] Added \(added) edges to graph")
            } catch {
                log.error("[Step 6] Edge proposal failed: \(error) — continuing without edges")
            }
        } else {
            log.info("[Step 6] Skipped edge proposal (only \(conceptLabels.count) concepts)")
        }

        // Step 7: Auto-save
        if let projectID = projectID {
            GraphStore.shared.saveProjectGraph(graph, projectID: projectID)
            log.info("[Step 7] Saved project graph")
        } else {
            GraphStore.shared.scheduleSave(graph, for: documentURL)
            log.info("[Step 7] Scheduled per-document auto-save")
        }
    }

    // MARK: - Deep Mode Text Chunking

    private func extractTextChunks(
        document: PDFDocument,
        documentURL: URL,
        pageRange: Range<Int>
    ) -> [TextChunk] {
        var chunks: [TextChunk] = []
        var pageIndex = pageRange.lowerBound

        while pageIndex < pageRange.upperBound {
            let batchEnd = min(pageIndex + batchSize, pageRange.upperBound)
            let batchRange = pageIndex..<batchEnd

            let pageResults = textExtractor.extractPages(from: document, pageRange: batchRange)
            let text = pageResults.map { $0.fullText }.joined(separator: "\n\n")

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(TextChunk(text: text, pageRange: batchRange, documentURL: documentURL))
            }
            pageIndex = batchEnd
        }
        return chunks
    }

    // MARK: - Source Anchor Resolution

    private func findSourceAnchor(
        for textSpan: String,
        in blocks: [PageTextBlock],
        documentURL: URL,
        document: PDFDocument
    ) -> SourceAnchor? {
        let normalizedSpan = textSpan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSpan.isEmpty else {
            log.debug("  findSourceAnchor: empty textSpan")
            return nil
        }

        // Try exact substring match in classified blocks
        for block in blocks {
            if block.text.lowercased().contains(normalizedSpan) {
                return SourceAnchor(
                    documentURL: documentURL,
                    pageIndex: block.pageIndex,
                    boundingBox: block.boundingBox,
                    textSnippet: String(textSpan.prefix(200))
                )
            }
        }

        // Try prefix match (first 30 chars)
        let prefix = String(normalizedSpan.prefix(30))
        for block in blocks {
            if block.text.lowercased().contains(prefix) {
                return SourceAnchor(
                    documentURL: documentURL,
                    pageIndex: block.pageIndex,
                    boundingBox: block.boundingBox,
                    textSnippet: String(textSpan.prefix(200))
                )
            }
        }

        // Last resort: search full page text
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string else { continue }
            if pageText.lowercased().contains(prefix) {
                let bounds = page.bounds(for: .mediaBox)
                return SourceAnchor(
                    documentURL: documentURL,
                    pageIndex: pageIndex,
                    boundingBox: bounds,
                    textSnippet: String(textSpan.prefix(200))
                )
            }
        }

        return nil
    }
}

// MARK: - Document Summary Generation

extension ExtractionPipeline {
    /// Final extraction step: produces the `.document`-level node for this
    /// PDF and links it to its `.chapter` children via `containsChapter`
    /// edges. Under the 4-level model the Document node is the top fold of
    /// what extraction produces — same status as Chapter/Concept/Entity, just
    /// the most abstract level.
    ///
    /// The LLM is fed the document's top concepts as bullet context and
    /// returns a tldr that becomes the Document node's summary. If no
    /// concept-level nodes exist for the URL (extraction produced an empty
    /// graph), we still create the Document node with an empty summary so
    /// the Document tab is not empty — the user can see the doc is present.
    static func appendDocumentSummary(
        graph: KnowledgeGraph,
        documentURL: URL,
        backend: any AtlasModel
    ) async {
        let docFilename = documentURL.lastPathComponent

        let topConcepts = graph.allNodes
            .filter { node in
                node.level == .concept &&
                node.sourceAnchors.contains { $0.documentURL == documentURL }
            }
            .sorted { graph.edges(for: $0.id).count > graph.edges(for: $1.id).count }
            .prefix(8)

        let bullets = topConcepts.map { node -> String in
            if let s = node.summary, !s.isEmpty { return "- \(node.label): \(s)" }
            return "- \(node.label)"
        }.joined(separator: "\n")

        var summaryText = ""
        if !topConcepts.isEmpty {
            let sourceText = """
            Document: \(docFilename)

            Key concepts extracted from this document:
            \(bullets)
            """
            do {
                let raw = try await backend.summarizeConcept(docFilename, sourceText: sourceText)
                summaryText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                log.error("[Summary] LLM call failed for \(docFilename): \(error.localizedDescription)")
            }
        } else {
            log.info("[Summary] No concept nodes for \(docFilename); creating Document node with empty summary")
        }

        // Find or create the Document node for this URL.
        let existing = graph.allNodes.first(where: { node in
            node.level == .document &&
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        })

        let documentNodeID: UUID
        if var updated = existing {
            updated.label = docFilename
            if !summaryText.isEmpty { updated.summary = summaryText }
            updated.lastModified = Date()
            graph.updateNode(updated)
            documentNodeID = updated.id
            log.info("[Summary] Updated Document node for \(docFilename)")
        } else {
            let anchor = SourceAnchor(
                documentURL: documentURL,
                pageIndex: 0,
                boundingBox: .zero,
                textSnippet: ""
            )
            let node = ConceptNode(
                label: docFilename,
                type: .concept,
                summary: summaryText.isEmpty ? nil : summaryText,
                sourceAnchors: [anchor],
                confidence: 1.0,
                level: .document
            )
            graph.addNode(node)
            documentNodeID = node.id
            log.info("[Summary] Created Document node for \(docFilename)")
        }

        // Link Document → Chapter nodes for this URL via containsChapter edges.
        // (Chapter nodes are produced by the chapter-extraction pass, which
        // lands separately; if there are no Chapter nodes yet this is a no-op.)
        let chapters = graph.allNodes.filter { node in
            node.level == .chapter &&
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        for chapter in chapters {
            let alreadyLinked = graph.allEdges.contains { e in
                e.type == .containsChapter &&
                e.sourceNodeID == documentNodeID &&
                e.targetNodeID == chapter.id
            }
            if !alreadyLinked {
                let edge = GraphEdge(
                    sourceNodeID: documentNodeID,
                    targetNodeID: chapter.id,
                    type: .containsChapter,
                    confidence: 1.0
                )
                graph.addEdge(edge)
            }
        }
    }
}
