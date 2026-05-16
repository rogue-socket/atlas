import XCTest
@testable import pdf_app1

/// Tests for SCE (Sequential Cumulative Extraction) — step 1.
///
/// Step 1 covers the cumulative-state header builder + its threading through
/// `ExtractionContext` into the concept-extraction prompt. Later steps will
/// cover buffer-then-commit in `ExtractionPipeline` and Gemini prompt-token
/// capture; those land in this same file as they're built.
final class SCETests: XCTestCase {

    private let docA = URL(fileURLWithPath: "/tmp/sce/doc_a.pdf")
    private let docB = URL(fileURLWithPath: "/tmp/sce/doc_b.pdf")

    private func anchor(in url: URL, page: Int = 0) -> SourceAnchor {
        SourceAnchor(
            documentURL: url,
            pageIndex: page,
            boundingBox: .zero,
            textSnippet: ""
        )
    }

    // MARK: - cumulativeStateHeader

    func test_cumulativeStateHeader_emptyWhenGraphHasNoPriorDocNodes() {
        // No nodes at all → empty.
        let empty = KnowledgeGraph()
        XCTAssertEqual(
            PromptTemplates.cumulativeStateHeader(priorDocsGraph: empty, currentDocURL: docB),
            ""
        )

        // Only nodes anchored in the current doc → empty (those are intra-doc, not prior).
        let intraDocOnly = KnowledgeGraph()
        intraDocOnly.addNode(ConceptNode(
            label: "Local Concept",
            sourceAnchors: [anchor(in: docB)],
            level: .concept
        ))
        XCTAssertEqual(
            PromptTemplates.cumulativeStateHeader(priorDocsGraph: intraDocOnly, currentDocURL: docB),
            ""
        )
    }

    func test_cumulativeStateHeader_includesPriorDocNodesAndExcludesCurrentDocNodes() {
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(
            label: "VitaCare Health Network",
            type: .concept,
            summary: "Hybrid digital health and clinic operator.",
            sourceAnchors: [anchor(in: docA)],
            level: .concept
        ))
        g.addNode(ConceptNode(
            label: "Helena Vargas",
            type: .person,
            summary: "Chief Clinical Quality Officer.",
            sourceAnchors: [anchor(in: docA)],
            level: .entity
        ))
        // Current-doc node — must NOT appear in the header.
        g.addNode(ConceptNode(
            label: "Local Only",
            type: .concept,
            summary: "Should be skipped.",
            sourceAnchors: [anchor(in: docB)],
            level: .concept
        ))

