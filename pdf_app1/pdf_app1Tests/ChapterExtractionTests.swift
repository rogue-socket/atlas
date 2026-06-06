import XCTest
@testable import pdf_app1

/// Tests for `ChapterExtraction.attachConceptsToChapters` — the post-extraction
/// pass that links concept nodes to the chapter(s) whose page range overlaps
/// the concept's source anchors. The chapter-detection sources (PDF outline,
/// LLM) are integration paths covered by manual testing; this file pins the
/// pure-graph attach step that the extraction pipeline always runs.
final class ChapterExtractionTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/chapters.pdf")

    private func anchor(page: Int) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    private func chapterNode(_ label: String, startPage: Int) -> ConceptNode {
        ConceptNode(label: label, type: .concept,
                    sourceAnchors: [anchor(page: startPage)],
                    level: .chapter)
    }

    private func conceptNode(_ label: String, pages: [Int]) -> ConceptNode {
        ConceptNode(label: label, type: .concept,
                    sourceAnchors: pages.map { anchor(page: $0) },
                    level: .concept)
    }

    // MARK: - Basic attach

    func test_attach_linksConceptToOwningChapter() {
        let graph = KnowledgeGraph()
        // Two chapters: A covers pages 0–4, B covers pages 5–9.
        let chA = chapterNode("A", startPage: 0); graph.addNode(chA)
        let chB = chapterNode("B", startPage: 5); graph.addNode(chB)
        let concept = conceptNode("Topic", pages: [3]); graph.addNode(concept)

        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)

        let containsEdges = graph.allEdges.filter { $0.type == .containsConcept }
        XCTAssertEqual(containsEdges.count, 1)
        XCTAssertEqual(containsEdges.first?.sourceNodeID, chA.id)
        XCTAssertEqual(containsEdges.first?.targetNodeID, concept.id)
    }

    func test_attach_isIdempotentAcrossMultipleCalls() {
        let graph = KnowledgeGraph()
        let chA = chapterNode("A", startPage: 0); graph.addNode(chA)
        let chB = chapterNode("B", startPage: 5); graph.addNode(chB)
        let concept = conceptNode("Topic", pages: [3]); graph.addNode(concept)

        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)
        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)

        let containsEdges = graph.allEdges.filter { $0.type == .containsConcept }
        XCTAssertEqual(containsEdges.count, 1, "Re-running attach must not duplicate edges")
    }

    func test_attach_multiAnchorConceptLinksToEveryOverlappingChapter() {
        // Concept appears on pages 3 (chapter A: 0–4) and 7 (chapter B: 5–end).
        // Multi-parent semantics → two containsConcept edges.
        let graph = KnowledgeGraph()
        let chA = chapterNode("A", startPage: 0); graph.addNode(chA)
        let chB = chapterNode("B", startPage: 5); graph.addNode(chB)
        let concept = conceptNode("Spans", pages: [3, 7]); graph.addNode(concept)

        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)

        let containsEdges = graph.allEdges.filter { $0.type == .containsConcept }
        XCTAssertEqual(containsEdges.count, 2)
        let sourceIDs = Set(containsEdges.map(\.sourceNodeID))
        XCTAssertEqual(sourceIDs, Set([chA.id, chB.id]))
    }

    func test_attach_finalChapterCoversUpToEndOfDocument() {
        // Chapter A: starts at 0. Chapter B: starts at 5 and (per reconstruction)
        // covers everything from 5 to Int.max. A concept on page 999 should
        // land under chapter B.
        let graph = KnowledgeGraph()
        let chA = chapterNode("A", startPage: 0); graph.addNode(chA)
        let chB = chapterNode("B", startPage: 5); graph.addNode(chB)
        let concept = conceptNode("Late", pages: [999]); graph.addNode(concept)

        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)

        let containsEdges = graph.allEdges.filter { $0.type == .containsConcept }
        XCTAssertEqual(containsEdges.count, 1)
        XCTAssertEqual(containsEdges.first?.sourceNodeID, chB.id)
    }

    func test_attach_isNoOpWhenNoChaptersForDocument() {
        // No chapter nodes — must not crash, must not create edges.
        let graph = KnowledgeGraph()
        let concept = conceptNode("Topic", pages: [3]); graph.addNode(concept)
        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)
        XCTAssertTrue(graph.allEdges.filter { $0.type == .containsConcept }.isEmpty)
    }

    func test_attach_scopesChaptersToTheGivenDocument() {
        // Chapter in document A; concept in document B — must not link.
        let urlOther = URL(fileURLWithPath: "/tmp/other.pdf")
        let graph = KnowledgeGraph()
        let chOther = ConceptNode(
            label: "Other chapter",
            sourceAnchors: [SourceAnchor(documentURL: urlOther, pageIndex: 0,
                                          boundingBox: .zero, textSnippet: "")],
            level: .chapter
        )
        graph.addNode(chOther)
        let concept = conceptNode("Topic", pages: [3]); graph.addNode(concept)

        ChapterExtraction.attachConceptsToChapters(graph: graph, documentURL: url)
        XCTAssertTrue(graph.allEdges.filter { $0.type == .containsConcept }.isEmpty)
    }
}
