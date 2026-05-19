import XCTest
@testable import pdf_app1

/// Extends `MapInteractionTests.swift` to cover the zoom, hit-test, click,
/// drag, and scroll-wheel paths the existing file does not.
final class MapInteractionMoreTests: XCTestCase {

    private func graphWithOneNode(at pos: CGPoint) -> (MapInteraction, ForceDirectedLayout, KnowledgeGraph, ConceptNode) {
        let m = MapInteraction()
        let layout = ForceDirectedLayout()
        let graph = KnowledgeGraph()
        let node = ConceptNode(label: "Solo")
        graph.addNode(node)
        layout.positions[node.id] = NodePosition(x: pos.x, y: pos.y)
        return (m, layout, graph, node)
    }

    // MARK: - Zoom

    func test_zoomIn_clampsAtMaxFive() {
        let m = MapInteraction()
        m.viewScale = 4.5
        m.zoomIn()
        m.zoomIn()
        XCTAssertLessThanOrEqual(m.viewScale, 5.0)
    }

    func test_zoomOut_clampsAtMinPointOne() {
        let m = MapInteraction()
        m.viewScale = 0.15
        for _ in 0..<10 { m.zoomOut() }
        XCTAssertGreaterThanOrEqual(m.viewScale, 0.1)
    }

    func test_resetZoom_clearsOffsetAndScale() {
        let m = MapInteraction()
        m.viewScale = 2.5
        m.viewOffset = CGPoint(x: 300, y: -100)
        m.resetZoom()
        XCTAssertEqual(m.viewScale, 1.0)
        XCTAssertEqual(m.viewOffset, .zero)
    }

    func test_handleMagnification_anchorsAgainstStartScale() {
        let m = MapInteraction()
        m.viewScale = 1.5
        m.handleMagnificationChanged(2.0)  // starts → 1.5 × 2.0 = 3.0
        XCTAssertEqual(m.viewScale, 3.0, accuracy: 0.001)

        // Mid-gesture: cumulative magnification 1.5 still anchored against 1.5.
        m.handleMagnificationChanged(1.5)
        XCTAssertEqual(m.viewScale, 1.5 * 1.5, accuracy: 0.001)

        // After ended, a new gesture re-anchors against the current scale.
        m.handleMagnificationEnded()
        m.handleMagnificationChanged(2.0)
        XCTAssertEqual(m.viewScale, (1.5 * 1.5) * 2.0, accuracy: 0.001)
    }

    func test_handleMagnification_clampsToScaleBounds() {
        let m = MapInteraction()
        m.viewScale = 0.5
        m.handleMagnificationChanged(0.01)   // 0.5 * 0.01 = 0.005 → clamps to 0.1
        XCTAssertEqual(m.viewScale, 0.1, accuracy: 0.001)

        m.handleMagnificationEnded()
        m.viewScale = 3.0
        m.handleMagnificationChanged(10.0)   // 3 * 10 = 30 → clamps to 5.0
        XCTAssertEqual(m.viewScale, 5.0, accuracy: 0.001)
    }

    // MARK: - hitTest

    func test_hitTest_returnsNodeWhenPointIsInsideNodeRect() {
        let (m, layout, graph, node) = graphWithOneNode(at: CGPoint(x: 200, y: 150))
        // viewScale = 1, viewOffset = .zero. The node's rect is centered at (200,150),
        // with width/height from AppConstants.mapNode{Width,Height}. So (200,150) is inside.
        XCTAssertEqual(m.hitTest(location: CGPoint(x: 200, y: 150), layout: layout, graph: graph), node.id)
    }

    func test_hitTest_returnsNilWhenPointMissesAllNodes() {
        let (m, layout, graph, _) = graphWithOneNode(at: CGPoint(x: 50, y: 50))
        XCTAssertNil(m.hitTest(location: CGPoint(x: 1000, y: 1000), layout: layout, graph: graph))
    }

    // MARK: - handleClick

    func test_handleClick_selectsThenDeselectsSameNode() {
        let (m, layout, graph, node) = graphWithOneNode(at: CGPoint(x: 200, y: 150))
        m.handleClick(at: CGPoint(x: 200, y: 150), layout: layout, graph: graph)
        XCTAssertEqual(m.selectedNodeID, node.id)

        m.handleClick(at: CGPoint(x: 200, y: 150), layout: layout, graph: graph)
        XCTAssertNil(m.selectedNodeID, "Clicking the selected node a second time deselects")
    }

