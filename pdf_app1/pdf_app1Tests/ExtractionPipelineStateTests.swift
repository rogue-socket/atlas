import XCTest
import PDFKit
@testable import pdf_app1

/// Tests for `ExtractionPipeline`'s observable state surface that does NOT
/// require a fully realized PDF + LLM round-trip:
///   - `progress` computation (guard at totalPages == 0)
///   - `cancel()` clears `isProcessing`
///   - `processPages` early-returns when no AI backend is configured
///   - `processFullDocument` guards against re-entry
final class ExtractionPipelineStateTests: XCTestCase {

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
