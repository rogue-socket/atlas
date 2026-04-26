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

    private let textExtractor = TextExtractor()
    private let layoutAnalyzer = LayoutAnalyzer()
    private let batchSize = 5

    // MARK: - Progressive Extraction

    func processPages(
        document: PDFDocument,
        documentURL: URL,
        pageRange: Range<Int>,
        graph: KnowledgeGraph,
        aiService: AIServiceManager
    ) async {
        guard !isProcessing else {
            log.warning("processPages called while already processing — skipping")
            return
        }

        log.info("=== Starting extraction for \(documentURL.lastPathComponent), pages \(pageRange.lowerBound+1)-\(pageRange.upperBound) ===")

        guard let backend = aiService.createBackend() else {
            log.error("No AI backend configured (type=\(aiService.selectedBackendType.rawValue), model=\(aiService.selectedModel))")
            statusMessage = "AI backend not configured"
            return
        }

        log.info("Using backend: \(backend.displayName) / \(backend.modelIdentifier)")

        isProcessing = true
        totalPages = pageRange.count

        let existingLabels = graph.allNodes.map { $0.label }
        let outlineEntries = layoutAnalyzer.extractOutline(from: document)
        let outlineHints = outlineEntries.map { $0.title }
        log.info("Outline entries: \(outlineEntries.count), existing concepts: \(existingLabels.count)")

        var pageIndex = pageRange.lowerBound
        var batchNumber = 0
        while pageIndex < pageRange.upperBound {
            let batchEnd = min(pageIndex + batchSize, pageRange.upperBound)
            let batchRange = pageIndex..<batchEnd
            batchNumber += 1

            currentPage = pageIndex
            statusMessage = "Analyzing pages \(batchRange.lowerBound + 1)-\(batchEnd)..."
            log.info("--- Batch \(batchNumber): pages \(batchRange.lowerBound+1)-\(batchEnd) ---")

            do {
                try await processBatch(
                    document: document,
                    documentURL: documentURL,
                    pageRange: batchRange,
                    graph: graph,
                    backend: backend,
                    existingLabels: existingLabels,
                    outlineHints: outlineHints
                )
                log.info("Batch \(batchNumber) done. Graph now has \(graph.nodeCount) nodes, \(graph.edgeCount) edges")
            } catch {
                log.error("Batch \(batchNumber) FAILED: \(error.localizedDescription)")
                statusMessage = "Error: \(error.localizedDescription)"
                break
            }

            pageIndex = batchEnd
        }

        isProcessing = false
        statusMessage = "Done — \(graph.nodeCount) concepts extracted"
        graph.documentProcessingState[documentURL] = .complete
        log.info("=== Extraction complete: \(graph.nodeCount) nodes, \(graph.edgeCount) edges ===")
    }

    func processFullDocument(
        document: PDFDocument,
        documentURL: URL,
        graph: KnowledgeGraph,
        aiService: AIServiceManager
    ) async {
        log.info("processFullDocument: \(documentURL.lastPathComponent), \(document.pageCount) pages")
        graph.documentProcessingState[documentURL] = .processing
        await processPages(
            document: document,
            documentURL: documentURL,
            pageRange: 0..<document.pageCount,
            graph: graph,
            aiService: aiService
        )
    }

    // MARK: - Batch Processing

    private func processBatch(
        document: PDFDocument,
        documentURL: URL,
        pageRange: Range<Int>,
        graph: KnowledgeGraph,
        backend: any AtlasModel,
        existingLabels: [String],
        outlineHints: [String]
    ) async throws {
        // Step 1: Extract text
        let pageResults = textExtractor.extractPages(from: document, pageRange: pageRange)
        let totalChars = pageResults.reduce(0) { $0 + $1.fullText.count }
        log.info("[Step 1] Text extraction: \(pageResults.count) pages, \(totalChars) chars total")
        for r in pageResults {
            log.debug("  Page \(r.pageIndex+1): \(r.blocks.count) blocks, \(r.fullText.count) chars")
        }

        if totalChars == 0 {
            log.warning("[Step 1] No text extracted from pages — possibly a scanned PDF without OCR")
            return
        }

        // Step 2: Layout classification
        var classifiedBlocks: [PageTextBlock] = []
        for result in pageResults {
            guard let page = document.page(at: result.pageIndex) else { continue }
            let pageSize = page.bounds(for: .mediaBox).size
            let classified = layoutAnalyzer.classify(blocks: result.blocks, pageSize: pageSize)
            classifiedBlocks.append(contentsOf: classified)
        }
        log.info("[Step 2] Layout analysis: \(classifiedBlocks.count) classified blocks")

        // Step 3: Build context
        let centerPage = (pageRange.lowerBound + pageRange.upperBound) / 2
        let contextExtraction = textExtractor.extractWithContext(from: document, centerPage: centerPage, contextPages: 2)
        log.info("[Step 3] Context built: \(contextExtraction.contextText.count) chars, center=page \(centerPage+1)")

        let context = ExtractionContext(
            documentTitle: documentURL.lastPathComponent,
            pageRange: pageRange,
            existingConcepts: existingLabels,
            outlineHints: outlineHints
        )

        // Step 4: AI concept extraction
        log.info("[Step 4] Sending to AI for concept extraction...")
        let rawConcepts: [RawConcept]
        do {
            rawConcepts = try await backend.extractConcepts(from: contextExtraction.contextText, context: context)
            log.info("[Step 4] AI returned \(rawConcepts.count) raw concepts")
            for (i, c) in rawConcepts.enumerated() {
                log.debug("  [\(i)] label=\"\(c.label)\" type=\(c.type) span=\(c.textSpan.prefix(60))...")
            }
        } catch {
            log.error("[Step 4] AI extraction failed: \(error)")
            throw error
        }

        if rawConcepts.isEmpty {
            log.warning("[Step 4] AI returned 0 concepts — check prompt or model output")
            return
        }

        // Step 5: Anchor resolution + graph integration
        var anchored = 0
        var rejected = 0
        for rawConcept in rawConcepts {
            let anchor = findSourceAnchor(
                for: rawConcept.textSpan,
                in: classifiedBlocks,
                documentURL: documentURL,
                document: document
            )

            if anchor == nil {
                rejected += 1
                log.debug("[Step 5] REJECTED (no anchor): \"\(rawConcept.label)\" span=\"\(rawConcept.textSpan.prefix(50))...\"")
                continue
            }
            anchored += 1

            let conceptType = ConceptType(rawValue: rawConcept.type) ?? .concept
            let existingNode = graph.allNodes.first { $0.label.lowercased() == rawConcept.label.lowercased() }

            if var existing = existingNode {
                existing.sourceAnchors.append(anchor!)
                if let summary = rawConcept.summary, existing.summary == nil {
                    existing.summary = summary
                }
                graph.updateNode(existing)
                log.debug("[Step 5] Updated existing node: \"\(existing.label)\"")
            } else {
                let node = ConceptNode(
                    label: rawConcept.label,
                    type: conceptType,
                    summary: rawConcept.summary,
                    sourceAnchors: [anchor!],
                    confidence: rawConcept.confidence ?? 0.8
                )
                graph.addNode(node)
                log.debug("[Step 5] Added new node: \"\(node.label)\" type=\(conceptType.rawValue)")
            }
        }
        log.info("[Step 5] Anchor resolution: \(anchored) anchored, \(rejected) rejected (no match)")

        // Step 6: Edge proposal
        let conceptLabels = graph.allNodes.map { $0.label }
        if conceptLabels.count >= 2 {
            log.info("[Step 6] Requesting edge proposals for \(conceptLabels.count) concepts...")
            do {
                let rawEdges = try await backend.proposeEdges(between: conceptLabels, context: contextExtraction.contextText)
                log.info("[Step 6] AI returned \(rawEdges.count) raw edges")

                var added = 0
                for rawEdge in rawEdges {
                    guard let sourceNode = graph.allNodes.first(where: { $0.label.lowercased() == rawEdge.sourceLabel.lowercased() }),
                          let targetNode = graph.allNodes.first(where: { $0.label.lowercased() == rawEdge.targetLabel.lowercased() }) else {
                        log.debug("[Step 6] Edge skipped (node not found): \"\(rawEdge.sourceLabel)\" -> \"\(rawEdge.targetLabel)\"")
                        continue
                    }

                    let exists = graph.allEdges.contains {
                        $0.sourceNodeID == sourceNode.id && $0.targetNodeID == targetNode.id
                    }
                    guard !exists else { continue }

                    let edgeType = EdgeType(rawValue: rawEdge.type) ?? .sameTopic
                    let edge = GraphEdge(
                        sourceNodeID: sourceNode.id,
                        targetNodeID: targetNode.id,
                        type: edgeType,
                        confidence: rawEdge.confidence ?? 0.7
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
        GraphStore.shared.scheduleSave(graph, for: documentURL)
        log.info("[Step 7] Scheduled auto-save")
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
