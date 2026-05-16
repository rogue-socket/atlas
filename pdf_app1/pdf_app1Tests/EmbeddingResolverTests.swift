import XCTest
@testable import pdf_app1

/// Pure-helper tests for `EmbeddingResolver` (ETR stage 3) + the
/// `PromptTemplates.mergeAdjudication` parser. No backend calls; the async
/// orchestrator that wires the embedding backend + LLM is exercised via
/// the headless harness when stage 3/4 land end-to-end.
final class EmbeddingResolverTests: XCTestCase {

    // MARK: - embeddingText

    func test_embeddingText_includesLabelTypeAndSummary() {
        let n = ConceptNode(label: "Helena Vargas", type: .person,
                            summary: "CCQO of VitaCare Health Network.",
                            level: .entity)
        XCTAssertEqual(EmbeddingResolver.embeddingText(for: n),
                       "Helena Vargas: person CCQO of VitaCare Health Network.")
    }

    func test_embeddingText_dropsSummaryWhenNil() {
        let n = ConceptNode(label: "Helena Vargas", type: .person,
                            summary: nil, level: .entity)
        XCTAssertEqual(EmbeddingResolver.embeddingText(for: n),
                       "Helena Vargas: person")
    }

    func test_embeddingText_dropsSummaryWhenEmpty() {
        let n = ConceptNode(label: "Helena Vargas", type: .person,
                            summary: "", level: .entity)
        XCTAssertEqual(EmbeddingResolver.embeddingText(for: n),
                       "Helena Vargas: person")
    }

    // MARK: - contentHash

    func test_contentHash_isDeterministic() {
        let a = ConceptNode(label: "X", type: .concept, summary: "y", level: .concept)
        let b = ConceptNode(label: "X", type: .concept, summary: "y", level: .concept)
        XCTAssertEqual(EmbeddingResolver.contentHash(for: a),
                       EmbeddingResolver.contentHash(for: b))
    }

    func test_contentHash_changesOnSummaryEdit() {
        let a = ConceptNode(label: "X", type: .concept, summary: "y", level: .concept)
        let b = ConceptNode(label: "X", type: .concept, summary: "z", level: .concept)
        XCTAssertNotEqual(EmbeddingResolver.contentHash(for: a),
                          EmbeddingResolver.contentHash(for: b))
    }

    func test_contentHash_nilSummaryDiffersFromEmptyString_andFromNonEmpty() {
        // nil and "" both feed `""` into the hash → same hash. Documents
        // current behavior: the hash collapses nil/empty (both produce the
        // same embedding text, so collapsing the cache key is correct).
        let nilSum = ConceptNode(label: "X", type: .concept, summary: nil, level: .concept)
        let emptySum = ConceptNode(label: "X", type: .concept, summary: "", level: .concept)
        let realSum = ConceptNode(label: "X", type: .concept, summary: "real", level: .concept)
        XCTAssertEqual(EmbeddingResolver.contentHash(for: nilSum),
                       EmbeddingResolver.contentHash(for: emptySum))
        XCTAssertNotEqual(EmbeddingResolver.contentHash(for: nilSum),
                          EmbeddingResolver.contentHash(for: realSum))
    }

    // MARK: - eligibility

    func test_isEligible_conceptAndEntity_true_documentAndChapter_false() {
        XCTAssertTrue(EmbeddingResolver.isEligible(ConceptNode(label: "c", level: .concept)))
        XCTAssertTrue(EmbeddingResolver.isEligible(ConceptNode(label: "e", level: .entity)))
        XCTAssertFalse(EmbeddingResolver.isEligible(ConceptNode(label: "d", level: .document)))
        XCTAssertFalse(EmbeddingResolver.isEligible(ConceptNode(label: "ch", level: .chapter)))
    }

    func test_eligibleNodes_excludesDocumentAndChapter() {
        let g = KnowledgeGraph()
        let c = ConceptNode(label: "c", level: .concept)
        let e = ConceptNode(label: "e", level: .entity)
        let d = ConceptNode(label: "d", level: .document)
        let ch = ConceptNode(label: "ch", level: .chapter)
        [c, e, d, ch].forEach { g.addNode($0) }
        let eligible = Set(EmbeddingResolver.eligibleNodes(in: g).map { $0.id })
        XCTAssertEqual(eligible, [c.id, e.id])
    }

