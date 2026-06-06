import XCTest
@testable import pdf_app1

/// Tests for the hybrid cross-doc resolver — ETR's extract-then-resolve
/// backbone extended with SCE's typed-relation taxonomy. Covers the hybrid
/// adjudication parser, the verdict→EdgeType mapping, and stage-4 application
/// of typed relations (`MergePlan.relations`) by `EmbeddingMergeApplier`.
final class HybridResolverTests: XCTestCase {

    // MARK: - Fakes

    /// Fixed-vector embedding backend, keyed on the embedding text.
    final class FakeEmbeddingBackend: AtlasEmbeddingBackend, @unchecked Sendable {
        let displayName = "Fake"
        let modelIdentifier: String
        let vectorDimension: Int
        let isAvailable = true
        private let vectorFor: @Sendable (String) -> [Float]
        init(modelID: String = "fake", dim: Int = 2,
             vectorFor: @escaping @Sendable (String) -> [Float]) {
            self.modelIdentifier = modelID
            self.vectorDimension = dim
            self.vectorFor = vectorFor
        }
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map(vectorFor) }
    }

    /// LLM backend that returns one fixed string from `generateRawResponse`.
    final class FixedLLMBackend: AtlasModel, @unchecked Sendable {
        let displayName = "Fixed"
        let modelIdentifier = "fixed-llm"
        let isAvailable = true
        private let response: String
        init(response: String) { self.response = response }
        func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { [] }
        func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { [] }
        func summarizeConcept(_ label: String, sourceText: String) async throws -> String { "" }
        func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
            throw AIError.modelUnavailable("not impl")
        }
        func generateRawResponse(prompt: String) async throws -> String { response }
    }

    // MARK: - Helpers

    private func anchor(_ path: String) -> SourceAnchor {
        SourceAnchor(documentURL: URL(fileURLWithPath: path),
                     pageIndex: 0, boundingBox: .zero, textSnippet: "")
    }

    private func anchor(_ path: String, page: Int, snippet: String) -> SourceAnchor {
        SourceAnchor(documentURL: URL(fileURLWithPath: path),
                     pageIndex: page, boundingBox: .zero, textSnippet: snippet)
    }

    private func node(_ label: String, level: NodeLevel = .concept,
                      doc: String, modified: Date = Date()) -> ConceptNode {
        ConceptNode(label: label, type: .concept, summary: nil,
                    sourceAnchors: [anchor(doc)], level: level, lastModified: modified)
    }

    private func wipeCacheFile(for projectID: UUID) {
        try? FileManager.default.removeItem(at: EmbeddingCacheStore.fileURL(for: projectID))
    }

    // MARK: - parseHybridAdjudicationResponse

    func test_hybridPrompt_includesMetadataAndSourceEvidence() {
        let a = ConceptNode(
            label: "Revenue share",
            type: .result,
            summary: "Percentage of company revenue from a channel.",
            sourceAnchors: [anchor("/docs/pricing.pdf", page: 2, snippet: "E-commerce accounts for 18% of fiscal 2025 revenue.")],
            level: .entity
        )
        let b = ConceptNode(
            label: "E-commerce revenue share",
            type: .result,
            summary: "Share of revenue produced by e-commerce.",
            sourceAnchors: [anchor("/docs/operations.pdf", page: 4, snippet: "Online orders are tracked as the e-commerce revenue share.")],
            level: .entity
        )

        let prompt = PromptTemplates.mergeAdjudicationHybrid(
            candidates: [(a: a, b: b, similarity: 0.88493377, pairKind: .entityEntity)]
        )

        XCTAssertTrue(prompt.contains("pairKind=entityEntity, similarity=0.8849"))
        XCTAssertTrue(prompt.contains("pricing.pdf p.3"))
        XCTAssertTrue(prompt.contains("operations.pdf p.5"))
        XCTAssertTrue(prompt.contains("E-commerce accounts for 18% of fiscal 2025 revenue."))
        XCTAssertTrue(prompt.contains("Use evidence and summaries over label similarity alone."))
        XCTAssertTrue(prompt.contains("Business adjacency is not enough."))
    }

    func test_hybridPrompt_legacyPairsUsePairKindWithNoSimilarity() {
        let a = node("Catalog", doc: "/a.pdf")
        let b = node("Offering", doc: "/b.pdf")

        let prompt = PromptTemplates.mergeAdjudicationHybrid(pairs: [(a: a, b: b)])

        XCTAssertTrue(prompt.contains("pairKind=conceptConcept, similarity=n/a"))
    }

    func test_parse_happyPath_objectArray() throws {
        let raw = #"[{"pair": 1, "verdict": "merge", "direction": "ab"}, {"pair": 2, "verdict": "instance_of", "direction": "ba"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 2)
        XCTAssertEqual(results, [
            AdjudicationResult(verdict: .merge, direction: .ab),
            AdjudicationResult(verdict: .instanceOf, direction: .ba),
        ])
    }

    func test_parse_missingDirection_defaultsToAB() throws {
        let raw = #"[{"pair": 1, "verdict": "process_for"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 1)
        XCTAssertEqual(results, [AdjudicationResult(verdict: .processFor, direction: .ab)])
    }

    func test_parse_unknownVerdict_fallsBackToKeep() throws {
        let raw = #"[{"pair": 1, "verdict": "frobnicate"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 1)
        XCTAssertEqual(results, [AdjudicationResult(verdict: .keep, direction: .ab)])
    }

    func test_parse_shortResponse_padsMissingPairsWithKeep() throws {
        // Two pairs expected, only one answered — the gap must not throw
        // (the lenient-parse robustness fix); missing pair 2 → keep.
        let raw = #"[{"pair": 1, "verdict": "merge"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].verdict, .merge)
        XCTAssertEqual(results[1].verdict, .keep)
    }

    func test_parse_outOfOrderPairFields_matchedByPairNumber() throws {
        let raw = #"[{"pair": 2, "verdict": "merge"}, {"pair": 1, "verdict": "attribute_of"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 2)
        XCTAssertEqual(results[0].verdict, .attributeOf)
        XCTAssertEqual(results[1].verdict, .merge)
    }

    func test_parse_missingPairField_fallsBackToArrayPosition() throws {
        let raw = #"[{"verdict": "merge"}, {"verdict": "keep"}]"#
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 2)
        XCTAssertEqual(results[0].verdict, .merge)
        XCTAssertEqual(results[1].verdict, .keep)
    }

    func test_parse_toleratesCodeFences() throws {
        let raw = "```json\n[{\"pair\": 1, \"verdict\": \"merge\"}]\n```"
        let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: 1)
        XCTAssertEqual(results[0].verdict, .merge)
    }

    func test_parse_notAJSONArray_throws() {
        XCTAssertThrowsError(
            try PromptTemplates.parseHybridAdjudicationResponse("not json at all", expectedCount: 1)
        )
    }

    // MARK: - AdjudicationVerdict → EdgeType

    func test_verdict_edgeTypeMapping() {
        XCTAssertEqual(AdjudicationVerdict.instanceOf.edgeType, .instanceOf)
        XCTAssertEqual(AdjudicationVerdict.attributeOf.edgeType, .attributeOf)
        XCTAssertEqual(AdjudicationVerdict.processFor.edgeType, .processFor)
        XCTAssertNil(AdjudicationVerdict.merge.edgeType)
        XCTAssertNil(AdjudicationVerdict.keep.edgeType)
    }

    // MARK: - EmbeddingMergeApplier — typed relations

    func test_apply_relationOnly_addsDirectedTypedEdge() {
        let g = KnowledgeGraph()
        let leaf = node("Health Coaching", doc: "/a.pdf")
        let catalog = node("VitaCare Services", doc: "/b.pdf")
        g.addNode(leaf); g.addNode(catalog)
        let plan = MergePlan(
            decisions: [],
            relations: [RelationDecision(sourceID: leaf.id, targetID: catalog.id,
                                         edgeType: .instanceOf, similarity: 0.86)],
            thresholds: .default)
        let result = EmbeddingMergeApplier.apply(plan, to: g)
        XCTAssertEqual(result.relationsAdded, 1)
        XCTAssertEqual(g.allNodes.count, 2, "A typed relation keeps both nodes")
        XCTAssertEqual(g.allEdges.count, 1)
        let edge = g.allEdges.first!
        XCTAssertEqual(edge.sourceNodeID, leaf.id)
        XCTAssertEqual(edge.targetNodeID, catalog.id)
        XCTAssertEqual(edge.type, .instanceOf)
    }

    func test_apply_relationEndpointRemapped_whenNodeMergesAway() {
        // b merges into a (a is older → canonical). A relation declared on b
        // must follow the merge and attach to a.
        let g = KnowledgeGraph()
        let a = node("X", level: .entity, doc: "/1.pdf", modified: Date(timeIntervalSince1970: 100))
        let b = node("X", level: .entity, doc: "/2.pdf", modified: Date(timeIntervalSince1970: 200))
        let target = node("Y", doc: "/3.pdf")
        [a, b, target].forEach { g.addNode($0) }
        let plan = MergePlan(
            decisions: [MergeDecision(aID: a.id, bID: b.id, similarity: 1.0, reason: .highSimilarity)],
            relations: [RelationDecision(sourceID: b.id, targetID: target.id,
                                         edgeType: .processFor, similarity: 0.88)],
            thresholds: .default)
        let result = EmbeddingMergeApplier.apply(plan, to: g)
        XCTAssertEqual(result.nodesRemoved, 1)
        XCTAssertEqual(result.relationsAdded, 1)
        XCTAssertEqual(g.allEdges.count, 1)
        XCTAssertEqual(g.allEdges.first?.sourceNodeID, a.id, "Relation followed b→a merge")
        XCTAssertEqual(g.allEdges.first?.targetNodeID, target.id)
    }

    func test_apply_selfRelation_isDropped() {
        // A relation whose endpoints both collapse into the same merged group
        // is a self-edge — drop it.
        let g = KnowledgeGraph()
        let a = node("X", level: .entity, doc: "/1.pdf")
        let b = node("X", level: .entity, doc: "/2.pdf")
        g.addNode(a); g.addNode(b)
        let plan = MergePlan(
            decisions: [MergeDecision(aID: a.id, bID: b.id, similarity: 1.0, reason: .highSimilarity)],
            relations: [RelationDecision(sourceID: a.id, targetID: b.id,
                                         edgeType: .instanceOf, similarity: 0.9)],
            thresholds: .default)
        let result = EmbeddingMergeApplier.apply(plan, to: g)
        XCTAssertEqual(result.relationsAdded, 0)
        XCTAssertEqual(g.allEdges.count, 0)
    }

    func test_apply_relationDedupsAgainstExistingEdge() {
        let g = KnowledgeGraph()
        let a = node("A", doc: "/1.pdf")
        let b = node("B", doc: "/2.pdf")
        g.addNode(a); g.addNode(b)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .instanceOf))
        let plan = MergePlan(
            decisions: [],
            relations: [RelationDecision(sourceID: a.id, targetID: b.id,
                                         edgeType: .instanceOf, similarity: 0.9)],
            thresholds: .default)
        let result = EmbeddingMergeApplier.apply(plan, to: g)
        XCTAssertEqual(result.relationsAdded, 0, "Identical (source,target,type) already present")
        XCTAssertEqual(g.allEdges.count, 1)
    }

    // MARK: - resolve() end-to-end producing a typed relation

    /// Two cross-doc nodes ~0.87 cosine apart land in the adjudication band;
    /// the fake LLM returns an `instance_of` verdict → the plan carries a
    /// typed relation, not a merge.
    func test_resolve_adjudicationRelationVerdict_populatesRelations() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = node("Health Coaching", doc: "/a.pdf")
        let b = node("VitaCare Services", doc: "/b.pdf")
        g.addNode(a); g.addNode(b)
        let backend = FakeEmbeddingBackend(dim: 2) { text in
            text.contains("Health Coaching") ? [1, 0] : [0.87, (1 - 0.87 * 0.87).squareRoot()]
        }
        let llm = FixedLLMBackend(response: #"[{"pair": 1, "verdict": "instance_of", "direction": "ab"}]"#)
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend, llmBackend: llm)
        XCTAssertTrue(plan.decisions.isEmpty, "instance_of verdict is a relation, not a merge")
        XCTAssertEqual(plan.relations.count, 1)
        XCTAssertEqual(plan.relations.first?.edgeType, .instanceOf)
        XCTAssertEqual(Set([plan.relations[0].sourceID, plan.relations[0].targetID]),
                       Set([a.id, b.id]))
    }

    /// Direction "ab" vs "ba" must swap the relation's source/target. Both
    /// runs use the SAME graph (and project cache) so the resolver's internal
    /// pair ordering is identical — only the LLM-reported direction differs.
    func test_resolve_relationDirection_swapsSourceAndTarget() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        g.addNode(node("Health Coaching", doc: "/a.pdf"))
        g.addNode(node("VitaCare Services", doc: "/b.pdf"))
        let backend = FakeEmbeddingBackend(dim: 2) { text in
            text.contains("Health Coaching") ? [1, 0] : [0.87, (1 - 0.87 * 0.87).squareRoot()]
        }
        func resolveDirection(_ direction: String) async throws -> RelationDecision {
            let llm = FixedLLMBackend(
                response: #"[{"pair": 1, "verdict": "instance_of", "direction": ""# + direction + #""}]"#)
            let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                           embeddingBackend: backend, llmBackend: llm)
            return try XCTUnwrap(plan.relations.first)
        }
        let ab = try await resolveDirection("ab")
        let ba = try await resolveDirection("ba")
        XCTAssertEqual(ab.sourceID, ba.targetID, "ba flips the edge endpoints vs ab")
        XCTAssertEqual(ab.targetID, ba.sourceID)
        XCTAssertNotEqual(ab.sourceID, ab.targetID)
    }

    // MARK: - Lexical (embedding-free) candidate generation

    func test_lexicalTokens_lowercasesAndDropsStopwordsAndShortTokens() {
        let toks = EmbeddingResolver.lexicalTokens("The Substance Use Disorder Program")
        XCTAssertEqual(toks, ["substance", "use", "disorder", "program"])
    }

    func test_lexicalCandidatePairs_pairsCrossDocNodesSharingTokens() {
        let a = node("Behavioral Health Services", doc: "/a.pdf")
        let b = node("Behavioral Health Privacy", doc: "/b.pdf")
        let c = node("Lab Result Release", doc: "/b.pdf")
        let cands = EmbeddingResolver.lexicalCandidatePairs(among: [a, b, c])
        XCTAssertEqual(cands.count, 1, "only a↔b share ≥2 significant tokens across docs")
        XCTAssertEqual(Set([cands[0].aID, cands[0].bID]), Set([a.id, b.id]))
        XCTAssertGreaterThan(cands[0].similarity, 0)
    }

    func test_lexicalCandidatePairs_skipsSameDocPairs() {
        let a = node("Behavioral Health Services", doc: "/same.pdf")
        let b = node("Behavioral Health Privacy", doc: "/same.pdf")
        XCTAssertTrue(EmbeddingResolver.lexicalCandidatePairs(among: [a, b]).isEmpty,
                      "same-doc pairs are not cross-doc candidates")
    }

    func test_lexicalCandidatePairs_tieBreaksDeterministicallyBeforeLimit() {
        let nodes = [
            node("Shared Apple", doc: "/a.pdf"),
            node("Shared Banana", doc: "/a.pdf"),
            node("Shared Cherry", doc: "/b.pdf"),
            node("Shared Date", doc: "/b.pdf")
        ]

        let forward = pairLabels(
            EmbeddingResolver.lexicalCandidatePairs(among: nodes, limit: 2),
            nodes: nodes
        )
        let reversed = pairLabels(
            EmbeddingResolver.lexicalCandidatePairs(among: Array(nodes.reversed()), limit: 2),
            nodes: nodes
        )

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward, [
            ["Shared Apple", "Shared Cherry"],
            ["Shared Apple", "Shared Date"]
        ])
    }

    func test_lexicalCandidatePairs_nonPositiveLimitReturnsNoCandidates() {
        let nodes = [
            node("Shared Apple", doc: "/a.pdf"),
            node("Shared Banana", doc: "/b.pdf")
        ]

        XCTAssertEqual(EmbeddingResolver.lexicalCandidatePairs(among: nodes, limit: 0), [])
        XCTAssertEqual(EmbeddingResolver.lexicalCandidatePairs(among: nodes, limit: -1), [])
    }

    private func pairLabels(_ candidates: [MergeCandidate],
                            nodes: [ConceptNode]) -> [[String]] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.label) })
        return candidates.map { candidate in
            [byID[candidate.aID] ?? "", byID[candidate.bID] ?? ""].sorted()
        }
    }

    func test_resolveLexical_dropsLowSimilarityProcessForWithoutProcessCue() async throws {
        let graph = KnowledgeGraph()
        graph.addNode(node("Medicare Conditions of Participation", doc: "/a.pdf"))
        graph.addNode(node("traditional Medicare", doc: "/b.pdf"))
        let llm = FixedLLMBackend(response: #"[{"pair": 1, "verdict": "process_for", "direction": "ab"}]"#)

        let plan = try await EmbeddingResolver.resolveLexical(graph: graph, llmBackend: llm)

        XCTAssertEqual(plan.decisions.count, 0)
        XCTAssertEqual(plan.relations.count, 0)
    }

    func test_resolveLexical_keepsProcessForWithStrongSimilarity() async throws {
        let graph = KnowledgeGraph()
        let process = node("Primary care visit scheduling", doc: "/a.pdf")
        let service = node("Pediatric primary care", doc: "/b.pdf")
        graph.addNode(process)
        graph.addNode(service)
        let llm = FixedLLMBackend(response: #"[{"pair": 1, "verdict": "process_for", "direction": "ab"}]"#)

        let plan = try await EmbeddingResolver.resolveLexical(graph: graph, llmBackend: llm)

        XCTAssertEqual(plan.decisions.count, 0)
        XCTAssertEqual(plan.relations.count, 1)
        XCTAssertEqual(plan.relations.first?.edgeType, .processFor)
        XCTAssertEqual(Set([plan.relations[0].sourceID, plan.relations[0].targetID]),
                       Set([process.id, service.id]))
    }

    func test_resolveLexical_candidateLimitCapsAdjudicationPairs() async throws {
        let graph = KnowledgeGraph()
        graph.addNode(node("Shared Apple", doc: "/a.pdf"))
        graph.addNode(node("Shared Banana", doc: "/a.pdf"))
        graph.addNode(node("Shared Cherry", doc: "/b.pdf"))
        graph.addNode(node("Shared Date", doc: "/b.pdf"))
        let llm = FixedLLMBackend(response: #"""
        [
          {"pair": 1, "verdict": "instance_of", "direction": "ab"},
          {"pair": 2, "verdict": "instance_of", "direction": "ab"},
          {"pair": 3, "verdict": "instance_of", "direction": "ab"},
          {"pair": 4, "verdict": "instance_of", "direction": "ab"}
        ]
        """#)

        let plan = try await EmbeddingResolver.resolveLexical(
            graph: graph,
            llmBackend: llm,
            candidateLimit: 2
        )

        XCTAssertEqual(plan.decisions.count, 0)
        XCTAssertEqual(plan.relations.count, 2)
    }

    func test_resolveLexical_exactLabelAutoMergeIgnoresCandidateLimit() async throws {
        let graph = KnowledgeGraph()
        let a = node("AI", level: .entity, doc: "/a.pdf")
        let b = node("ai", level: .entity, doc: "/b.pdf")
        graph.addNode(a)
        graph.addNode(b)
        let llm = FixedLLMBackend(response: "[]")

        let plan = try await EmbeddingResolver.resolveLexical(
            graph: graph,
            llmBackend: llm,
            candidateLimit: 0
        )

        XCTAssertEqual(plan.decisions.count, 1)
        XCTAssertEqual(plan.decisions.first?.reason, .exactLabel)
        XCTAssertEqual(Set([plan.decisions[0].aID, plan.decisions[0].bID]), Set([a.id, b.id]))
        XCTAssertEqual(plan.relations.count, 0)
    }
}
