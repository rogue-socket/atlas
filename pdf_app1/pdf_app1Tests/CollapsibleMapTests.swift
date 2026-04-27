import Foundation

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", file: String = #file, line: Int = #line) {
    guard a == b else {
        print("FAIL [\(file):\(line)]: \(msg.isEmpty ? "\(a) != \(b)" : msg)")
        exit(1)
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "", file: String = #file, line: Int = #line) {
    guard condition else {
        print("FAIL [\(file):\(line)]: \(msg.isEmpty ? "expected true" : msg)")
        exit(1)
    }
}

// MARK: - Test: childNodes(of:) returns children connected via subtopicOf edges

func testChildNodesViaSubtopicOf() {
    let graph = KnowledgeGraph()

    let theme = ConceptNode(label: "Cellular Respiration", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Glycolysis", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Krebs Cycle", type: .concept, hierarchyLevel: 1)
    let unrelated = ConceptNode(label: "Photosynthesis", type: .concept, hierarchyLevel: 0)

    graph.addNode(theme)
    graph.addNode(sub1)
    graph.addNode(sub2)
    graph.addNode(unrelated)

    // subtopicOf edges: sub1 and sub2 are children of theme
    graph.addEdge(GraphEdge(sourceNodeID: sub1.id, targetNodeID: theme.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub2.id, targetNodeID: theme.id, type: .subtopicOf))

    let children = graph.childNodes(of: theme.id)
    let childIDs = Set(children.map(\.id))

    assertEqual(children.count, 2, "theme should have 2 children")
    assertTrue(childIDs.contains(sub1.id), "sub1 should be a child")
    assertTrue(childIDs.contains(sub2.id), "sub2 should be a child")

    let unrelatedChildren = graph.childNodes(of: unrelated.id)
    assertEqual(unrelatedChildren.count, 0, "unrelated node should have no children")

    print("PASS: testChildNodesViaSubtopicOf")
}

// MARK: - Test: level0Nodes() returns only hierarchyLevel == 0 nodes

func testLevel0Nodes() {
    let graph = KnowledgeGraph()

    let theme1 = ConceptNode(label: "Theme 1", type: .concept, hierarchyLevel: 0)
    let theme2 = ConceptNode(label: "Theme 2", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Sub 1", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Sub 2", type: .concept, hierarchyLevel: 2)

    graph.addNode(theme1)
    graph.addNode(theme2)
    graph.addNode(sub1)
    graph.addNode(sub2)

    let level0 = graph.level0Nodes()
    assertEqual(level0.count, 2, "should have 2 level-0 nodes")
    let ids = Set(level0.map(\.id))
    assertTrue(ids.contains(theme1.id))
    assertTrue(ids.contains(theme2.id))

    print("PASS: testLevel0Nodes")
}

// MARK: - Test: DensityManager returns only level-0 when all collapsed at .concept zoom

func testCollapsedGraphShowsOnlyLevel0() {
    let graph = KnowledgeGraph()

    let theme1 = ConceptNode(label: "Theme 1", type: .concept, hierarchyLevel: 0)
    let theme2 = ConceptNode(label: "Theme 2", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Sub 1", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Sub 2", type: .concept, hierarchyLevel: 1)
    let sub3 = ConceptNode(label: "Sub 3", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme1)
    graph.addNode(theme2)
    graph.addNode(sub1)
    graph.addNode(sub2)
    graph.addNode(sub3)

    graph.addEdge(GraphEdge(sourceNodeID: sub1.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub2.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub3.id, targetNodeID: theme2.id, type: .subtopicOf))

    // All nodes default to .collapsed
    let dm = DensityManager()
    let visible = dm.visibleNodes(from: graph, zoomLevel: .concept)

    let visibleIDs = Set(visible.map(\.id))
    assertEqual(visible.count, 2, "only 2 level-0 nodes should be visible, got \(visible.count)")
    assertTrue(visibleIDs.contains(theme1.id), "theme1 should be visible")
    assertTrue(visibleIDs.contains(theme2.id), "theme2 should be visible")
    assertTrue(!visibleIDs.contains(sub1.id), "sub1 should NOT be visible")

    print("PASS: testCollapsedGraphShowsOnlyLevel0")
}

