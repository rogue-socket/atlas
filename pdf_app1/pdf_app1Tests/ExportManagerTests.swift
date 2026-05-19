import XCTest
@testable import pdf_app1

/// Tests for `Atlas/Export/ExportManager.swift`:
/// pure-string output for all three formats, plus the file-writing path.
final class ExportManagerTests: XCTestCase {

    private func anchor(_ url: URL, page: Int = 3) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    /// Build a small graph: concept A with summary, entity B underneath, and a
    /// dependsOn edge from A to a second concept C.
    private func makeSampleGraph() -> (KnowledgeGraph, URL) {
        let url = URL(fileURLWithPath: "/tmp/export-sample.pdf")
        let graph = KnowledgeGraph()

        let a = ConceptNode(
            id: UUID(),
            label: "Alpha Concept",
            type: .concept,
            summary: "Alpha summary text.",
            sourceAnchors: [anchor(url, page: 2)],
            confidence: 0.9,
            level: .concept
        )
        let c = ConceptNode(
            id: UUID(),
            label: "Charlie Concept",
            type: .theorem,
            summary: nil,
            sourceAnchors: [anchor(url, page: 5)],
            confidence: 1.0,
            level: .concept
        )
        let b = ConceptNode(
            id: UUID(),
            label: "Bravo Entity",
            type: .definition,
            summary: "Bravo definition.",
            sourceAnchors: [anchor(url, page: 3)],
            confidence: 0.75,
            level: .entity
        )
        graph.addNode(a)
        graph.addNode(c)
        graph.addNode(b)
        graph.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: c.id, type: .dependsOn, label: "requires"))
        graph.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .containsEntity))

        return (graph, url)
    }

    // MARK: - Obsidian format

    func test_obsidianExport_groupsByTypeAndUsesWikilinks() {
        let (graph, _) = makeSampleGraph()
        let out = ExportManager().export(graph: graph, format: .obsidian, projectName: "Demo")

        XCTAssertTrue(out.hasPrefix("# Demo"))
        // Type-header grouping (display names are capitalized).
        XCTAssertTrue(out.contains("## Concepts"),  "Should group concept-type nodes")
        XCTAssertTrue(out.contains("## Theorems"),  "Should group theorem-type nodes")
        XCTAssertTrue(out.contains("## Definitions"), "Should group entity-level definition nodes")
        // Nodes are listed under '### <label>'.
        XCTAssertTrue(out.contains("### Alpha Concept"))
        XCTAssertTrue(out.contains("### Bravo Entity"))
        XCTAssertTrue(out.contains("### Charlie Concept"))
        // Summary line and wikilink-style connection lines.
        XCTAssertTrue(out.contains("Alpha summary text."))
        XCTAssertTrue(out.contains("[[Charlie Concept]]"))
        XCTAssertTrue(out.contains("[[Bravo Entity]]"))
        // Source line (page index is 0-based internally; printed 1-based).
        XCTAssertTrue(out.contains("export-sample.pdf, page 3"), "page index 2 should be printed as page 3")
    }

    // MARK: - Markdown format

    func test_markdownExport_includesCountsAndConfidence() {
        let (graph, _) = makeSampleGraph()
        let out = ExportManager().export(graph: graph, format: .markdown, projectName: "Demo")
        XCTAssertTrue(out.contains("Demo — Knowledge Map"))
        XCTAssertTrue(out.contains("**\(graph.nodeCount) concepts, \(graph.edgeCount) connections**"))
        // Confidence is rendered as a percentage.
        XCTAssertTrue(out.contains("Confidence: 90%"), "Alpha confidence 0.9 → '90%'")
        XCTAssertTrue(out.contains("Confidence: 75%"), "Bravo confidence 0.75 → '75%'")
        XCTAssertTrue(out.contains("**Depends On**"))
    }

    // MARK: - JSON format

    func test_jsonExport_isWellFormedAndIncludesNodesAndEdges() throws {
        let (graph, _) = makeSampleGraph()
        let json = ExportManager().export(graph: graph, format: .json)
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        let nodes = obj?["nodes"] as? [[String: Any]]
        let edges = obj?["edges"] as? [[String: Any]]
        XCTAssertEqual(nodes?.count, 3)
        XCTAssertEqual(edges?.count, 2)
    }

    // MARK: - exportToFile

    func test_exportToFile_writesContentToTemporaryDirectory() throws {
        let (graph, _) = makeSampleGraph()
        let mgr = ExportManager()
        let url = mgr.exportToFile(graph: graph, format: .markdown, projectName: "WriteOut-\(UUID().uuidString.prefix(6))")
        XCTAssertNotNil(url)
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("Knowledge Map"))
    }

    func test_exportToFile_jsonChoosesJSONExtension() {
        let (graph, _) = makeSampleGraph()
        let url = ExportManager().exportToFile(graph: graph, format: .json, projectName: "JSON-\(UUID().uuidString.prefix(6))")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.pathExtension, "json")
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    func test_exportEmptyGraph_yieldsHeaderOnly() {
        let empty = KnowledgeGraph()
        let mgr = ExportManager()
        let md = mgr.export(graph: empty, format: .markdown, projectName: "Empty")
        XCTAssertTrue(md.contains("Empty — Knowledge Map"))
        XCTAssertTrue(md.contains("**0 concepts, 0 connections**"))

        let obs = mgr.export(graph: empty, format: .obsidian, projectName: "Empty")
        XCTAssertEqual(obs.trimmingCharacters(in: .whitespacesAndNewlines), "# Empty")

        let json = mgr.export(graph: empty, format: .json)
        let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed)
    }
}
