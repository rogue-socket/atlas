import XCTest
@testable import pdf_app1

final class MockGuidedTourBackend: AtlasModel, @unchecked Sendable {
    let displayName = "Mock Tour"
    let modelIdentifier = "mock-tour"
    var isAvailable: Bool = true
    var rawResponse: String = "{\"stops\":[]}"
    private(set) var prompts: [String] = []

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { [] }
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { [] }
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String { "" }
    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        AnswerWithCitations(answer: "", citations: [])
    }

    func generateRawResponse(prompt: String) async throws -> String {
        prompts.append(prompt)
        return rawResponse
    }
}

final class GuidedTourGeneratorTests: XCTestCase {
    private let docURL = URL(fileURLWithPath: "/tmp/tour.pdf")

    private func graphWithTourCandidates() -> (KnowledgeGraph, ConceptNode, ConceptNode, ConceptNode) {
        let graph = KnowledgeGraph()
        let anchor = SourceAnchor(documentURL: docURL, pageIndex: 0, boundingBox: .zero, textSnippet: "source")
        let document = ConceptNode(label: "Tour Document", sourceAnchors: [anchor], level: .document)
        let chapter = ConceptNode(label: "Foundations", sourceAnchors: [anchor], level: .chapter)
        let concept = ConceptNode(label: "Cellular Respiration", sourceAnchors: [anchor], level: .concept)
        graph.addNode(document)
        graph.addNode(chapter)
        graph.addNode(concept)
        graph.addEdge(GraphEdge(sourceNodeID: document.id, targetNodeID: chapter.id, type: .containsChapter))
        graph.addEdge(GraphEdge(sourceNodeID: chapter.id, targetNodeID: concept.id, type: .containsConcept))
        return (graph, document, chapter, concept)
    }

    func test_generate_usesLLMStopsAndFiltersUnknownOrDuplicateNodeIDs() async {
        let (graph, document, chapter, _) = graphWithTourCandidates()
        let backend = MockGuidedTourBackend()
        backend.rawResponse = """
        {
          "introduction": "This tour explains the document arc before moving into foundations.",
          "stops": [
            {"nodeID": "\(document.id.uuidString)", "narration": "Start with the document overview."},
            {"nodeID": "\(UUID().uuidString)", "narration": "Unknown node should be ignored."},
            {"nodeID": "\(document.id.uuidString)", "narration": "Duplicate should be ignored."},
            {"nodeID": "\(chapter.id.uuidString)", "narration": "Now that you understand the overview, move into foundations."}
          ]
        }
        """

        let tour = await GuidedTourGenerator.generate(graph: graph, documentURL: docURL, backend: backend)

        XCTAssertEqual(tour?.generatedByModel, "mock-tour")
        XCTAssertEqual(tour?.introduction, "This tour explains the document arc before moving into foundations.")
        XCTAssertEqual(tour?.stops.map(\.nodeID), [document.id, chapter.id])
        XCTAssertEqual(tour?.stops.first?.title, "Tour Document")
        XCTAssertEqual(backend.prompts.count, 1)
        XCTAssertTrue(backend.prompts[0].contains(document.id.uuidString))
    }

    func test_generate_fallsBackToDeterministicTourWhenResponseIsInvalid() async {
        let (graph, document, chapter, _) = graphWithTourCandidates()
        let backend = MockGuidedTourBackend()
        backend.rawResponse = "not json"

        let tour = await GuidedTourGenerator.generate(graph: graph, documentURL: docURL, backend: backend, maxStops: 2)

        XCTAssertEqual(tour?.generatedByModel, "mock-tour-fallback")
        XCTAssertTrue(tour?.introduction.contains("tour") == true)
        XCTAssertFalse(tour?.introduction.contains(".pdf") == true)
        XCTAssertEqual(tour?.stops.map(\.nodeID), [document.id, chapter.id])
        XCTAssertTrue(tour?.stops.last?.narration.contains("Now that") == true)
    }

    func test_tourCandidates_prefersDocumentChapterConceptBeforeEntities() {
        let graph = KnowledgeGraph()
        let anchor = SourceAnchor(documentURL: docURL, pageIndex: 0, boundingBox: .zero, textSnippet: "")
        let entity = ConceptNode(label: "Entity", sourceAnchors: [anchor], level: .entity)
        let concept = ConceptNode(label: "Concept", sourceAnchors: [anchor], level: .concept)
        let document = ConceptNode(label: "Document", sourceAnchors: [anchor], level: .document)
        graph.addNode(entity)
        graph.addNode(concept)
        graph.addNode(document)

        let candidates = GuidedTourGenerator.tourCandidates(in: graph, documentURL: docURL, maxCandidates: 10)

        XCTAssertEqual(candidates.map(\.id), [document.id, concept.id])
    }
}
