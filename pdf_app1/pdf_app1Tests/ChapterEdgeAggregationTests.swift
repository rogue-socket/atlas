import XCTest
@testable import pdf_app1

/// Tests for L2 — `ChapterEdgeAggregation` projects concept-level
/// relational edges onto chapter-level edges so the Chapter tab can
/// show inter-chapter relationships.
final class ChapterEdgeAggregationTests: XCTestCase {

    private func build(_ graph: KnowledgeGraph,
                       chapter: String,
                       concept: String) -> (chapter: ConceptNode, concept: ConceptNode) {
        let ch = ConceptNode(label: chapter, level: .chapter)
        let co = ConceptNode(label: concept, level: .concept)
        graph.addNode(ch)
        graph.addNode(co)
        graph.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: co.id, type: .containsConcept))
        return (ch, co)
    }

    func test_synthesize_emitsChapterEdgeForCrossChapterConceptEdge() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A1")
        let b = build(g, chapter: "Ch B", concept: "Concept B1")
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: b.concept.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let chapterEdges = g.allEdges.filter {
            $0.sourceNodeID == a.chapter.id && $0.targetNodeID == b.chapter.id
        }
        XCTAssertEqual(chapterEdges.count, 1)
        XCTAssertEqual(chapterEdges.first?.type, .dependsOn)
        XCTAssertEqual(chapterEdges.first?.label, "aggregated")
    }

    func test_synthesize_skipsConceptEdgesWithinSameChapter() {
        let g = KnowledgeGraph()
        let ch = ConceptNode(label: "Ch A", level: .chapter)
        let c1 = ConceptNode(label: "Concept 1", level: .concept)
        let c2 = ConceptNode(label: "Concept 2", level: .concept)
        g.addNode(ch); g.addNode(c1); g.addNode(c2)
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c1.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: ch.id, targetNodeID: c2.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: c1.id, targetNodeID: c2.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 0, "Same-chapter concept edge produces no chapter-level edge")
    }

    func test_synthesize_skipsContainmentEdges() {
        // A containsConcept edge between two concepts shouldn't project
        // into a chapter-level edge — we only aggregate relational edges.
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A")
        let b = build(g, chapter: "Ch B", concept: "Concept B")
        // (No relational edge between concepts.)
        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 0)
        _ = (a, b)
    }

    func test_synthesize_isIdempotent() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A")
        let b = build(g, chapter: "Ch B", concept: "Concept B")
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: b.concept.id, type: .dependsOn))

        let first = ChapterEdgeAggregation.synthesize(in: g)
        let second = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 0, "Re-running should add zero new edges")
    }

    func test_synthesize_emitsForEveryChapterPair_whenConceptHasMultipleParents() {
        // Concept A1 is contained by chapters X and Y; concept B1 by chapter Z.
        // A1 → B1 (dependsOn) should produce two chapter edges:
        // X → Z and Y → Z.
        let g = KnowledgeGraph()
        let chX = ConceptNode(label: "Ch X", level: .chapter)
        let chY = ConceptNode(label: "Ch Y", level: .chapter)
        let chZ = ConceptNode(label: "Ch Z", level: .chapter)
        let cA = ConceptNode(label: "A1", level: .concept)
        let cB = ConceptNode(label: "B1", level: .concept)
        for n in [chX, chY, chZ, cA, cB] { g.addNode(n) }
        g.addEdge(GraphEdge(sourceNodeID: chX.id, targetNodeID: cA.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: chY.id, targetNodeID: cA.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: chZ.id, targetNodeID: cB.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: cA.id, targetNodeID: cB.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 2)

        let chapterEdges = g.allEdges.filter { edge in
            (edge.sourceNodeID == chX.id || edge.sourceNodeID == chY.id) &&
            edge.targetNodeID == chZ.id &&
            edge.type == .dependsOn
        }
        XCTAssertEqual(chapterEdges.count, 2)
    }
}