        let header = PromptTemplates.cumulativeStateHeader(priorDocsGraph: g, currentDocURL: docB)
        XCTAssertTrue(header.contains("VitaCare Health Network"))
        XCTAssertTrue(header.contains("Helena Vargas"))
        XCTAssertFalse(header.contains("Local Only"))
        // Format check: label · level·type · summary
        XCTAssertTrue(header.contains("(concept·concept)"))
        XCTAssertTrue(header.contains("(entity·person)"))
        XCTAssertTrue(header.contains("Hybrid digital health and clinic operator."))
    }

    func test_cumulativeStateHeader_treatsMultiAnchorNodeAsCurrentDocAndSkips() {
        // A multi-anchor node touching the current doc is considered already-known
        // to that doc's context and should not be re-listed in the prior-docs header.
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(
            label: "Shared Across Docs",
            type: .concept,
            summary: "Anchored in both A and B.",
            sourceAnchors: [anchor(in: docA), anchor(in: docB)],
            level: .concept
        ))
        let header = PromptTemplates.cumulativeStateHeader(priorDocsGraph: g, currentDocURL: docB)
        XCTAssertEqual(header, "")
    }

    func test_cumulativeStateHeader_handlesMissingSummaryGracefully() {
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(
            label: "No Summary Concept",
            type: .concept,
            summary: nil,
            sourceAnchors: [anchor(in: docA)],
            level: .concept
        ))
        let header = PromptTemplates.cumulativeStateHeader(priorDocsGraph: g, currentDocURL: docB)
        XCTAssertTrue(header.contains("No Summary Concept"))
        XCTAssertTrue(header.contains("(no summary)"))
    }

    // MARK: - ExtractionContext.priorDocsContext threading

    func test_conceptExtractionPrompt_omitsPriorDocsBlockWhenContextIsNil() {
        let ctx = ExtractionContext(
            documentTitle: "doc_a.pdf",
            pageRange: 0..<5,
            existingConcepts: [],
            outlineHints: [],
            priorDocsContext: nil
        )
        let prompt = PromptTemplates.conceptExtraction(text: "sample text", context: ctx)
        XCTAssertFalse(prompt.contains("Prior Documents"))
        XCTAssertFalse(prompt.contains("Cross-Document Reuse"))
    }

    func test_conceptExtractionPrompt_includesPriorDocsBlockWhenContextProvided() {
        let header = "- VitaCare Health Network (concept·concept): Hybrid digital health operator."
        let ctx = ExtractionContext(
            documentTitle: "doc_b.pdf",
            pageRange: 0..<5,
            existingConcepts: [],
            outlineHints: [],
            priorDocsContext: header
        )
        let prompt = PromptTemplates.conceptExtraction(text: "sample text", context: ctx)
        XCTAssertTrue(prompt.contains("Prior Documents — Cross-Document Reuse"))
        XCTAssertTrue(prompt.contains("COPY THE LABEL EXACTLY"))
        XCTAssertTrue(prompt.contains("Worked examples"))
        XCTAssertTrue(prompt.contains("VitaCare Health Network"))
    }

    // MARK: - Buffer-then-commit contract
    //
    // The pipeline's full buffer-then-commit flow is integration-tested manually
    // on live PDFs (per integration decision: verification = re-analyze vitacare).
    // These tests pin the underlying contract — KnowledgeGraph.merge(from:) is
    // what makes the commit atomic — so a future change to merge semantics that
    // breaks SCE assumptions fails here.

    func test_sceBufferCommit_mergeMakesBufferContentsAppearInLiveGraph() {
        // Live graph starts with doc-A content.
        let live = KnowledgeGraph()
        let docANode = ConceptNode(
            label: "Doc A Concept",
            sourceAnchors: [anchor(in: docA)],
            level: .concept
        )
        live.addNode(docANode)

        // Buffer collects doc-B batch results.
        let buffer = KnowledgeGraph()
        let docBNode1 = ConceptNode(
            label: "Doc B Concept 1",
            sourceAnchors: [anchor(in: docB)],
            level: .concept
        )
        let docBNode2 = ConceptNode(
            label: "Doc B Concept 2",
            sourceAnchors: [anchor(in: docB)],
            level: .concept
        )
        buffer.addNode(docBNode1)
        buffer.addNode(docBNode2)
        buffer.addEdge(GraphEdge(
            sourceNodeID: docBNode1.id,
            targetNodeID: docBNode2.id,
            type: .dependsOn
        ))

        // Commit: live.merge(from: buffer).
        XCTAssertEqual(live.nodeCount, 1)
        live.merge(from: buffer)
        XCTAssertEqual(live.nodeCount, 3)
        XCTAssertEqual(live.edgeCount, 1)
        XCTAssertNotNil(live.node(matching: "Doc A Concept"))
        XCTAssertNotNil(live.node(matching: "Doc B Concept 1"))
        XCTAssertNotNil(live.node(matching: "Doc B Concept 2"))
    }

    func test_sceBufferDiscard_skippingMergeLeavesLiveGraphUntouched() {
        // Live graph starts with doc-A content.
        let live = KnowledgeGraph()
        live.addNode(ConceptNode(
            label: "Doc A Concept",
            sourceAnchors: [anchor(in: docA)],
            level: .concept
        ))

        // Buffer accumulates partial doc-B batch work that should be thrown away
        // because the doc-B run was cancelled mid-extraction.
        let buffer = KnowledgeGraph()
        buffer.addNode(ConceptNode(
            label: "Partial Doc B Concept",
            sourceAnchors: [anchor(in: docB)],
            level: .concept
        ))
        XCTAssertEqual(buffer.nodeCount, 1)

        // Pipeline's cancel path: NEVER calls live.merge(from: buffer).
        // Just let the buffer go out of scope. Live graph stays at doc-A only.
        XCTAssertEqual(live.nodeCount, 1)
        XCTAssertNil(live.node(matching: "Partial Doc B Concept"))
        XCTAssertNotNil(live.node(matching: "Doc A Concept"))
    }
}
