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

    private func node(_ label: String, level: NodeLevel = .concept,
                      doc: String, modified: Date = Date()) -> ConceptNode {
        ConceptNode(label: label, type: .concept, summary: nil,
                    sourceAnchors: [anchor(doc)], level: level, lastModified: modified)
    }

    private func wipeCacheFile(for projectID: UUID) {
        try? FileManager.default.removeItem(at: EmbeddingCacheStore.fileURL(for: projectID))
    }

    // MARK: - parseHybridAdjudicationResponse

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
}
