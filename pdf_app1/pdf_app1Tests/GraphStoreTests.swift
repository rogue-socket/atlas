import XCTest
@testable import pdf_app1

/// Tests for `GraphStore` save/load/delete/loadProjectWideGraph.
/// Uses unique URLs so the per-doc filename hash avoids collisions with
/// any real persisted state in `~/Library/Application Support/Atlas/graphs/`.
final class GraphStoreTests: XCTestCase {

    private func uniqueURL() -> URL {
        URL(fileURLWithPath: "/tmp/atlas-graphstore-test-\(UUID().uuidString).pdf")
    }

    private func anchor(_ url: URL, page: Int = 0) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    // Force the debounced save to complete synchronously before we assert.
    private func flushAndYield() async throws {
        GraphStore.shared.flushPendingSave()
        // Yield so any straggler dispatch is also drained.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - hasGraph / load when nothing is saved

    func test_hasGraph_isFalseWhenNothingSaved() {
        let url = uniqueURL()
        XCTAssertFalse(GraphStore.shared.hasGraph(for: url))
        XCTAssertNil(GraphStore.shared.load(for: url))
        XCTAssertNil(GraphStore.shared.loadPayload(for: url))
    }

    // MARK: - Save → load round-trip

    func test_save_then_loadRoundTripsNodesAndEdges() async throws {
        let url = uniqueURL()
        let graph = KnowledgeGraph()
        let a = ConceptNode(label: "RoundTripA", sourceAnchors: [anchor(url)], level: .concept)
        let b = ConceptNode(label: "RoundTripB", sourceAnchors: [anchor(url)], level: .entity)
        graph.addNode(a)
        graph.addNode(b)
        graph.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .containsEntity))

        GraphStore.shared.scheduleSave(graph, for: url)
        try await flushAndYield()

        defer { GraphStore.shared.deleteGraph(for: url) }
        XCTAssertTrue(GraphStore.shared.hasGraph(for: url))
        let loaded = GraphStore.shared.load(for: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.nodeCount, 2)
        XCTAssertEqual(loaded?.edgeCount, 1)
        XCTAssertNotNil(loaded?.node(matching: "RoundTripA"))
    }

    // MARK: - Delete

    func test_delete_removesPersistedFile() async throws {
        let url = uniqueURL()
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "X", sourceAnchors: [anchor(url)], level: .concept))
        GraphStore.shared.scheduleSave(graph, for: url)
        try await flushAndYield()

        XCTAssertTrue(GraphStore.shared.hasGraph(for: url))
        GraphStore.shared.deleteGraph(for: url)
        XCTAssertFalse(GraphStore.shared.hasGraph(for: url))
        // Delete is idempotent.
        GraphStore.shared.deleteGraph(for: url)
    }

    // MARK: - Subgraph scoping

    func test_save_onlyPersistsNodesAnchoredInThisURL() async throws {
        // In-memory project graph spans two URLs; per-doc save must only
        // include the nodes anchored to the scope URL.
        let urlA = uniqueURL()
        let urlB = uniqueURL()
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Anode", sourceAnchors: [anchor(urlA)], level: .concept))
        graph.addNode(ConceptNode(label: "Bnode", sourceAnchors: [anchor(urlB)], level: .concept))

        GraphStore.shared.scheduleSave(graph, for: urlA)
        try await flushAndYield()
        defer {
            GraphStore.shared.deleteGraph(for: urlA)
            GraphStore.shared.deleteGraph(for: urlB)
        }

        let restored = GraphStore.shared.load(for: urlA)
        XCTAssertEqual(restored?.allNodes.map(\.label), ["Anode"])
    }

    // MARK: - loadProjectWideGraph

    func test_loadProjectWideGraph_mergesPerDocFilesIntoOneGraph() async throws {
        let urlA = uniqueURL()
        let urlB = uniqueURL()
        let gA = KnowledgeGraph()
        gA.addNode(ConceptNode(label: "OnlyA", sourceAnchors: [anchor(urlA)], level: .concept))
        let gB = KnowledgeGraph()
        gB.addNode(ConceptNode(label: "OnlyB", sourceAnchors: [anchor(urlB)], level: .concept))

        // scheduleSave shares a single debouncer; calling twice back-to-back
        // would cancel the first work item. Flush between saves.
        GraphStore.shared.scheduleSave(gA, for: urlA)
        try await flushAndYield()
        GraphStore.shared.scheduleSave(gB, for: urlB)
        try await flushAndYield()
        defer {
            GraphStore.shared.deleteGraph(for: urlA)
            GraphStore.shared.deleteGraph(for: urlB)
        }

        let merged = GraphStore.shared.loadProjectWideGraph(documentURLs: [urlA, urlB])
        XCTAssertEqual(Set(merged.allNodes.map(\.label)), Set(["OnlyA", "OnlyB"]))
    }

    func test_loadProjectWideGraph_skipsUrlsWithNoSavedFile() async throws {
        let urlA = uniqueURL()
        let urlMissing = uniqueURL()  // never saved
        let gA = KnowledgeGraph()
        gA.addNode(ConceptNode(label: "Alone", sourceAnchors: [anchor(urlA)], level: .concept))
        GraphStore.shared.scheduleSave(gA, for: urlA)
        try await flushAndYield()
        defer { GraphStore.shared.deleteGraph(for: urlA) }

        let merged = GraphStore.shared.loadProjectWideGraph(documentURLs: [urlA, urlMissing])
        XCTAssertEqual(merged.allNodes.map(\.label), ["Alone"])
    }

    // MARK: - flushPendingSave on empty queue

    func test_flushPendingSave_withNothingPendingIsNoOp() {
        GraphStore.shared.flushPendingSave()  // must not crash
    }
}