    func test_handleClick_offNodeClearsSelection() {
        let (m, layout, graph, node) = graphWithOneNode(at: CGPoint(x: 200, y: 150))
        m.selectedNodeID = node.id
        m.handleClick(at: CGPoint(x: 1000, y: 1000), layout: layout, graph: graph)
        XCTAssertNil(m.selectedNodeID)
    }

    func test_handleClick_togglesExpansionWhenChildrenExist() {
        let m = MapInteraction()
        let layout = ForceDirectedLayout()
        let graph = KnowledgeGraph()
        let parent = ConceptNode(label: "P", level: .concept); graph.addNode(parent)
        let child = ConceptNode(label: "C", level: .entity); graph.addNode(child)
        graph.addEdge(GraphEdge(sourceNodeID: parent.id, targetNodeID: child.id, type: .containsEntity))
        layout.positions[parent.id] = NodePosition(x: 200, y: 150)

        XCTAssertEqual(graph.node(for: parent.id)?.expansionState, .collapsed)
        m.handleClick(at: CGPoint(x: 200, y: 150), layout: layout, graph: graph)
        XCTAssertEqual(graph.node(for: parent.id)?.expansionState, .expanded)
    }

    // MARK: - Drag (background pan)

    func test_dragBackground_movesViewOffset() {
        let m = MapInteraction()
        let layout = ForceDirectedLayout()
        let graph = KnowledgeGraph()

        m.handleDragStart(at: CGPoint(x: 10, y: 10), layout: layout, graph: graph)
        XCTAssertTrue(m.isDragging)
        XCTAssertFalse(m.isDraggingNode)

        m.handleDragChanged(translation: CGSize(width: 50, height: -30), layout: layout)
        XCTAssertEqual(m.viewOffset.x, 50, accuracy: 0.001)
        XCTAssertEqual(m.viewOffset.y, -30, accuracy: 0.001)

        m.handleDragEnded()
        XCTAssertFalse(m.isDragging)
    }

    // MARK: - Drag node

    func test_dragNode_movesNodePositionAndSelectsIt() {
        let (m, layout, graph, node) = graphWithOneNode(at: CGPoint(x: 200, y: 150))
        m.handleDragStart(at: CGPoint(x: 200, y: 150), layout: layout, graph: graph)
        XCTAssertTrue(m.isDraggingNode)
        XCTAssertEqual(m.selectedNodeID, node.id)

        m.handleDragChanged(translation: CGSize(width: 40, height: 10), layout: layout)
        let pos = layout.point(for: node.id)!
        XCTAssertEqual(pos.x, 240, accuracy: 0.001)
        XCTAssertEqual(pos.y, 160, accuracy: 0.001)

        m.handleDragEnded()
        XCTAssertFalse(m.isDraggingNode)
    }

    // MARK: - Scroll wheel zoom

    func test_handleScrollWheel_changesScaleAndAdjustsOffsetToKeepCursorAnchored() {
        let m = MapInteraction()
        m.viewScale = 1.0
        m.viewOffset = .zero

        let cursor = CGPoint(x: 100, y: 100)
        m.handleScrollWheel(deltaY: 1, cursorLocation: cursor)
        // deltaY > 0 → factor 1.05 → scale 1.05.
        XCTAssertEqual(m.viewScale, 1.05, accuracy: 0.001)

        // After zoom, the cursor's *graph-space* position should map back
        // to the same screen-space cursor.
        let cursorInGraph = CGPoint(
            x: (cursor.x - m.viewOffset.x) / m.viewScale,
            y: (cursor.y - m.viewOffset.y) / m.viewScale
        )
        // pre-zoom graph-cursor was (100, 100); after zoom invariant:
        // cursorScreen = graph * scale + offset.
        let projected = CGPoint(
            x: cursorInGraph.x * m.viewScale + m.viewOffset.x,
            y: cursorInGraph.y * m.viewScale + m.viewOffset.y
        )
        XCTAssertEqual(projected.x, cursor.x, accuracy: 0.001)
        XCTAssertEqual(projected.y, cursor.y, accuracy: 0.001)
    }
}
