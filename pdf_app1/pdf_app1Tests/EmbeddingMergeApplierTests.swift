import XCTest
@testable import pdf_app1

/// Tests for ETR stage 4 — `EmbeddingMergeApplier.apply(_:to:)`.
/// Covers union-find transitive closure, canonical pick rule, anchor union,
/// edge rewrite + self-edge drop + tuple dedup.
final class EmbeddingMergeApplierTests: XCTestCase {

    // MARK: - Helpers

    private func anchor(_ url: String, page: Int = 0) -> SourceAnchor {
        SourceAnchor(documentURL: URL(fileURLWithPath: url),
                     pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    private func plan(_ decisions: [(UUID, UUID)]) -> MergePlan {
        MergePlan(decisions: decisions.map {
            MergeDecision(aID: $0.0, bID: $0.1, similarity: 1.0, reason: .highSimilarity)
        }, thresholds: .default)
    }

    // MARK: - apply

    func test_apply_emptyPlan_isNoop() {
        let g = KnowledgeGraph()
        let n = ConceptNode(label: "x", level: .concept)
        g.addNode(n)
        let result = EmbeddingMergeApplier.apply(MergePlan(decisions: [], thresholds: .default), to: g)
        XCTAssertEqual(result.groupsApplied, 0)
        XCTAssertEqual(g.allNodes.count, 1)
    }

    func test_apply_singlePair_collapsesTwoIntoOne() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Helena Vargas", type: .person, summary: nil,
                            sourceAnchors: [anchor("/org.pdf")], level: .entity)
        let b = ConceptNode(label: "Helena Vargas", type: .person, summary: nil,
                            sourceAnchors: [anchor("/cmp.pdf")], level: .entity)
        g.addNode(a); g.addNode(b)

        let result = EmbeddingMergeApplier.apply(plan([(a.id, b.id)]), to: g)
        XCTAssertEqual(result.groupsApplied, 1)
        XCTAssertEqual(result.nodesRemoved, 1)
        XCTAssertEqual(g.allNodes.count, 1)
    }

    func test_apply_chainOfPairs_collapsesToSingleGroupViaTransitiveClosure() {
        let g = KnowledgeGraph()
        let a = make("A", level: .entity, anchors: [anchor("/1.pdf")])
        let b = make("B", level: .entity, anchors: [anchor("/2.pdf")])
        let c = make("C", level: .entity, anchors: [anchor("/3.pdf")])
        let d = make("D", level: .entity, anchors: [anchor("/4.pdf")])
        [a, b, c, d].forEach { g.addNode($0) }
        // Pairs (A,B), (B,C), (C,D) → one group of 4
        let result = EmbeddingMergeApplier.apply(plan([(a.id, b.id), (b.id, c.id), (c.id, d.id)]), to: g)
        XCTAssertEqual(result.groupsApplied, 1)
        XCTAssertEqual(result.nodesRemoved, 3)
        XCTAssertEqual(g.allNodes.count, 1)
    }

    // Hand-build ConceptNode to control sourceAnchors when convenience init
    // signature has anchors-before-level.
    private func make(_ label: String, level: NodeLevel,
                      anchors: [SourceAnchor] = [],
                      modified: Date = Date()) -> ConceptNode {
        ConceptNode(label: label, type: .concept, summary: nil,
                    sourceAnchors: anchors, level: level, lastModified: modified)
    }

    // MARK: - Canonical pick rule

    func test_pickCanonical_higherLevelWins_conceptBeatsEntity() {
        let entity = make("X", level: .entity)
        let concept = make("X", level: .concept)
        let picked = EmbeddingMergeApplier.pickCanonical(from: [entity, concept])
        XCTAssertEqual(picked?.id, concept.id)
    }

    func test_pickCanonical_tieOnLevel_olderLastModifiedWins() {
        let older = make("X", level: .concept, modified: Date(timeIntervalSince1970: 100))
        let newer = make("X", level: .concept, modified: Date(timeIntervalSince1970: 200))
        let picked = EmbeddingMergeApplier.pickCanonical(from: [newer, older])
        XCTAssertEqual(picked?.id, older.id)
    }

    func test_apply_levelPromotion_survivorTakesHigherLevel() {
        let g = KnowledgeGraph()
        let entity = make("X", level: .entity, anchors: [anchor("/a.pdf")])
        let concept = make("X", level: .concept, anchors: [anchor("/b.pdf")])
        g.addNode(entity); g.addNode(concept)
        EmbeddingMergeApplier.apply(plan([(entity.id, concept.id)]), to: g)
        XCTAssertEqual(g.allNodes.count, 1)
        XCTAssertEqual(g.allNodes.first?.level, .concept)
    }

