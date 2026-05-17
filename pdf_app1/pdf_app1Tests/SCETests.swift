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
        // SCE Option D+E: structured fields drive the merge; no vitacare-specific
        // worked examples — the prompt uses abstract pattern templates instead.
        XCTAssertTrue(prompt.contains("prior_label_match"))
        XCTAssertTrue(prompt.contains("match_kind"))
        XCTAssertTrue(prompt.contains("same_entity"))
        XCTAssertTrue(prompt.contains("instance_of"))
        XCTAssertTrue(prompt.contains("attribute_of"))
        XCTAssertTrue(prompt.contains("process_for"))
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

    // MARK: - SCE Option D — prior_label_match rewrite

    func test_priorDocsLabelMap_excludesCurrentDocNodes_andLowercasesKeys() {
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(label: "Company Identity & Founding",
                              sourceAnchors: [anchor(in: docA)], level: .concept))
        g.addNode(ConceptNode(label: "Helena Vargas",
                              sourceAnchors: [anchor(in: docA)], level: .entity))
        // Current-doc node — excluded.
        g.addNode(ConceptNode(label: "Local Concept",
                              sourceAnchors: [anchor(in: docB)], level: .concept))
        // Multi-anchor touching current doc — excluded (already known to current doc).
        g.addNode(ConceptNode(label: "Shared Already",
                              sourceAnchors: [anchor(in: docA), anchor(in: docB)], level: .concept))

        let map = PromptTemplates.priorDocsLabelMap(graph: g, currentDocURL: docB)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["company identity & founding"], "Company Identity & Founding")
        XCTAssertEqual(map["helena vargas"], "Helena Vargas")
        XCTAssertNil(map["local concept"])
        XCTAssertNil(map["shared already"])
    }

    func test_resolveEffectiveLabel_returnsCanonicalCasing_whenClaimMatches() {
        let map = ["company identity & founding": "Company Identity & Founding"]
        // LLM's label is its own current-doc framing; claim points to prior.
        let (effective, renamed) = PromptTemplates.resolveEffectiveLabel(
            rawLabel: "Company Identity",
            priorLabelMatch: "company identity & founding",   // wrong case — should still match
            priorDocsLabelMap: map
        )
        XCTAssertEqual(effective, "Company Identity & Founding")
        XCTAssertTrue(renamed)
    }

    func test_resolveEffectiveLabel_returnsRawLabel_whenClaimMissing() {
        let map = ["company identity & founding": "Company Identity & Founding"]
        let (effective, renamed) = PromptTemplates.resolveEffectiveLabel(
            rawLabel: "Some New Concept",
            priorLabelMatch: nil,
            priorDocsLabelMap: map
        )
        XCTAssertEqual(effective, "Some New Concept")
        XCTAssertFalse(renamed)
    }

    func test_resolveEffectiveLabel_returnsRawLabel_whenClaimInvalid() {
        // LLM hallucinated a prior label that isn't actually in the map.
        let map = ["company identity & founding": "Company Identity & Founding"]
        let (effective, renamed) = PromptTemplates.resolveEffectiveLabel(
            rawLabel: "New Thing",
            priorLabelMatch: "Imagined Prior Concept",
            priorDocsLabelMap: map
        )
        XCTAssertEqual(effective, "New Thing")
        XCTAssertFalse(renamed)
    }

    func test_resolveEffectiveLabel_treatsEmptyClaimAsAbsent() {
        let map = ["x": "X"]
        let (effective, renamed) = PromptTemplates.resolveEffectiveLabel(
            rawLabel: "Y",
            priorLabelMatch: "   ",  // whitespace-only is a non-claim
            priorDocsLabelMap: map
        )
        XCTAssertEqual(effective, "Y")
        XCTAssertFalse(renamed)
    }

    func test_resolveEffectiveLabel_noOpRename_whenClaimEqualsLabel() {
        // LLM echoed its own label — valid claim but no rewrite needed.
        let map = ["company identity": "Company Identity"]
        let (effective, renamed) = PromptTemplates.resolveEffectiveLabel(
            rawLabel: "Company Identity",
            priorLabelMatch: "Company Identity",
            priorDocsLabelMap: map
        )
        XCTAssertEqual(effective, "Company Identity")
        XCTAssertFalse(renamed, "renamed should be false when canonical equals raw (case-insensitive)")
    }

    func test_rawConcept_decodesPriorLabelMatchFromSnakeCaseJSON() throws {
        let json = """
        {
          "label": "Company Identity",
          "type": "concept",
          "summary": "Who VitaCare is.",
          "textSpan": "VitaCare Health Network is a hybrid operator.",
          "confidence": 0.95,
          "prior_label_match": "Company Identity & Founding"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(c.priorLabelMatch, "Company Identity & Founding")
    }

    func test_rawConcept_decodesWithoutPriorLabelMatch_legacyResponse() throws {
        let json = """
        {
          "label": "Standalone",
          "type": "concept",
          "summary": "No prior match.",
          "textSpan": "Standalone phrase",
          "confidence": 0.9
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertNil(c.priorLabelMatch)
        XCTAssertNil(c.matchKind)
    }

    func test_rawConcept_decodesMatchKindFromSnakeCaseJSON() throws {
        let json = """
        {
          "label": "Annual Wellness Visit Scheduling",
          "type": "concept",
          "summary": "How visits get scheduled.",
          "textSpan": "Wellness visits are scheduled annually.",
          "confidence": 0.85,
          "prior_label_match": "Annual Wellness Visit",
          "match_kind": "process_for"
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(c.priorLabelMatch, "Annual Wellness Visit")
        XCTAssertEqual(c.matchKind, "process_for")
    }

    // MARK: - SCE step 3 — resolveMatchAction

    func test_resolveMatchAction_sameEntity_yieldsMerge() {
        let map = ["company identity & founding": "Company Identity & Founding"]
        let action = PromptTemplates.resolveMatchAction(
            priorLabelMatch: "Company Identity & Founding",
            matchKind: "same_entity",
            priorDocsLabelMap: map
        )
        XCTAssertEqual(action, .mergeByRename(canonical: "Company Identity & Founding"))
    }

    func test_resolveMatchAction_missingMatchKind_defaultsToMerge_backwardCompat() {
        // Step-2 responses had only prior_label_match; preserve their merge behavior.
        let map = ["x": "X"]
        let action = PromptTemplates.resolveMatchAction(
            priorLabelMatch: "X",
            matchKind: nil,
            priorDocsLabelMap: map
        )
        XCTAssertEqual(action, .mergeByRename(canonical: "X"))
    }

    func test_resolveMatchAction_typedKinds_yieldEdges() {
        let map = ["asynchronous messages": "Asynchronous Messages"]
        XCTAssertEqual(
            PromptTemplates.resolveMatchAction(
                priorLabelMatch: "Asynchronous Messages",
                matchKind: "instance_of",
                priorDocsLabelMap: map
            ),
            .typedEdge(canonical: "Asynchronous Messages", edgeType: .instanceOf)
        )
        XCTAssertEqual(
            PromptTemplates.resolveMatchAction(
                priorLabelMatch: "Asynchronous Messages",
                matchKind: "attribute_of",
                priorDocsLabelMap: map
            ),
            .typedEdge(canonical: "Asynchronous Messages", edgeType: .attributeOf)
        )
        XCTAssertEqual(
            PromptTemplates.resolveMatchAction(
                priorLabelMatch: "Asynchronous Messages",
                matchKind: "process_for",
                priorDocsLabelMap: map
            ),
            .typedEdge(canonical: "Asynchronous Messages", edgeType: .processFor)
        )
    }

    func test_resolveMatchAction_invalidPriorLabel_yieldsNoMatch() {
        let map = ["x": "X"]
        let action = PromptTemplates.resolveMatchAction(
            priorLabelMatch: "Hallucinated",
            matchKind: "same_entity",
            priorDocsLabelMap: map
        )
        XCTAssertEqual(action, .noMatch)
    }

    func test_resolveMatchAction_unknownMatchKind_yieldsNoMatch() {
        // Defensive: unknown kinds are refused rather than guessed.
        let map = ["x": "X"]
        let action = PromptTemplates.resolveMatchAction(
            priorLabelMatch: "X",
            matchKind: "synonym_of",  // not in our taxonomy
            priorDocsLabelMap: map
        )
        XCTAssertEqual(action, .noMatch)
    }

    // MARK: - Gemini response-schema builder

    func test_buildExtractionResponseSchema_includesEnumWhenPriorLabelsPresent() throws {
        let schema = GeminiBackend.buildExtractionResponseSchema(
            priorCanonicalLabels: ["Helena Vargas", "Annual Wellness Visit"]
        )
        // Serialize and re-read to assert on shape independent of dictionary ordering.
        let data = try JSONSerialization.data(withJSONObject: schema)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("\"enum\""))
        XCTAssertTrue(s.contains("\"Helena Vargas\""))
        XCTAssertTrue(s.contains("\"Annual Wellness Visit\""))
        // match_kind enum should always be present
        XCTAssertTrue(s.contains("\"same_entity\""))
        XCTAssertTrue(s.contains("\"instance_of\""))
        XCTAssertTrue(s.contains("\"attribute_of\""))
        XCTAssertTrue(s.contains("\"process_for\""))
    }

    func test_buildExtractionResponseSchema_omitsPriorLabelMatchEnumWhenListEmpty() throws {
        let schema = GeminiBackend.buildExtractionResponseSchema(priorCanonicalLabels: [])
        let data = try JSONSerialization.data(withJSONObject: schema)
        let s = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(s.contains("\"prior_label_match\""))
        // match_kind still present even with no priors (LLM may speculate; parser will treat as noMatch)
        XCTAssertTrue(s.contains("\"same_entity\""))
    }

    func test_buildExtractionResponseSchema_fallsBackToUnrestrictedStringWhenOverBudget() throws {
        // Construct labels whose total chars exceed the ~1500 budget.
        // 50 labels × 50 chars = 2500 → over budget → enum dropped.
        let bigLabels = (0..<50).map { i in
            String(repeating: "x", count: 49) + String(i)
        }
        let schema = GeminiBackend.buildExtractionResponseSchema(priorCanonicalLabels: bigLabels)
        let data = try JSONSerialization.data(withJSONObject: schema)
        let s = String(data: data, encoding: .utf8) ?? ""
        // prior_label_match field still present (so the LLM can flag matches),
        // but with no enum constraint — parser-side validation handles it.
        XCTAssertTrue(s.contains("\"prior_label_match\""))
        // No occurrences of the actual label values in the schema => no enum was emitted.
        XCTAssertFalse(s.contains("xxxxxxxxxxxxxxxxxx"))
    }

    func test_buildExtractionResponseSchema_stripsNewlinesFromLabels() throws {
        let dirty = ["Clean Label", "Label with\nnewline", "Tab\there"]
        let schema = GeminiBackend.buildExtractionResponseSchema(priorCanonicalLabels: dirty)
        let data = try JSONSerialization.data(withJSONObject: schema)
        let s = String(data: data, encoding: .utf8) ?? ""
        // Newlines/tabs should be replaced with spaces in the enum values.
        XCTAssertTrue(s.contains("\"Label with newline\""))
        XCTAssertTrue(s.contains("\"Tab here\""))
        XCTAssertFalse(s.contains("\\n"), "embedded newlines leaked into enum")
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