    // MARK: - isCrossDoc

    private func anchor(for url: URL) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: 0, boundingBox: .zero, textSnippet: "")
    }

    func test_isCrossDoc_differentSingleDoc_true() {
        let a = ConceptNode(label: "x", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: URL(fileURLWithPath: "/a.pdf"))],
                            level: .concept)
        let b = ConceptNode(label: "y", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: URL(fileURLWithPath: "/b.pdf"))],
                            level: .concept)
        XCTAssertTrue(EmbeddingResolver.isCrossDoc(a, b))
    }

    func test_isCrossDoc_sameSingleDoc_false() {
        let url = URL(fileURLWithPath: "/a.pdf")
        let a = ConceptNode(label: "x", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: url)], level: .concept)
        let b = ConceptNode(label: "y", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: url)], level: .concept)
        XCTAssertFalse(EmbeddingResolver.isCrossDoc(a, b))
    }

    func test_isCrossDoc_overlappingButNotEqualSets_true() {
        let urlA = URL(fileURLWithPath: "/a.pdf")
        let urlB = URL(fileURLWithPath: "/b.pdf")
        // Merged node A spans both docs; node B spans only one — different sets.
        let a = ConceptNode(label: "x", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlA), anchor(for: urlB)],
                            level: .concept)
        let b = ConceptNode(label: "y", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlA)], level: .concept)
        XCTAssertTrue(EmbeddingResolver.isCrossDoc(a, b))
    }

    func test_isCrossDoc_identicalMultiDocSets_false() {
        let urlA = URL(fileURLWithPath: "/a.pdf")
        let urlB = URL(fileURLWithPath: "/b.pdf")
        let a = ConceptNode(label: "x", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlA), anchor(for: urlB)],
                            level: .concept)
        let b = ConceptNode(label: "y", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlB), anchor(for: urlA)],
                            level: .concept)
        XCTAssertFalse(EmbeddingResolver.isCrossDoc(a, b))
    }

    // MARK: - pairsToCompare

    func test_pairsToCompare_skipsSameDocPairs_keepsCrossDocPairs() {
        let urlA = URL(fileURLWithPath: "/a.pdf")
        let urlB = URL(fileURLWithPath: "/b.pdf")
        let aFromA = ConceptNode(label: "1", type: .concept, summary: nil,
                                 sourceAnchors: [anchor(for: urlA)], level: .concept)
        let bFromA = ConceptNode(label: "2", type: .concept, summary: nil,
                                 sourceAnchors: [anchor(for: urlA)], level: .concept)
        let cFromB = ConceptNode(label: "3", type: .concept, summary: nil,
                                 sourceAnchors: [anchor(for: urlB)], level: .concept)
        let pairs = EmbeddingResolver.pairsToCompare(among: [aFromA, bFromA, cFromB])
        // 3 nodes → 3 unordered pairs → 2 cross-doc (aFromA↔cFromB, bFromA↔cFromB)
        // and 1 in-doc (aFromA↔bFromA) which must be skipped.
        XCTAssertEqual(pairs.count, 2)
        let asSet = Set(pairs.map { Set([$0.0, $0.1]) })
        XCTAssertTrue(asSet.contains(Set([aFromA.id, cFromB.id])))
        XCTAssertTrue(asSet.contains(Set([bFromA.id, cFromB.id])))
        XCTAssertFalse(asSet.contains(Set([aFromA.id, bFromA.id])))
    }

    func test_pairsToCompare_deterministic_aIDLessThanBID() {
        let urlA = URL(fileURLWithPath: "/a.pdf")
        let urlB = URL(fileURLWithPath: "/b.pdf")
        let a = ConceptNode(label: "1", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlA)], level: .concept)
        let b = ConceptNode(label: "2", type: .concept, summary: nil,
                            sourceAnchors: [anchor(for: urlB)], level: .concept)
        let pairs = EmbeddingResolver.pairsToCompare(among: [a, b])
        XCTAssertEqual(pairs.count, 1)
        XCTAssertLessThan(pairs[0].0.uuidString, pairs[0].1.uuidString)
    }

    // MARK: - classify

    func test_classify_atOrAboveAutoMerge_returnsAutoMerge() {
        let t = ResolverThresholds.default
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.96, thresholds: t), .autoMerge)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.95, thresholds: t), .autoMerge)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 1.0,  thresholds: t), .autoMerge)
    }

    func test_classify_inAdjudicationBand_returnsAdjudication() {
        let t = ResolverThresholds.default
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.85, thresholds: t), .adjudication)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.90, thresholds: t), .adjudication)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.9499, thresholds: t), .adjudication)
    }

    func test_classify_belowFloor_returnsReject() {
        let t = ResolverThresholds.default
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.84, thresholds: t), .reject)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.0,  thresholds: t), .reject)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: -1.0, thresholds: t), .reject)
    }

    func test_classify_customThresholds() {
        let t = ResolverThresholds(autoMerge: 0.99, adjudicationFloor: 0.70, adjudicationBatchSize: 18)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.985, thresholds: t), .adjudication)
        XCTAssertEqual(EmbeddingResolver.classify(similarity: 0.69, thresholds: t), .reject)
    }

    // MARK: - isExactLabelMatch

    func test_isExactLabelMatch_caseInsensitive_true() {
        let a = ConceptNode(label: "Helena Vargas", level: .entity)
        let b = ConceptNode(label: "helena vargas", level: .concept)
        XCTAssertTrue(EmbeddingResolver.isExactLabelMatch(a, b))
    }

    func test_isExactLabelMatch_differentLabels_false() {
        let a = ConceptNode(label: "Helena Vargas", level: .entity)
        let b = ConceptNode(label: "Anna Schultz", level: .entity)
        XCTAssertFalse(EmbeddingResolver.isExactLabelMatch(a, b))
    }

    // MARK: - mergeAdjudication prompt + parser

    func test_mergeAdjudicationPrompt_includesAllPairsAndCount() {
        let a1 = ConceptNode(label: "Helena Vargas", type: .person,
                             summary: "CCQO of VitaCare", level: .entity)
        let b1 = ConceptNode(label: "Helena Vargas", type: .person,
                             summary: nil, level: .concept)
        let a2 = ConceptNode(label: "Labcorp", type: .concept,
                             summary: "Vendor", level: .entity)
        let b2 = ConceptNode(label: "Labcorp", type: .concept,
                             summary: "Reference lab partner", level: .entity)
        let prompt = PromptTemplates.mergeAdjudication(pairs: [(a1, b1), (a2, b2)])
        XCTAssertTrue(prompt.contains("Helena Vargas"))
        XCTAssertTrue(prompt.contains("Labcorp"))
        XCTAssertTrue(prompt.contains("(no summary)"))
        XCTAssertTrue(prompt.contains("CCQO of VitaCare"))
        XCTAssertTrue(prompt.contains("array of 2 booleans"))
        // Cross-level caveat present
        XCTAssertTrue(prompt.contains("different abstraction levels"))
    }

    func test_parseMergeAdjudication_validJSONArray_returnsBools() throws {
        let parsed = try PromptTemplates.parseMergeAdjudicationResponse(
            "[true, false, true]", expectedCount: 3)
        XCTAssertEqual(parsed, [true, false, true])
    }

    func test_parseMergeAdjudication_lengthMismatch_throws() {
        XCTAssertThrowsError(
            try PromptTemplates.parseMergeAdjudicationResponse("[true, false]", expectedCount: 3))
    }

    func test_parseMergeAdjudication_tolerates_codeFences() throws {
        let parsed = try PromptTemplates.parseMergeAdjudicationResponse(
            "```json\n[true, false]\n```", expectedCount: 2)
        XCTAssertEqual(parsed, [true, false])
    }

    func test_parseMergeAdjudication_invalidJSON_throws() {
        XCTAssertThrowsError(
            try PromptTemplates.parseMergeAdjudicationResponse("not json", expectedCount: 1))
    }
}
