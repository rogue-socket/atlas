import XCTest
@testable import pdf_app1

final class EmbeddingResolverStructuralBoostTests: XCTestCase {

    private func node(_ label: String, level: NodeLevel = .entity, type: ConceptType = .definition) -> ConceptNode {
        ConceptNode(label: label, type: type, level: level)
    }

    func test_acronymOverlap_detectsInitialismInLongerLabel() {
        let a = node("Lab Result Communication")
        let b = node("LRC policy")
        XCTAssertTrue(EmbeddingResolver.hasAcronymOrTokenOverlap(a, b))
        XCTAssertGreaterThan(EmbeddingResolver.structuralBoost(a: a, b: b, graph: KnowledgeGraph()), 0)
    }

    func test_significantTokenOverlap_sharedWord() {
        let a = node("Revenue share")
        let b = node("E-commerce revenue share")
        XCTAssertTrue(EmbeddingResolver.hasAcronymOrTokenOverlap(a, b))
    }

    func test_sharesChapterContext_sameChapterParent() {
        let g = KnowledgeGraph()
        let ch = node("Clinical Services", level: .chapter, type: .concept)
        let c1 = node("Pricing", level: .concept, type: .concept)
        let c2 = node("Packages", level: .concept, type: .concept)
        g.addNode(ch)
        g.addNode(c1)
        g.addNode(c2)
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c1.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c2.id, type: .containsConcept))
        XCTAssertTrue(EmbeddingResolver.sharesChapterContext(c1, c2, graph: g))
    }

    func test_sharesNeighborLabel_siblingEntitiesUnderConcepts() {
        let g = KnowledgeGraph()
        let concept = node("Care coordination", level: .concept, type: .concept)
        let e1 = node("Care coordinator")
        let e2 = node("Coordinator role")
        g.addNode(concept)
        g.addNode(e1)
        g.addNode(e2)
        g.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e1.id, type: .containsEntity))
        g.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e2.id, type: .containsEntity))
        let shared = node("Care coordinator")
        g.addNode(shared)
        g.addEdge(GraphEdge(sourceNodeID: e1.id, targetNodeID: shared.id, type: .sameTopic))
        g.addEdge(GraphEdge(sourceNodeID: e2.id, targetNodeID: shared.id, type: .sameTopic))
        XCTAssertTrue(EmbeddingResolver.sharesNeighborLabel(e1, e2, graph: g))
    }

    func test_sharesNeighborLabel_ignoresContainmentParents() {
        let g = KnowledgeGraph()
        let concept = node("Care coordination", level: .concept, type: .concept)
        let e1 = node("Care coordinator")
        let e2 = node("Coordinator role")
        g.addNode(concept)
        g.addNode(e1)
        g.addNode(e2)
        g.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e1.id, type: .containsEntity))
        g.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e2.id, type: .containsEntity))
        XCTAssertFalse(EmbeddingResolver.sharesNeighborLabel(e1, e2, graph: g))
    }

    func test_structuralBoost_capped() {
        let g = KnowledgeGraph()
        let ch = node("Ch", level: .chapter, type: .concept)
        let c1 = node("Alpha Beta Gamma", level: .concept, type: .concept)
        let c2 = node("Alpha Beta Delta", level: .concept, type: .concept)
        g.addNode(ch)
        g.addNode(c1)
        g.addNode(c2)
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c1.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c2.id, type: .containsConcept))
        XCTAssertLessThanOrEqual(EmbeddingResolver.structuralBoost(a: c1, b: c2, graph: g),
                                 EmbeddingResolver.structuralBoostCap + 0.001)
    }
}
