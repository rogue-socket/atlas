import XCTest
@testable import pdf_app1

/// Tests for L2 — `ChapterEdgeAggregation` projects lower-level
/// relational edges onto chapter/document rollups so high-level tabs can
/// show relationships.
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

    private func build(_ graph: KnowledgeGraph,
                       document: String,
                       chapter: String,
                       concept: String) -> (document: ConceptNode, chapter: ConceptNode, concept: ConceptNode) {
        let doc = ConceptNode(label: document, level: .document)
        let built = build(graph, chapter: chapter, concept: concept)
        graph.addNode(doc)
        graph.addEdge(GraphEdge(sourceNodeID: doc.id, targetNodeID: built.chapter.id, type: .containsChapter))
        return (doc, built.chapter, built.concept)
    }

    private func addEntity(_ label: String, to concept: ConceptNode, in graph: KnowledgeGraph) -> ConceptNode {
        let entity = ConceptNode(label: label, level: .entity)
        graph.addNode(entity)
        graph.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: entity.id, type: .containsEntity))
        return entity
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
        XCTAssertEqual(chapterEdges.first?.label, "rolls up: depends on")
    }

    func test_synthesize_usesChildEdgeLabelForSingleRollup() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A1")
        let b = build(g, chapter: "Ch B", concept: "Concept B1")
        g.addEdge(GraphEdge(
            sourceNodeID: a.concept.id,
            targetNodeID: b.concept.id,
            type: .dependsOn,
            label: "manufacturing dependency"
        ))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a.chapter.id && $0.targetNodeID == b.chapter.id && $0.type == .dependsOn
        }
        XCTAssertEqual(chapterEdge?.label, "rolls up: manufacturing dependency")
    }

    func test_synthesize_summarizesMultipleChildEdgesForSameChapterPair() {
        let g = KnowledgeGraph()
        let a1 = build(g, chapter: "Ch A", concept: "Concept A1")
        let b1 = build(g, chapter: "Ch B", concept: "Concept B1")
        let a2 = ConceptNode(label: "Concept A2", level: .concept)
        let b2 = ConceptNode(label: "Concept B2", level: .concept)
        g.addNode(a2)
        g.addNode(b2)
        g.addEdge(GraphEdge(sourceNodeID: a1.chapter.id, targetNodeID: a2.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: b1.chapter.id, targetNodeID: b2.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: a1.concept.id, targetNodeID: b1.concept.id, type: .dependsOn))
        g.addEdge(GraphEdge(sourceNodeID: a2.id, targetNodeID: b2.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a1.chapter.id && $0.targetNodeID == b1.chapter.id && $0.type == .dependsOn
        }
        XCTAssertEqual(chapterEdge?.label, "aggregates 2: depends on")
    }

    func test_synthesize_emitsDocumentEdgeForCrossDocumentConceptEdge() {
        let g = KnowledgeGraph()
        let a = build(g, document: "Doc A", chapter: "Ch A", concept: "Concept A")
        let b = build(g, document: "Doc B", chapter: "Ch B", concept: "Concept B")
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: b.concept.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 2)

        let documentEdge = g.allEdges.first {
            $0.sourceNodeID == a.document.id && $0.targetNodeID == b.document.id && $0.type == .dependsOn
        }
        XCTAssertEqual(documentEdge?.label, "rolls up: depends on")
    }

    func test_synthesize_skipsDocumentEdgeWithinSameDocument() {
        let g = KnowledgeGraph()
        let doc = ConceptNode(label: "Doc A", level: .document)
        let a = build(g, chapter: "Ch A", concept: "Concept A")
        let b = build(g, chapter: "Ch B", concept: "Concept B")
        g.addNode(doc)
        g.addEdge(GraphEdge(sourceNodeID: doc.id, targetNodeID: a.chapter.id, type: .containsChapter))
        g.addEdge(GraphEdge(sourceNodeID: doc.id, targetNodeID: b.chapter.id, type: .containsChapter))
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: b.concept.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let documentEdges = g.allEdges.filter {
            $0.sourceNodeID == doc.id && $0.targetNodeID == doc.id && $0.type == .dependsOn
        }
        XCTAssertTrue(documentEdges.isEmpty)
    }

    func test_synthesize_refreshesExistingDocumentRollupLabel() {
        let g = KnowledgeGraph()
        let a = build(g, document: "Doc A", chapter: "Ch A", concept: "Concept A")
        let b = build(g, document: "Doc B", chapter: "Ch B", concept: "Concept B")
        g.addEdge(GraphEdge(
            sourceNodeID: a.concept.id,
            targetNodeID: b.concept.id,
            type: .dependsOn,
            label: "manufacturing dependency"
        ))
        g.addEdge(GraphEdge(
            sourceNodeID: a.chapter.id,
            targetNodeID: b.chapter.id,
            type: .dependsOn,
            confidence: 0.7,
            label: "aggregated"
        ))
        g.addEdge(GraphEdge(
            sourceNodeID: a.document.id,
            targetNodeID: b.document.id,
            type: .dependsOn,
            confidence: 0.7,
            label: "aggregated"
        ))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 0)

        let documentEdge = g.allEdges.first {
            $0.sourceNodeID == a.document.id && $0.targetNodeID == b.document.id && $0.type == .dependsOn
        }
        XCTAssertEqual(documentEdge?.label, "rolls up: manufacturing dependency")
    }

    func test_synthesize_rollsUpEntityToEntityEdgesThroughParentConcepts() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A")
        let b = build(g, chapter: "Ch B", concept: "Concept B")
        let entityA = addEntity("Entity A", to: a.concept, in: g)
        let entityB = addEntity("Entity B", to: b.concept, in: g)
        g.addEdge(GraphEdge(
            sourceNodeID: entityA.id,
            targetNodeID: entityB.id,
            type: .processFor,
            label: "manufacturing process"
        ))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a.chapter.id && $0.targetNodeID == b.chapter.id && $0.type == .processFor
        }
        XCTAssertEqual(chapterEdge?.label, "rolls up: manufacturing process")
    }

    func test_synthesize_rollsUpConceptToEntityEdgesThroughParentConcepts() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A")
        let b = build(g, chapter: "Ch B", concept: "Concept B")
        let entityB = addEntity("Entity B", to: b.concept, in: g)
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: entityB.id, type: .dependsOn))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 1)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a.chapter.id && $0.targetNodeID == b.chapter.id && $0.type == .dependsOn
        }
        XCTAssertEqual(chapterEdge?.label, "rolls up: depends on")
    }

    func test_synthesize_refreshesExistingRollupLabelWhenChildEdgeCountChanges() {
        let g = KnowledgeGraph()
        let a1 = build(g, chapter: "Ch A", concept: "Concept A1")
        let b1 = build(g, chapter: "Ch B", concept: "Concept B1")
        let a2 = ConceptNode(label: "Concept A2", level: .concept)
        let b2 = ConceptNode(label: "Concept B2", level: .concept)
        g.addNode(a2)
        g.addNode(b2)
        g.addEdge(GraphEdge(sourceNodeID: a1.chapter.id, targetNodeID: a2.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: b1.chapter.id, targetNodeID: b2.id, type: .containsConcept))
        g.addEdge(GraphEdge(sourceNodeID: a1.concept.id, targetNodeID: b1.concept.id, type: .dependsOn))
        g.addEdge(GraphEdge(sourceNodeID: a2.id, targetNodeID: b2.id, type: .dependsOn))
        g.addEdge(GraphEdge(
            sourceNodeID: a1.chapter.id,
            targetNodeID: b1.chapter.id,
            type: .dependsOn,
            confidence: 0.7,
            label: "rolls up: depends on"
        ))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 0)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a1.chapter.id && $0.targetNodeID == b1.chapter.id && $0.type == .dependsOn
        }
        XCTAssertEqual(chapterEdge?.label, "aggregates 2: depends on")
    }

    func test_synthesize_refreshesExistingGenericAggregatedLabel() {
        let g = KnowledgeGraph()
        let a = build(g, chapter: "Ch A", concept: "Concept A1")
        let b = build(g, chapter: "Ch B", concept: "Concept B1")
        g.addEdge(GraphEdge(sourceNodeID: a.concept.id, targetNodeID: b.concept.id, type: .dependsOn))
        g.addEdge(GraphEdge(
            sourceNodeID: a.chapter.id,
            targetNodeID: b.chapter.id,
            type: .dependsOn,
            confidence: 0.7,
            label: "aggregated"
        ))

        let added = ChapterEdgeAggregation.synthesize(in: g)
        XCTAssertEqual(added, 0)

        let chapterEdge = g.allEdges.first {
            $0.sourceNodeID == a.chapter.id && $0.targetNodeID == b.chapter.id && $0.type == .dependsOn
        }
        XCTAssertEqual(chapterEdge?.label, "rolls up: depends on")
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
