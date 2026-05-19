import XCTest
@testable import pdf_app1

/// Tests for `Atlas/Models/KnowledgeGraph.swift` covering the parts that
/// existing test files (FourLevelGraphTests, SCETests) do not pin:
///   - node lifecycle + adjacency, labelIndex sync on rename/remove
///   - edge lifecycle + bi-directional adjacency
///   - query helpers (edges/for, neighbors, degree, nodes(forDocument/forPage))
///   - expansion (toggle, expandAll, collapseAll), `hasChildren`, `childNodes`
///   - clear() wipes everything including labelIndex and highlightColorCounter
///   - nextHighlightColorIndex wraps modulo palette size
///   - documentProcessingState round-trips through encode/decode
///   - SourceAnchor Codable
final class KnowledgeGraphTests: XCTestCase {

    private func anchor(_ url: URL = URL(fileURLWithPath: "/tmp/x.pdf"), page: Int = 0) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    // MARK: - Node lifecycle

    func test_addNode_increasesNodeCountAndIsRetrievableByID() {
        let g = KnowledgeGraph()
        let n = ConceptNode(label: "Alpha")
        g.addNode(n)
        XCTAssertEqual(g.nodeCount, 1)
        XCTAssertEqual(g.node(for: n.id)?.label, "Alpha")
    }

    func test_addNode_isFindableByLabelCaseInsensitive() {
        let g = KnowledgeGraph()
        let n = ConceptNode(label: "Mixed Case Label")
        g.addNode(n)
        XCTAssertEqual(g.node(matching: "mixed case label")?.id, n.id)
        XCTAssertEqual(g.node(matching: "MIXED CASE LABEL")?.id, n.id)
        XCTAssertNil(g.node(matching: "missing"))
    }

    func test_updateNode_rewritesLabelIndexOnRename() {
        let g = KnowledgeGraph()
        var n = ConceptNode(label: "Original")
        g.addNode(n)
        n.label = "Renamed"
        g.updateNode(n)

        XCTAssertNil(g.node(matching: "Original"))
        XCTAssertEqual(g.node(matching: "Renamed")?.id, n.id)
    }