    // MARK: - Anchor union

    func test_apply_unionsSourceAnchorsFromAllMembers() {
        let g = KnowledgeGraph()
        let a = make("X", level: .entity, anchors: [anchor("/a.pdf", page: 1)])
        let b = make("X", level: .entity, anchors: [anchor("/b.pdf", page: 2)])
        let c = make("X", level: .entity, anchors: [anchor("/c.pdf", page: 3)])
        [a, b, c].forEach { g.addNode($0) }
        EmbeddingMergeApplier.apply(plan([(a.id, b.id), (b.id, c.id)]), to: g)
        XCTAssertEqual(g.allNodes.count, 1)
        let surviving = g.allNodes.first!
        XCTAssertEqual(Set(surviving.sourceAnchors.map { $0.documentURL.lastPathComponent }),
                       ["a.pdf", "b.pdf", "c.pdf"])
    }

    func test_apply_anchorDedupsIdenticalKeys() {
        let g = KnowledgeGraph()
        let dup = anchor("/a.pdf", page: 1)
        let a = make("X", level: .entity, anchors: [dup])
        let b = make("X", level: .entity, anchors: [dup])
        g.addNode(a); g.addNode(b)
        EmbeddingMergeApplier.apply(plan([(a.id, b.id)]), to: g)
        XCTAssertEqual(g.allNodes.first?.sourceAnchors.count, 1)
    }

    // MARK: - Edge rewrite / self-edge drop / dedup

    func test_apply_rewritesEdgeEndpointsToCanonical() {
        let g = KnowledgeGraph()
        let a = make("A", level: .entity, anchors: [anchor("/1.pdf")])
        let b = make("B", level: .entity, anchors: [anchor("/2.pdf")])
        let x = make("X", level: .concept, anchors: [anchor("/3.pdf")])
        [a, b, x].forEach { g.addNode($0) }
        // Edge from A → X. After merging (A,B) the edge endpoint A should
        // remain pointing at whichever survives (canonical of {A,B}).
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: x.id, type: .dependsOn))
        EmbeddingMergeApplier.apply(plan([(a.id, b.id)]), to: g)
        let survivor = g.allNodes.first { $0.label == "A" || $0.label == "B" }!.id
        XCTAssertEqual(g.allEdges.count, 1)
        XCTAssertEqual(g.allEdges.first?.sourceNodeID, survivor)
        XCTAssertEqual(g.allEdges.first?.targetNodeID, x.id)
    }

    func test_apply_dropsSelfEdgesAfterRewrite() {
        let g = KnowledgeGraph()
        let a = make("A", level: .entity, anchors: [anchor("/1.pdf")])
        let b = make("B", level: .entity, anchors: [anchor("/2.pdf")])
        g.addNode(a); g.addNode(b)
        // Edge A → B becomes a self-edge after the merge collapses A and B.
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .dependsOn))
        EmbeddingMergeApplier.apply(plan([(a.id, b.id)]), to: g)
        XCTAssertEqual(g.allEdges.count, 0, "Self-edges from merge should be dropped")
    }

    func test_apply_dedupsEdgesByTuple_keepsHighestConfidence() {
        let g = KnowledgeGraph()
        let a = make("A", level: .entity, anchors: [anchor("/1.pdf")])
        let b = make("B", level: .entity, anchors: [anchor("/2.pdf")])
        let x = make("X", level: .concept, anchors: [anchor("/3.pdf")])
        [a, b, x].forEach { g.addNode($0) }
        // Both A and B independently link to X via dependsOn. After (A,B) merge,
        // we get two A'→X edges of the same type; dedup keeps the higher-conf one.
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: x.id, type: .dependsOn, confidence: 0.5))
        g.addEdge(GraphEdge(sourceNodeID: b.id, targetNodeID: x.id, type: .dependsOn, confidence: 0.9))
        let result = EmbeddingMergeApplier.apply(plan([(a.id, b.id)]), to: g)
        XCTAssertEqual(g.allEdges.count, 1)
        XCTAssertEqual(g.allEdges.first?.confidence, 0.9)
        XCTAssertGreaterThanOrEqual(result.edgesDeduplicated, 1)
    }
}
