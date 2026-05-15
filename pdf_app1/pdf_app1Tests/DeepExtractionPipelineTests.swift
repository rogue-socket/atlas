import XCTest

@testable import pdf_app1

// MARK: - Mock Backend for Deep Pipeline

final class MockDeepBackend: AtlasModel, @unchecked Sendable {
    let displayName = "Mock Deep"
    let modelIdentifier = "mock-deep"
    var isAvailable: Bool = true

    var generateCalls: [String] = []
    var responsesForPass: [Int: String] = [:]
    private var callCount = 0

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { [] }
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { [] }
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String { "" }
    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        AnswerWithCitations(answer: "", citations: [])
    }

    func generateRawResponse(prompt: String) async throws -> String {
        callCount += 1
        generateCalls.append(prompt)
        // Pass 1 calls happen per-chunk, Pass 2 is one call, Pass 3 is one call
        // Determine which pass based on prompt content
        if prompt.contains("fact extraction") {
            return responsesForPass[1] ?? "{\"facts\":[]}"
        } else if prompt.contains("organizing extracted facts") {
            return responsesForPass[2] ?? "{\"concepts\":[]}"
        } else if prompt.contains("Cross-Referencing") || prompt.contains("knowledge map") {
            return responsesForPass[3] ?? "[]"
        }
        return "{}"
    }
}

// MARK: - Tests

final class DeepExtractionPipelineTests: XCTestCase {

    private func makeDocumentURL() -> URL {
        URL(fileURLWithPath: "/tmp/test-document.pdf")
    }

    // MARK: - Slice 1: Tracer bullet — 3-pass pipeline produces nodes and edges

    func testFullPipelineProducesNodesAndEdges() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        // Pass 1: return facts about DNA replication
        backend.responsesForPass[1] = """
        {
          "facts": [
            {"claim": "DNA replication is semi-conservative", "textSpan": "DNA replication is semi-conservative", "type": "claim", "confidence": 0.95},
            {"claim": "Helicase unwinds the double helix", "textSpan": "Helicase unwinds the double helix", "type": "definition", "confidence": 0.9}
          ]
        }
        """

        // Pass 2: cluster into one concept with one entity
        backend.responsesForPass[2] = """
        {
          "concepts": [
            {
              "label": "DNA Replication",
              "type": "concept",
              "summary": "The process of copying DNA",
              "level": "concept",
              "factIndices": [0, 1],
              "entities": [
                {
                  "label": "Helicase",
                  "type": "definition",
                  "summary": "Enzyme that unwinds DNA",
                  "parentLabel": "DNA Replication",
                  "factIndices": [1]
                }
              ]
            }
          ]
        }
        """

        // Pass 3: one edge
        backend.responsesForPass[3] = """
        [
          {"sourceLabel": "DNA Replication", "targetLabel": "Helicase", "type": "uses", "confidence": 0.85}
        ]
        """

        let chunks = [
            TextChunk(text: "DNA replication is semi-conservative. Helicase unwinds the double helix.", pageRange: 0..<3, documentURL: docURL)
        ]