    func test_removeNode_cascadesEdgesAndAdjacency() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); let b = ConceptNode(label: "B"); let c = ConceptNode(label: "C")
        g.addNode(a); g.addNode(b); g.addNode(c)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .dependsOn))
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: c.id, type: .uses))
        g.addEdge(GraphEdge(sourceNodeID: b.id, targetNodeID: c.id, type: .sameTopic))

        XCTAssertEqual(g.edgeCount, 3)
        g.removeNode(a.id)
        // A's two edges should be gone; b↔c remains.
        XCTAssertEqual(g.edgeCount, 1)
        XCTAssertEqual(g.allEdges.first?.type, .sameTopic)
        XCTAssertNil(g.node(for: a.id))
        XCTAssertNil(g.node(matching: "A"))
        XCTAssertEqual(g.degree(of: b.id), 1)
        XCTAssertEqual(g.degree(of: c.id), 1)
    }

    func test_removeNode_unknownIDIsNoOp() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); g.addNode(a)
        g.removeNode(UUID())  // must not crash
        XCTAssertEqual(g.nodeCount, 1)
    }

    // MARK: - Edge lifecycle

    func test_addEdge_recordsAdjacencyOnBothEndpoints() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); g.addNode(a)
        let b = ConceptNode(label: "B"); g.addNode(b)
        let e = GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .dependsOn)
        g.addEdge(e)
        XCTAssertEqual(g.degree(of: a.id), 1)
        XCTAssertEqual(g.degree(of: b.id), 1)
        XCTAssertEqual(g.edges(for: a.id).first?.id, e.id)
        XCTAssertEqual(g.edges(for: b.id).first?.id, e.id)
    }

    func test_removeEdge_updatesAdjacencyAndEdgeCount() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); g.addNode(a)
        let b = ConceptNode(label: "B"); g.addNode(b)
        let e = GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .sameTopic)
        g.addEdge(e)
        g.removeEdge(e.id)
        XCTAssertEqual(g.edgeCount, 0)
        XCTAssertEqual(g.degree(of: a.id), 0)
        XCTAssertEqual(g.degree(of: b.id), 0)
    }

    func test_neighbors_returnsBothDirections() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); g.addNode(a)
        let b = ConceptNode(label: "B"); g.addNode(b)
        let c = ConceptNode(label: "C"); g.addNode(c)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .uses))
        g.addEdge(GraphEdge(sourceNodeID: c.id, targetNodeID: a.id, type: .partOf))

        XCTAssertEqual(Set(g.neighbors(of: a.id).map(\.id)), Set([b.id, c.id]))
        XCTAssertEqual(Set(g.neighbors(of: b.id).map(\.id)), Set([a.id]))
    }

    // MARK: - Document/page queries

    func test_nodesForDocument_andForPage_filterByAnchor() {
        let urlA = URL(fileURLWithPath: "/tmp/a.pdf")
        let urlB = URL(fileURLWithPath: "/tmp/b.pdf")
        let g = KnowledgeGraph()
        let na = ConceptNode(label: "A", sourceAnchors: [anchor(urlA, page: 0)])
        let nb = ConceptNode(label: "B", sourceAnchors: [anchor(urlB, page: 2)])
        let nab = ConceptNode(label: "AB", sourceAnchors: [anchor(urlA, page: 5), anchor(urlB, page: 5)])
        g.addNode(na); g.addNode(nb); g.addNode(nab)

        XCTAssertEqual(Set(g.nodes(forDocument: urlA).map(\.label)), Set(["A", "AB"]))
        XCTAssertEqual(Set(g.nodes(forDocument: urlB).map(\.label)), Set(["B", "AB"]))
        XCTAssertEqual(g.nodes(forPage: 5, in: urlA).map(\.label), ["AB"])
        XCTAssertEqual(g.nodes(forPage: 0, in: urlA).map(\.label), ["A"])
        XCTAssertTrue(g.nodes(forPage: 99, in: urlA).isEmpty)
    }

    // MARK: - Hierarchy queries

    func test_conceptNodes_filtersByLevel() {
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(label: "doc", level: .document))
        g.addNode(ConceptNode(label: "chap", level: .chapter))
        let c = ConceptNode(label: "concept", level: .concept); g.addNode(c)
        g.addNode(ConceptNode(label: "ent", level: .entity))

        let concepts = g.conceptNodes()
        XCTAssertEqual(concepts.map(\.id), [c.id])
    }

    func test_containedChildren_filtersByEdgeTypeAndDirection() {
        let g = KnowledgeGraph()
        let parent = ConceptNode(label: "P", level: .concept); g.addNode(parent)
        let kid = ConceptNode(label: "K", level: .entity); g.addNode(kid)
        let sibling = ConceptNode(label: "S", level: .entity); g.addNode(sibling)

        // Outgoing containsEntity edge: parent → kid
        g.addEdge(GraphEdge(sourceNodeID: parent.id, targetNodeID: kid.id, type: .containsEntity))
        // Wrong-direction edge: sibling → parent (should NOT show as parent's child)
        g.addEdge(GraphEdge(sourceNodeID: sibling.id, targetNodeID: parent.id, type: .containsEntity))
        // Wrong edge type, outgoing
        g.addEdge(GraphEdge(sourceNodeID: parent.id, targetNodeID: sibling.id, type: .sameTopic))

        let children = g.containedChildren(of: parent.id, edgeType: .containsEntity)
        XCTAssertEqual(children.map(\.id), [kid.id])
    }

    func test_parentConcept_returnsFirstParentForEntity() {
        let g = KnowledgeGraph()
        let c1 = ConceptNode(label: "C1", level: .concept); g.addNode(c1)
        let c2 = ConceptNode(label: "C2", level: .concept); g.addNode(c2)
        let ent = ConceptNode(label: "E", level: .entity); g.addNode(ent)
        g.addEdge(GraphEdge(sourceNodeID: c1.id, targetNodeID: ent.id, type: .containsEntity))
        g.addEdge(GraphEdge(sourceNodeID: c2.id, targetNodeID: ent.id, type: .containsEntity))

        let parent = g.parentConcept(of: ent.id)
        XCTAssertNotNil(parent)
        XCTAssertTrue([c1.id, c2.id].contains(parent!.id))
    }

    func test_parentConcept_returnsNilWhenEntityHasNoParent() {
        let g = KnowledgeGraph()
        let ent = ConceptNode(label: "E", level: .entity); g.addNode(ent)
        XCTAssertNil(g.parentConcept(of: ent.id))
    }

    func test_childNodes_returnsAnyContainmentEdgeChild() {
        let g = KnowledgeGraph()
        let doc = ConceptNode(label: "D", level: .document); g.addNode(doc)
        let chap = ConceptNode(label: "Ch", level: .chapter); g.addNode(chap)
        let concept = ConceptNode(label: "Co", level: .concept); g.addNode(concept)
        let other = ConceptNode(label: "U", level: .concept); g.addNode(other)

        g.addEdge(GraphEdge(sourceNodeID: doc.id, targetNodeID: chap.id, type: .containsChapter))
        g.addEdge(GraphEdge(sourceNodeID: chap.id, targetNodeID: concept.id, type: .containsConcept))
        // Non-containment outgoing edge from doc — must NOT count
        g.addEdge(GraphEdge(sourceNodeID: doc.id, targetNodeID: other.id, type: .sameTopic))

        XCTAssertEqual(g.childNodes(of: doc.id).map(\.id), [chap.id])
        XCTAssertEqual(g.childNodes(of: chap.id).map(\.id), [concept.id])
        XCTAssertTrue(g.hasChildren(doc.id))
        XCTAssertTrue(g.hasChildren(chap.id))
        XCTAssertFalse(g.hasChildren(concept.id))
    }

    // MARK: - Expansion

    func test_toggleExpansion_flipsExpandedAndCollapsed_andBumpsGeneration() {
        let g = KnowledgeGraph()
        let n = ConceptNode(label: "X"); g.addNode(n)
        let g0 = g.expansionGeneration
        g.toggleExpansion(n.id)
        XCTAssertEqual(g.node(for: n.id)?.expansionState, .expanded)
        XCTAssertEqual(g.expansionGeneration, g0 + 1)

        g.toggleExpansion(n.id)
        XCTAssertEqual(g.node(for: n.id)?.expansionState, .collapsed)
        XCTAssertEqual(g.expansionGeneration, g0 + 2)
    }

    func test_toggleExpansion_unknownIDIsNoOp() {
        let g = KnowledgeGraph()
        let g0 = g.expansionGeneration
        g.toggleExpansion(UUID())
        XCTAssertEqual(g.expansionGeneration, g0)
    }

    func test_expandAll_thenCollapseAll() {
        let g = KnowledgeGraph()
        g.addNode(ConceptNode(label: "a"))
        g.addNode(ConceptNode(label: "b"))
        g.addNode(ConceptNode(label: "c"))

        g.expandAll()
        XCTAssertTrue(g.allNodes.allSatisfy { $0.expansionState == .expanded })

        g.collapseAll()
        XCTAssertTrue(g.allNodes.allSatisfy { $0.expansionState == .collapsed })
    }

    // MARK: - Highlight color cycling

    func test_nextHighlightColorIndex_wrapsModuloPaletteSize() {
        let g = KnowledgeGraph()
        let palette = SourceHighlightPalette.colors.count
        var first: [Int] = []
        for _ in 0..<palette { first.append(g.nextHighlightColorIndex()) }
        XCTAssertEqual(first, Array(0..<palette))
        XCTAssertEqual(g.nextHighlightColorIndex(), 0, "Should wrap back to zero")
    }

    // MARK: - clear()

    func test_clear_wipesNodesEdgesAdjacencyAndIndices() {
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A"); g.addNode(a)
        let b = ConceptNode(label: "B"); g.addNode(b)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .uses))
        g.documentProcessingState[URL(fileURLWithPath: "/tmp/foo.pdf")] = .processing
        _ = g.nextHighlightColorIndex()

        g.clear()
        XCTAssertEqual(g.nodeCount, 0)
        XCTAssertEqual(g.edgeCount, 0)
        XCTAssertTrue(g.documentProcessingState.isEmpty)
        XCTAssertNil(g.node(matching: "A"))
        // counter should reset, so the next call gives 0 again.
        XCTAssertEqual(g.nextHighlightColorIndex(), 0)
    }

    // MARK: - Codable round-trip

    func test_encodeDecode_roundTripsNodesEdgesAndProcessingState() throws {
        let urlA = URL(fileURLWithPath: "/tmp/round.pdf")
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A", sourceAnchors: [anchor(urlA)], level: .concept)
        let b = ConceptNode(label: "B", sourceAnchors: [anchor(urlA)], level: .entity)
        g.addNode(a); g.addNode(b)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .containsEntity))
        g.documentProcessingState[urlA] = .complete

        let data = try g.encode()
        let restored = KnowledgeGraph()
        try restored.decode(from: data)

        XCTAssertEqual(restored.nodeCount, 2)
        XCTAssertEqual(restored.edgeCount, 1)
        XCTAssertEqual(restored.documentProcessingState[urlA], .complete)
        XCTAssertEqual(restored.allEdges.first?.type, .containsEntity)
        XCTAssertEqual(Set(restored.allNodes.map(\.label)), Set(["A", "B"]))
    }

    func test_decode_clearsExistingStateBeforeLoading() throws {
        let g1 = KnowledgeGraph()
        g1.addNode(ConceptNode(label: "Persistent"))
        let data = try g1.encode()

        let g2 = KnowledgeGraph()
        g2.addNode(ConceptNode(label: "ShouldBeWiped"))
        try g2.decode(from: data)

        XCTAssertEqual(g2.nodeCount, 1)
        XCTAssertEqual(g2.allNodes.first?.label, "Persistent")
        XCTAssertNil(g2.node(matching: "ShouldBeWiped"))
    }

    // MARK: - SourceAnchor Codable

    func test_sourceAnchor_codableRoundTrip() throws {
        let original = SourceAnchor(
            documentURL: URL(fileURLWithPath: "/tmp/anchor.pdf"),
            pageIndex: 7,
            boundingBox: CGRect(x: 1, y: 2, width: 3, height: 4),
            textSnippet: "quoted span"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceAnchor.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.documentURL, original.documentURL)
        XCTAssertEqual(decoded.pageIndex, 7)
        XCTAssertEqual(decoded.boundingBox, original.boundingBox)
        XCTAssertEqual(decoded.textSnippet, "quoted span")
    }

    // MARK: - merge — additional edge cases

    func test_merge_addsNewNodesWithoutCollision() {
        let g1 = KnowledgeGraph()
        g1.addNode(ConceptNode(label: "Existing"))
        let g2 = KnowledgeGraph()
        g2.addNode(ConceptNode(label: "Incoming"))

        g1.merge(from: g2)
        XCTAssertEqual(Set(g1.allNodes.map(\.label)), Set(["Existing", "Incoming"]))
    }

    func test_merge_carriesProcessingStateOverwritingOnURL() {
        let url = URL(fileURLWithPath: "/tmp/merge.pdf")
        let g1 = KnowledgeGraph()
        g1.documentProcessingState[url] = .processing
        let g2 = KnowledgeGraph()
        g2.documentProcessingState[url] = .complete

        g1.merge(from: g2)
        XCTAssertEqual(g1.documentProcessingState[url], .complete)
    }
}