// MARK: - Test: Expanding a node reveals its subtopicOf children

func testExpandRevealsChildren() {
    let graph = KnowledgeGraph()

    let theme1 = ConceptNode(label: "Theme 1", type: .concept, hierarchyLevel: 0)
    let theme2 = ConceptNode(label: "Theme 2", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Sub 1", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Sub 2", type: .concept, hierarchyLevel: 1)
    let sub3 = ConceptNode(label: "Sub 3", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme1)
    graph.addNode(theme2)
    graph.addNode(sub1)
    graph.addNode(sub2)
    graph.addNode(sub3)

    graph.addEdge(GraphEdge(sourceNodeID: sub1.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub2.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub3.id, targetNodeID: theme2.id, type: .subtopicOf))

    // Expand theme1
    graph.toggleExpansion(theme1.id)

    let dm = DensityManager()
    let visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    let visibleIDs = Set(visible.map(\.id))

    // theme1's children should now be visible
    assertTrue(visibleIDs.contains(sub1.id), "sub1 should be visible after expanding theme1")
    assertTrue(visibleIDs.contains(sub2.id), "sub2 should be visible after expanding theme1")
    // theme2's child should still be hidden
    assertTrue(!visibleIDs.contains(sub3.id), "sub3 should NOT be visible (theme2 still collapsed)")
    // Both themes always visible
    assertTrue(visibleIDs.contains(theme1.id))
    assertTrue(visibleIDs.contains(theme2.id))

    print("PASS: testExpandRevealsChildren")
}

// MARK: - Test: Collapsing hides children again

func testCollapseHidesChildren() {
    let graph = KnowledgeGraph()

    let theme = ConceptNode(label: "Theme", type: .concept, hierarchyLevel: 0)
    let sub = ConceptNode(label: "Sub", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme)
    graph.addNode(sub)
    graph.addEdge(GraphEdge(sourceNodeID: sub.id, targetNodeID: theme.id, type: .subtopicOf))

    let dm = DensityManager()

    // Expand then collapse
    graph.toggleExpansion(theme.id)
    var visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(Set(visible.map(\.id)).contains(sub.id), "sub should be visible when expanded")

    graph.toggleExpansion(theme.id)
    visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(!Set(visible.map(\.id)).contains(sub.id), "sub should be hidden after collapsing")

    print("PASS: testCollapseHidesChildren")
}

// MARK: - Test: Multi-parent — child visible if ANY parent expanded

func testMultiParentVisibility() {
    let graph = KnowledgeGraph()

    let theme1 = ConceptNode(label: "Cellular Respiration", type: .concept, hierarchyLevel: 0)
    let theme2 = ConceptNode(label: "Photosynthesis", type: .concept, hierarchyLevel: 0)
    let atp = ConceptNode(label: "ATP", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme1)
    graph.addNode(theme2)
    graph.addNode(atp)

    // ATP is a subtopic of both themes
    graph.addEdge(GraphEdge(sourceNodeID: atp.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: atp.id, targetNodeID: theme2.id, type: .subtopicOf))

    let dm = DensityManager()

    // Neither expanded — ATP hidden
    var visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(!Set(visible.map(\.id)).contains(atp.id), "ATP hidden when both parents collapsed")

    // Expand theme1 — ATP visible
    graph.toggleExpansion(theme1.id)
    visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(Set(visible.map(\.id)).contains(atp.id), "ATP visible when theme1 expanded")

    // Collapse theme1, expand theme2 — ATP still visible
    graph.toggleExpansion(theme1.id)
    graph.toggleExpansion(theme2.id)
    visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(Set(visible.map(\.id)).contains(atp.id), "ATP visible when theme2 expanded")

    // Collapse theme2 — ATP hidden again
    graph.toggleExpansion(theme2.id)
    visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertTrue(!Set(visible.map(\.id)).contains(atp.id), "ATP hidden when both collapsed again")

    print("PASS: testMultiParentVisibility")
}

