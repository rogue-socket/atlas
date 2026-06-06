import XCTest
import PDFKit
import AppKit
@testable import pdf_app1

/// Tests for `ExtractionPipeline`'s observable state surface that does NOT
/// require a fully realized PDF + LLM round-trip:
///   - `progress` computation (guard at totalPages == 0)
///   - `cancel()` clears `isProcessing`
///   - `processPages` early-returns when no AI backend is configured
///   - `processFullDocument` guards against re-entry
final class ExtractionPipelineStateTests: XCTestCase {

    private func makePDFDocument(text: String) -> PDFDocument? {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.string = text
        guard let pdfData = textView.dataWithPDF(inside: textView.bounds) as Data? else { return nil }
        return PDFDocument(data: pdfData)
    }

    // MARK: - progress

    func test_progress_isZeroWhenTotalPagesIsZero() {
        let p = ExtractionPipeline()
        p.totalPages = 0
        p.currentPage = 5
        XCTAssertEqual(p.progress, 0, "Guard against divide-by-zero")
    }

    func test_progress_isCurrentOverTotal() {
        let p = ExtractionPipeline()
        p.totalPages = 10
        p.currentPage = 4
        XCTAssertEqual(p.progress, 0.4, accuracy: 0.0001)
    }

    // MARK: - cancel

    func test_cancel_clearsIsProcessing() {
        let p = ExtractionPipeline()
        p.isProcessing = true
        p.cancel()
        XCTAssertFalse(p.isProcessing)
    }

    // MARK: - SCE header cap configuration