        await pipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: docURL)

        XCTAssertFalse(pipeline.isProcessing)
        XCTAssertGreaterThanOrEqual(graph.nodeCount, 2, "Should have at least concept + entity")
        XCTAssertGreaterThanOrEqual(graph.edgeCount, 1, "Should have at least one edge")

        let dnaNode = graph.allNodes.first { $0.label == "DNA Replication" }
        XCTAssertNotNil(dnaNode, "Should have DNA Replication concept")
        XCTAssertEqual(dnaNode?.level, .concept)

        let helicaseNode = graph.allNodes.first { $0.label == "Helicase" }
        XCTAssertNotNil(helicaseNode, "Should have Helicase entity")
        XCTAssertEqual(helicaseNode?.level, .entity)

        // Parent-concept relationship is now expressed as a containsEntity edge
        // from concept → entity (replaces the old parentConceptID field).
        let hasContainsEdge = graph.allEdges.contains { e in
            e.type == .containsEntity &&
            e.sourceNodeID == dnaNode?.id &&
            e.targetNodeID == helicaseNode?.id
        }
        XCTAssertTrue(hasContainsEdge, "DNA Replication should contain Helicase via containsEntity edge")
    }

    // MARK: - Slice 2: Cross-page deduplication

    func testCrossPageDeduplication() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        // Pass 1: facts from two different chunks mention same topic
        backend.responsesForPass[1] = """
        {
          "facts": [
            {"claim": "DNA replication occurs in S phase", "textSpan": "DNA replication occurs in S phase", "type": "claim", "confidence": 0.95},
            {"claim": "Replication uses primase", "textSpan": "Replication uses primase", "type": "claim", "confidence": 0.9}
          ]
        }
        """

        // Pass 2: clusters reference facts from both chunks into ONE concept
        backend.responsesForPass[2] = """
        {
          "concepts": [
            {
              "label": "DNA Replication",
              "type": "concept",
              "summary": "DNA copying process in S phase",
              "level": "concept",
              "factIndices": [0, 1, 2, 3],
              "entities": null
            }
          ]
        }
        """

        backend.responsesForPass[3] = "[]"

        // Two chunks from different page ranges
        let chunks = [
            TextChunk(text: "DNA replication occurs in S phase", pageRange: 3..<5, documentURL: docURL),
            TextChunk(text: "Replication uses primase", pageRange: 6..<8, documentURL: docURL)
        ]

        await pipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: docURL)

        let dnaNodes = graph.allNodes.filter { $0.label == "DNA Replication" }
        XCTAssertEqual(dnaNodes.count, 1, "Should deduplicate into one node")

        let node = dnaNodes.first!
        XCTAssertGreaterThanOrEqual(node.sourceAnchors.count, 2, "Should have anchors from both page ranges")

        let pages = Set(node.sourceAnchors.map { $0.pageIndex })
        XCTAssertTrue(pages.contains(3), "Should have anchor from page range 3-5")
        XCTAssertTrue(pages.contains(6), "Should have anchor from page range 6-8")
    }

    // MARK: - Slice 3: Progress reporting

    func testProgressReporting() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        backend.responsesForPass[1] = """
        {"facts": [{"claim": "Test fact", "textSpan": "Test fact", "type": "claim", "confidence": 0.9}]}
        """
        backend.responsesForPass[2] = """
        {"concepts": [{"label": "Test Concept", "type": "concept", "summary": "A test", "level": "concept", "factIndices": [0], "entities": null}]}
        """
        backend.responsesForPass[3] = "[]"

        let chunks = [
            TextChunk(text: "Test fact", pageRange: 0..<2, documentURL: docURL)
        ]

        await pipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: docURL)

        // After completion, currentPass should be 3 (last pass) and isProcessing should be false
        XCTAssertEqual(pipeline.currentPass, 3)
        XCTAssertFalse(pipeline.isProcessing)
        XCTAssertTrue(pipeline.statusMessage.contains("Done"), "Status should indicate completion")
    }

    // MARK: - Slice 4: cross-reference edges from Pass 3 (dependsOn, etc.)

    func testCrossReferenceEdgesFromPass3() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        backend.responsesForPass[1] = """
        {"facts": [
            {"claim": "Genetics studies heredity", "textSpan": "Genetics studies heredity", "type": "claim", "confidence": 0.9},
            {"claim": "DNA replication copies genetic material", "textSpan": "DNA replication copies genetic material", "type": "claim", "confidence": 0.9}
        ]}
        """

        backend.responsesForPass[2] = """
        {"concepts": [
            {"label": "Genetics", "type": "concept", "summary": "Study of heredity", "level": "concept", "factIndices": [0], "entities": null},
            {"label": "DNA Replication", "type": "concept", "summary": "Copying genetic material", "level": "concept", "factIndices": [1], "entities": null}
        ]}
        """

        // subtopicOf is retired under the 4-level model; pass 3 now emits
        // cross-concept relationships like dependsOn / sameTopic.
        backend.responsesForPass[3] = """
        [{"sourceLabel": "DNA Replication", "targetLabel": "Genetics", "type": "dependsOn", "confidence": 0.9}]
        """

        let chunks = [
            TextChunk(text: "Genetics studies heredity. DNA replication copies genetic material.", pageRange: 0..<3, documentURL: docURL)
        ]

        await pipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: docURL)

        let dependsEdges = graph.allEdges.filter { $0.type == .dependsOn }
        XCTAssertEqual(dependsEdges.count, 1, "Should have one dependsOn edge from cross-reference")

        let edge = dependsEdges.first!
        let source = graph.node(for: edge.sourceNodeID)
        let target = graph.node(for: edge.targetNodeID)
        XCTAssertEqual(source?.label, "DNA Replication")
        XCTAssertEqual(target?.label, "Genetics")
    }

    // MARK: - Slice 5: Pass ordering — each pass receives distinct prompts

    func testPassOrdering() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        backend.responsesForPass[1] = """
        {"facts": [{"claim": "A fact", "textSpan": "A fact", "type": "claim", "confidence": 0.9}]}
        """
        backend.responsesForPass[2] = """
        {"concepts": [{"label": "Test", "type": "concept", "summary": "Test", "level": "concept", "factIndices": [0], "entities": null}]}
        """
        backend.responsesForPass[3] = "[]"

        let chunks = [
            TextChunk(text: "A fact", pageRange: 0..<1, documentURL: docURL)
        ]

        await pipeline.processChunks(chunks, backend: backend, graph: graph, documentURL: docURL)

        // Should have exactly 3 generateRawResponse calls: 1 per pass
        XCTAssertEqual(backend.generateCalls.count, 3, "Should make exactly 3 AI calls (one per pass)")

        // Verify call order by checking prompt content
        XCTAssertTrue(backend.generateCalls[0].contains("fact extraction"), "First call should be fact extraction")
        XCTAssertTrue(backend.generateCalls[1].contains("organizing extracted facts"), "Second call should be clustering")
        XCTAssertTrue(backend.generateCalls[2].contains("knowledge map"), "Third call should be cross-referencing")
    }

    // MARK: - Edge case: empty input

    func testEmptyChunksProducesNothing() async {
        let backend = MockDeepBackend()
        let graph = KnowledgeGraph()
        let pipeline = DeepExtractionPipeline()
        let docURL = makeDocumentURL()

        await pipeline.processChunks([], backend: backend, graph: graph, documentURL: docURL)

        XCTAssertEqual(graph.nodeCount, 0)
        XCTAssertEqual(graph.edgeCount, 0)
        XCTAssertFalse(pipeline.isProcessing)
    }
}