// MARK: - Test: collapseAll and expandAll

func testCollapseAllExpandAll() {
    let graph = KnowledgeGraph()

    let theme1 = ConceptNode(label: "Theme 1", type: .concept, hierarchyLevel: 0)
    let theme2 = ConceptNode(label: "Theme 2", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Sub 1", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Sub 2", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme1)
    graph.addNode(theme2)
    graph.addNode(sub1)
    graph.addNode(sub2)

    graph.addEdge(GraphEdge(sourceNodeID: sub1.id, targetNodeID: theme1.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub2.id, targetNodeID: theme2.id, type: .subtopicOf))

    let dm = DensityManager()

    // expandAll — all nodes visible
    graph.expandAll()
    var visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertEqual(visible.count, 4, "expandAll should show all 4 nodes")

    // collapseAll — only level-0 visible
    graph.collapseAll()
    visible = dm.visibleNodes(from: graph, zoomLevel: .concept)
    assertEqual(visible.count, 2, "collapseAll should show only 2 level-0 nodes")

    print("PASS: testCollapseAllExpandAll")
}

// MARK: - Test: Edges between hidden nodes are excluded from filtered graph

func testEdgeVisibility() {
    let graph = KnowledgeGraph()

    let theme = ConceptNode(label: "Theme", type: .concept, hierarchyLevel: 0)
    let sub1 = ConceptNode(label: "Sub 1", type: .concept, hierarchyLevel: 1)
    let sub2 = ConceptNode(label: "Sub 2", type: .concept, hierarchyLevel: 1)

    graph.addNode(theme)
    graph.addNode(sub1)
    graph.addNode(sub2)

    graph.addEdge(GraphEdge(sourceNodeID: sub1.id, targetNodeID: theme.id, type: .subtopicOf))
    graph.addEdge(GraphEdge(sourceNodeID: sub2.id, targetNodeID: theme.id, type: .subtopicOf))
    // Edge between two sub-concepts
    let crossEdge = GraphEdge(sourceNodeID: sub1.id, targetNodeID: sub2.id, type: .dependsOn)
    graph.addEdge(crossEdge)

    let dm = DensityManager()

    // Collapsed: only theme visible, no edges should appear
    let visibleCollapsed = dm.visibleNodes(from: graph, zoomLevel: .concept)
    let collapsedIDs = Set(visibleCollapsed.map(\.id))
    let collapsedEdges = graph.allEdges.filter { collapsedIDs.contains($0.sourceNodeID) && collapsedIDs.contains($0.targetNodeID) }
    assertEqual(collapsedEdges.count, 0, "no edges when only theme visible")

    // Expanded: all nodes visible, cross edge appears
    graph.toggleExpansion(theme.id)
    let visibleExpanded = dm.visibleNodes(from: graph, zoomLevel: .concept)
    let expandedIDs = Set(visibleExpanded.map(\.id))
    let expandedEdges = graph.allEdges.filter { expandedIDs.contains($0.sourceNodeID) && expandedIDs.contains($0.targetNodeID) }
    assertTrue(expandedEdges.contains(where: { $0.id == crossEdge.id }), "cross edge should appear when both subs visible")

    print("PASS: testEdgeVisibility")
}

@main
struct TestRunner {
    static func main() {
        testChildNodesViaSubtopicOf()
        testLevel0Nodes()
        testCollapsedGraphShowsOnlyLevel0()
        testExpandRevealsChildren()
        testCollapseHidesChildren()
        testMultiParentVisibility()
        testCollapseAllExpandAll()
        testEdgeVisibility()
        print("\nAll tests passed!")
    }
}