    func test_scePriorDocsHeaderMaxLines_defaultsTo120() {
        let suiteName = "ExtractionPipelineStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            ExtractionPipeline.scePriorDocsHeaderMaxLines(environment: [:], defaults: defaults),
            120
        )
    }

    func test_scePriorDocsHeaderMaxLines_readsUserDefaults() {
        let suiteName = "ExtractionPipelineStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(80, forKey: AppConstants.scePriorHeaderMaxLinesKey)

        XCTAssertEqual(
            ExtractionPipeline.scePriorDocsHeaderMaxLines(environment: [:], defaults: defaults),
            80
        )
    }

    func test_scePriorDocsHeaderMaxLines_environmentOverridesUserDefaults() {
        let suiteName = "ExtractionPipelineStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(80, forKey: AppConstants.scePriorHeaderMaxLinesKey)

        XCTAssertEqual(
            ExtractionPipeline.scePriorDocsHeaderMaxLines(
                environment: ["ATLAS_SCE_PRIOR_HEADER_MAX_LINES": "60"],
                defaults: defaults
            ),
            60
        )
    }

    func test_scePriorDocsHeaderMaxLines_ignoresInvalidEnvironment() {
        let suiteName = "ExtractionPipelineStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(90, forKey: AppConstants.scePriorHeaderMaxLinesKey)

        XCTAssertEqual(
            ExtractionPipeline.scePriorDocsHeaderMaxLines(
                environment: ["ATLAS_SCE_PRIOR_HEADER_MAX_LINES": "0"],
                defaults: defaults
            ),
            90
        )
    }

    func test_shouldFinalizeExtraction_allowsCompletedLoop() {
        XCTAssertTrue(
            ExtractionPipeline.shouldFinalizeExtraction(
                batchLoopOutcome: .completed,
                taskIsCancelled: false
            )
        )
    }

    func test_shouldFinalizeExtraction_blocksFailedLoop() {
        XCTAssertFalse(
            ExtractionPipeline.shouldFinalizeExtraction(
                batchLoopOutcome: .failed,
                taskIsCancelled: false
            )
        )
    }

    func test_shouldFinalizeExtraction_blocksCancellation() {
        XCTAssertFalse(
            ExtractionPipeline.shouldFinalizeExtraction(
                batchLoopOutcome: .completed,
                taskIsCancelled: true
            )
        )
        XCTAssertFalse(
            ExtractionPipeline.shouldFinalizeExtraction(
                batchLoopOutcome: .cancelled,
                taskIsCancelled: false
            )
        )
    }

    // MARK: - Relationship edge integration

    func test_addRelationshipEdges_addsSemanticEdgeBetweenEntityAndConcept() {
        let graph = KnowledgeGraph()
        let concept = ConceptNode(label: "Customer Operations", type: .concept, level: .concept)
        let entity = ConceptNode(label: "Service SLA", type: .definition, level: .entity)
        graph.addNode(concept)
        graph.addNode(entity)

        let result = ExtractionPipeline.addRelationshipEdges([
            RawEdge(
                sourceLabel: "Service SLA",
                targetLabel: "Customer Operations",
                type: "defines",
                confidence: 0.9,
                linkingPhrase: "defines"
            )
        ], to: graph)

        XCTAssertEqual(result.added, 1)
        let semantic = graph.allEdges.first { $0.type == .defines }
        XCTAssertEqual(semantic?.sourceNodeID, entity.id)
        XCTAssertEqual(semantic?.targetNodeID, concept.id)
        XCTAssertEqual(semantic?.label, "defines")
    }

    func test_addRelationshipEdges_allowsSemanticEdgeAlongsideContainmentEdge() {
        let graph = KnowledgeGraph()
        let concept = ConceptNode(label: "Customer Operations", type: .concept, level: .concept)
        let entity = ConceptNode(label: "Service SLA", type: .definition, level: .entity)
        graph.addNode(concept)
        graph.addNode(entity)
        graph.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: entity.id, type: .containsEntity))

        let result = ExtractionPipeline.addRelationshipEdges([
            RawEdge(
                sourceLabel: "Customer Operations",
                targetLabel: "Service SLA",
                type: "defines",
                confidence: 0.9,
                linkingPhrase: "defines"
            )
        ], to: graph)

        XCTAssertEqual(result.added, 1)
        XCTAssertTrue(graph.allEdges.contains { $0.type == .containsEntity })
        XCTAssertTrue(graph.allEdges.contains { $0.type == .defines })
    }

    func test_addRelationshipEdges_suppressesExactDuplicateOnly() {
        let graph = KnowledgeGraph()
        let source = ConceptNode(label: "Repair Program", type: .concept, level: .concept)
        let target = ConceptNode(label: "Service Model", type: .concept, level: .concept)
        graph.addNode(source)
        graph.addNode(target)

        let first = ExtractionPipeline.addRelationshipEdges([
            RawEdge(
                sourceLabel: "Repair Program",
                targetLabel: "Service Model",
                type: "uses",
                confidence: 0.8,
                linkingPhrase: "uses"
            )
        ], to: graph)
        let second = ExtractionPipeline.addRelationshipEdges([
            RawEdge(
                sourceLabel: "Repair Program",
                targetLabel: "Service Model",
                type: "uses",
                confidence: 0.8,
                linkingPhrase: "uses"
            ),
            RawEdge(
                sourceLabel: "Repair Program",
                targetLabel: "Service Model",
                type: "dependsOn",
                confidence: 0.8,
                linkingPhrase: "requires"
            )
        ], to: graph)

        XCTAssertEqual(first.added, 1)
        XCTAssertEqual(second.added, 1)
        XCTAssertEqual(second.duplicate, 1)
        XCTAssertEqual(graph.allEdges.filter { !$0.type.isContainment }.count, 2)
    }

    func test_edgeProposalCandidates_includesCurrentBatchEntitiesWithParent() {
        let graph = KnowledgeGraph()
        let url = URL(fileURLWithPath: "/tmp/current.pdf")
        let otherURL = URL(fileURLWithPath: "/tmp/other.pdf")
        let concept = ConceptNode(
            label: "Customer Operations",
            type: .concept,
            summary: "Operational support model.",
            sourceAnchors: [SourceAnchor(documentURL: url, pageIndex: 2, boundingBox: .zero, textSnippet: "Customer Operations")],
            level: .concept
        )
        let entity = ConceptNode(
            label: "Service SLA",
            type: .definition,
            summary: "Support response standard.",
            sourceAnchors: [SourceAnchor(documentURL: url, pageIndex: 2, boundingBox: .zero, textSnippet: "Service SLA")],
            level: .entity
        )
        let other = ConceptNode(
            label: "Other Document",
            type: .concept,
            sourceAnchors: [SourceAnchor(documentURL: otherURL, pageIndex: 2, boundingBox: .zero, textSnippet: "Other Document")],
            level: .concept
        )
        graph.addNode(concept)
        graph.addNode(entity)
        graph.addNode(other)
        graph.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: entity.id, type: .containsEntity))

        let candidates = ExtractionPipeline.edgeProposalCandidates(
            graph: graph,
            documentURL: url,
            pageRange: 2..<3,
            maxCount: 10
        )

        XCTAssertEqual(candidates.map(\.label), ["Customer Operations", "Service SLA"])
        XCTAssertEqual(candidates.last?.parentLabel, "Customer Operations")
        XCTAssertEqual(candidates.last?.level, .entity)
    }

    // MARK: - source anchor bounds

    func test_sourceAnchorBounds_pageSizedPreferredBoundsUseSelectionBounds() {
        guard let document = makePDFDocument(text: "Meridian Biofab validates release criteria from pilot manufacturing notes."),
              let page = document.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }

        let bounds = ExtractionPipeline.sourceAnchorBounds(
            preferredBounds: page.bounds(for: .mediaBox),
            snippet: "pilot manufacturing notes",
            pageIndex: 0,
            document: document
        )

        let pageBounds = page.bounds(for: .mediaBox)
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertLessThan(bounds.width * bounds.height, pageBounds.width * pageBounds.height * 0.25)
    }

    func test_sourceAnchorBounds_pageSizedPreferredBoundsWithoutSelectionBecomesPageOnly() {
        guard let document = makePDFDocument(text: "Meridian Biofab validates release criteria."),
              let page = document.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }

        let bounds = ExtractionPipeline.sourceAnchorBounds(
            preferredBounds: page.bounds(for: .mediaBox),
            snippet: "not present on page",
            pageIndex: 0,
            document: document
        )

        XCTAssertEqual(bounds, .zero)
    }

    // MARK: - processPages early-return without backend

    @MainActor
    func test_processPages_withoutBackend_setsStatusAndResets() async throws {
        // Use a backend type that requires a key (claude) and ensure no env
        // var is set in this run. Under XCTest, AIServiceManager.getAPIKey is
        // hard-guarded to nil, so createBackend() returns nil.
        let envName = "ATLAS_CLAUDE_API_KEY"
        try XCTSkipIf(ProcessInfo.processInfo.environment[envName] != nil,
                      "Skipping; \(envName) is set, backend would be created")

        let aiService = AIServiceManager()
        aiService.selectedBackendType = .claude
        aiService.selectedModel = "claude-sonnet-4-5-20250514"

        let pipeline = ExtractionPipeline()
        pipeline.isProcessing = true  // pretend we already started
        let graph = KnowledgeGraph()
        let url = URL(fileURLWithPath: "/tmp/pipeline-empty.pdf")
        let doc = PDFDocument()  // 0 pages

        await pipeline.processPages(
            document: doc, documentURL: url, pageRange: 0..<0,
            graph: graph, aiService: aiService
        )

        XCTAssertFalse(pipeline.isProcessing)
        XCTAssertTrue(pipeline.statusMessage.contains("not configured"),
                      "status should reflect missing backend: '\(pipeline.statusMessage)'")
    }

    // MARK: - processFullDocument re-entry guard

    @MainActor
    func test_processFullDocument_doesNotStartWhenAlreadyProcessing() {
        let p = ExtractionPipeline()
        p.isProcessing = true

        let aiService = AIServiceManager()
        let graph = KnowledgeGraph()
        let url = URL(fileURLWithPath: "/tmp/skip.pdf")
        let doc = PDFDocument()

        // Snapshot state before; expect no mutation.
        let beforeStatus = p.statusMessage
        p.processFullDocument(document: doc, documentURL: url, graph: graph, aiService: aiService)
        XCTAssertEqual(p.statusMessage, beforeStatus,
                       "Already-processing guard should make this a no-op")
        XCTAssertNil(graph.documentProcessingState[url],
                     "URL state must not be touched when guard fires")
    }

}
