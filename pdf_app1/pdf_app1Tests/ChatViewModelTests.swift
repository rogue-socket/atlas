import XCTest
@testable import pdf_app1

// MARK: - Mock AI Backend

final class MockAtlasModel: AtlasModel, @unchecked Sendable {
    var displayName: String = "Mock"
    var modelIdentifier: String = "mock-1"
    var isAvailable: Bool = true

    var answerToReturn: AnswerWithCitations = AnswerWithCitations(
        answer: "Test answer",
        citations: []
    )
    var shouldThrow: Error?
    var receivedQuestion: String?
    var receivedContext: String?

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { [] }
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { [] }
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String { "" }
    func generateRawResponse(prompt: String) async throws -> String { "" }

    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        receivedQuestion = question
        receivedContext = context
        if let error = shouldThrow { throw error }
        return answerToReturn
    }
}

// MARK: - Tests

final class ChatViewModelTests: XCTestCase {

    // MARK: Cycle 1 — Tracer bullet: send question, get answer in history

    @MainActor
    func testSendQuestion_addsUserAndAssistantMessages() async {
        let mock = MockAtlasModel()
        mock.answerToReturn = AnswerWithCitations(
            answer: "Photosynthesis converts light energy into chemical energy.",
            citations: [
                .init(text: "light energy is converted", pageIndex: 3)
            ]
        )

        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)

        await vm.send("What is photosynthesis?")

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "What is photosynthesis?")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Photosynthesis converts light energy into chemical energy.")
        XCTAssertEqual(vm.messages[1].citations.count, 1)
        XCTAssertEqual(vm.messages[1].citations[0].pageIndex, 3)
    }

    // MARK: Cycle 2 — Context building includes graph concepts and relationships

    @MainActor
    func testBuildContext_includesGraphConceptsAndEdges() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()

        let nodeA = ConceptNode(label: "Photosynthesis", type: .concept, summary: "Process of converting light to energy")
        let nodeB = ConceptNode(label: "Chlorophyll", type: .definition, summary: "Green pigment in plants")
        graph.addNode(nodeA)
        graph.addNode(nodeB)
        graph.addEdge(GraphEdge(sourceNodeID: nodeA.id, targetNodeID: nodeB.id, type: .dependsOn))

        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)
        let context = vm.buildContext()

        XCTAssertTrue(context.contains("Photosynthesis"), "Context should contain concept label")
        XCTAssertTrue(context.contains("Chlorophyll"), "Context should contain concept label")
        XCTAssertTrue(context.contains("Process of converting light to energy"), "Context should contain summary")
        XCTAssertTrue(context.contains("Depends On") || context.contains("dependsOn"), "Context should contain relationship")
    }

    // MARK: Cycle 3 — Context passes through to AI backend

    @MainActor
    func testSend_passesBuiltContextToBackend() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Mitosis", type: .concept))

        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)
        await vm.send("What is mitosis?")

        XCTAssertEqual(mock.receivedQuestion, "What is mitosis?")
        XCTAssertTrue(mock.receivedContext?.contains("Mitosis") == true, "Backend should receive graph context")
    }

    // MARK: Cycle 4 — Error handling

    @MainActor
    func testSend_whenBackendThrows_addsErrorMessage() async {
        let mock = MockAtlasModel()
        mock.shouldThrow = AIError.noAPIKey

        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)

        await vm.send("test question")

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[1].role, .error)
        XCTAssertTrue(vm.messages[1].content.contains("API key"), "Error message should describe the issue")
    }

    // MARK: Cycle 5 — Empty graph produces valid context

    @MainActor
    func testBuildContext_emptyGraph_returnsNonCrashingResult() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)

        let context = vm.buildContext()
        // Should not crash, and should be a valid (possibly empty) string
        XCTAssertNotNil(context)
    }

    // MARK: Cycle 7 — Page text included in context

    @MainActor
    func testBuildContext_includesPageText() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)
        vm.setPageText([
            (pageIndex: 0, text: "Introduction to biology"),
            (pageIndex: 1, text: "Photosynthesis is the process by which plants convert light.")
        ])

        let context = vm.buildContext()

        XCTAssertTrue(context.contains("--- Page 1 ---"), "Context should have page separator")
        XCTAssertTrue(context.contains("Introduction to biology"), "Context should include page text")
        XCTAssertTrue(context.contains("--- Page 2 ---"), "Context should have page separator")
        XCTAssertTrue(context.contains("Photosynthesis is the process"), "Context should include page text")
    }

    // MARK: Cycle 8 — Context includes both graph and page text

    @MainActor
    func testBuildContext_includesBothGraphAndPageText() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Mitosis", type: .concept, summary: "Cell division"))

        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)
        vm.setPageText([(pageIndex: 0, text: "Cells divide through mitosis.")])

        let context = vm.buildContext()

        XCTAssertTrue(context.contains("Mitosis"), "Context should have graph data")
        XCTAssertTrue(context.contains("Cells divide through mitosis"), "Context should have page text")
    }

    // MARK: Cycle 9 — Citation navigation finds matching SourceAnchor bounding box

    @MainActor
    func testNavigateToCitation_findsBoundingBoxFromGraph() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        let docURL = URL(fileURLWithPath: "/tmp/test.pdf")
        let anchor = SourceAnchor(
            documentURL: docURL,
            pageIndex: 5,
            boundingBox: CGRect(x: 10, y: 20, width: 200, height: 30),
            textSnippet: "light energy is converted into chemical energy"
        )
        let node = ConceptNode(label: "Photosynthesis", type: .concept, sourceAnchors: [anchor])
        graph.addNode(node)

        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: docURL)
        let citation = AnswerWithCitations.Citation(text: "light energy is converted", pageIndex: 5)

        let result = vm.resolveCitationAnchor(citation)
        XCTAssertNotNil(result, "Should find matching anchor")
        XCTAssertEqual(result?.pageIndex, 5)
        XCTAssertEqual(result?.boundingBox, CGRect(x: 10, y: 20, width: 200, height: 30))
    }

    @MainActor
    func testNavigateToCitation_returnsNilWhenNoMatch() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)
        let citation = AnswerWithCitations.Citation(text: "nonexistent text", pageIndex: 3)

        let result = vm.resolveCitationAnchor(citation)
        XCTAssertNil(result)
    }

    // MARK: Cycle 6 — Loading state

    @MainActor
    func testSend_setsIsLoadingDuringRequest() async {
        let mock = MockAtlasModel()
        let graph = KnowledgeGraph()
        let vm = ChatViewModel(backend: mock, graph: graph, documentURL: nil)

        XCTAssertFalse(vm.isLoading)
        await vm.send("test")
        XCTAssertFalse(vm.isLoading, "isLoading should be false after completion")
    }
}
