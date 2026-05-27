//
//  TourPlayerTests.swift
//  pdf_app1Tests
//

import XCTest

@testable import pdf_app1

private final class MockTourBackend: AtlasModel, @unchecked Sendable {
    let displayName = "Mock Tour"
    let modelIdentifier = "mock-tour"
    var isAvailable: Bool = true

    var lastPrompt: String?
    var response: String = "[]"

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { [] }
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { [] }
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String { "" }
    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        AnswerWithCitations(answer: "", citations: [])
    }
    func generateRawResponse(prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
}

final class TourPlayerTests: XCTestCase {

    private func makeTour(stopCount: Int) -> GuidedTour {
        let stops = (0..<stopCount).map { index in
            TourStop(nodeID: UUID(), narration: "Stop \(index)")
        }
        return GuidedTour(title: "Test Tour", stops: stops)
    }

    func testStartActivatesFirstStop() {
        let player = TourPlayer()
        let tour = makeTour(stopCount: 3)

        player.load(tour)
        player.start()

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentStop?.id, tour.stops[0].id)
    }

    func testNextPreviousSkipAndReplayClampToValidStops() {
        let player = TourPlayer()
        let tour = makeTour(stopCount: 3)
        player.load(tour)
        player.start()

        player.next()
        XCTAssertEqual(player.currentIndex, 1)

        player.skip(to: 2)
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertFalse(player.canGoNext)

        player.next()
        XCTAssertEqual(player.currentIndex, 2)

        player.previous()
        XCTAssertEqual(player.currentIndex, 1)

        player.skip(to: 99)
        XCTAssertEqual(player.currentIndex, 1)

        player.replay()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.isPlaying)
    }

    func testDismissEndsPlaybackAndClearsCurrentStop() {
        let player = TourPlayer()
        player.load(makeTour(stopCount: 2))
        player.start()

        player.dismiss()

        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentStop)
    }

    func testCandidateNodesPreferChaptersThenConcepts() {
        let graph = KnowledgeGraph()
        let chapterA = ConceptNode(label: "Chapter A", level: .chapter)
        let chapterB = ConceptNode(label: "Chapter B", level: .chapter)
        let duplicateChapter = ConceptNode(label: " chapter b ", level: .chapter)
        let conceptA = ConceptNode(label: "Concept A", level: .concept)
        let conceptB = ConceptNode(label: "Concept B", level: .concept)
        graph.addNode(conceptA)
        graph.addNode(chapterB)
        graph.addNode(conceptB)
        graph.addNode(duplicateChapter)
        graph.addNode(chapterA)

        XCTAssertEqual(TourGenerator.candidateNodes(in: graph).map(\.label), ["Chapter A", "Chapter B"])

        let conceptOnly = KnowledgeGraph()
        conceptOnly.addNode(conceptB)
        conceptOnly.addNode(conceptA)

        XCTAssertEqual(TourGenerator.candidateNodes(in: conceptOnly).map(\.label), ["Concept A", "Concept B"])
        XCTAssertTrue(TourGenerator.hasTourCandidates(in: conceptOnly))
    }

    func testCandidateNodesFallBackToConceptsWhenOnlyOneChapterExists() {
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Only Chapter", level: .chapter))
        graph.addNode(ConceptNode(label: "Concept B", level: .concept))
        graph.addNode(ConceptNode(label: "Concept A", level: .concept))

        XCTAssertEqual(TourGenerator.candidateNodes(in: graph).map(\.label), ["Concept A", "Concept B"])
    }

    func testGeneratorDropsHallucinatedStopsAndBuildsTour() async throws {
        let graph = KnowledgeGraph()
        let first = ConceptNode(label: "Foundations", summary: "Start here", level: .chapter)
        let second = ConceptNode(label: "Applications", summary: "Use the basics", level: .chapter)
        graph.addNode(first)
        graph.addNode(second)

        let backend = MockTourBackend()
        backend.response = """
        {
          "title": "Learning Path",
          "stops": [
            {"label": "Foundations", "narration": "Begin with the foundations."},
            {"label": "Applications", "narration": "Apply those ideas."},
            {"label": "Hallucinated", "narration": "Ignore me."}
          ]
        }
        """

        let tour = try await TourGenerator(model: backend).generate(from: graph)

        XCTAssertEqual(tour.title, "Learning Path")
        XCTAssertEqual(tour.stops.count, 2)
        XCTAssertEqual(tour.stops[0].nodeID, first.id)
        XCTAssertEqual(tour.stops[1].nodeID, second.id)
        XCTAssertEqual(tour.stops[1].narration, "Apply those ideas.")
        XCTAssertTrue(backend.lastPrompt?.contains("Foundations") == true)
        XCTAssertTrue(backend.lastPrompt?.contains("Applications") == true)
        XCTAssertTrue(backend.lastPrompt?.contains("self-contained") == true)
    }

    func testGeneratorDropsDuplicateStopsAndFillsEmptyText() async throws {
        let graph = KnowledgeGraph()
        let first = ConceptNode(label: "Foundations", level: .chapter)
        let second = ConceptNode(label: "Applications", level: .chapter)
        graph.addNode(first)
        graph.addNode(second)

        let backend = MockTourBackend()
        backend.response = """
        {
          "title": "   ",
          "stops": [
            {"label": "Foundations", "narration": "   "},
            {"label": "Foundations", "narration": "Duplicate."},
            {"label": "Applications", "narration": "Use the applications to apply the ideas."}
          ]
        }
        """

        let tour = try await TourGenerator(model: backend).generate(from: graph)

        XCTAssertEqual(tour.title, "Guided Tour")
        XCTAssertEqual(tour.stops.count, 2)
        XCTAssertEqual(tour.stops[0].nodeID, first.id)
        XCTAssertEqual(tour.stops[0].narration, "Explore Foundations.")
        XCTAssertEqual(tour.stops[1].nodeID, second.id)
        XCTAssertEqual(tour.stops[1].narration, "Use the applications to apply the ideas.")
    }

    func testGeneratorThrowsWhenOnlyOneStopCanBeResolved() async {
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Foundations", level: .chapter))
        graph.addNode(ConceptNode(label: "Applications", level: .chapter))

        let backend = MockTourBackend()
        backend.response = """
        {"title":"Learning Path","stops":[
          {"label":"Foundations","narration":"Start here."},
          {"label":"Unknown","narration":"No match."}
        ]}
        """

        do {
            _ = try await TourGenerator(model: backend).generate(from: graph)
            XCTFail("Expected insufficient stops error")
        } catch TourGenerationError.insufficientStops {
            // Expected.
        } catch {
            XCTFail("Expected TourGenerationError.insufficientStops, got \(error)")
        }
    }

    func testGeneratorThrowsWhenAllStopsAreHallucinated() async {
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Foundations", level: .chapter))
        graph.addNode(ConceptNode(label: "Applications", level: .chapter))

        let backend = MockTourBackend()
        backend.response = """
        {"title":"Learning Path","stops":[
          {"label":"Unknown","narration":"No match."}
        ]}
        """

        do {
            _ = try await TourGenerator(model: backend).generate(from: graph)
            XCTFail("Expected empty tour error")
        } catch TourGenerationError.empty {
            // Expected.
        } catch {
            XCTFail("Expected TourGenerationError.empty, got \(error)")
        }
    }
}
