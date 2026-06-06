import XCTest

@testable import pdf_app1

final class MapInteractionTests: XCTestCase {

    func testFitToContentNoOpOnEmptyLayout() {
        let interaction = MapInteraction()
        let layout = ForceDirectedLayout()
        interaction.fitToContent(layout: layout, canvasSize: CGSize(width: 800, height: 600))

        XCTAssertEqual(interaction.viewScale, 1.0)
        XCTAssertEqual(interaction.viewOffset, .zero)
    }

    func testFitToContentSinglePosition() {
        let interaction = MapInteraction()
        let layout = ForceDirectedLayout()
        layout.positions[UUID()] = NodePosition(x: 100, y: 100)

        interaction.fitToContent(layout: layout, canvasSize: CGSize(width: 800, height: 600))

        // contentWidth = 0 + 100 padding = 100, scaleX = 8, scaleY = 6, capped at 2.0
        XCTAssertEqual(interaction.viewScale, 2.0)
        // midpoint = (100, 100); offset = (400 - 200, 300 - 200) = (200, 100)
        XCTAssertEqual(interaction.viewOffset.x, 200, accuracy: 0.001)
        XCTAssertEqual(interaction.viewOffset.y, 100, accuracy: 0.001)
    }

    func testFitToContentScalesToFitLargeSpread() {
        let interaction = MapInteraction()
        let layout = ForceDirectedLayout()
        layout.positions[UUID()] = NodePosition(x: 0, y: 0)
        layout.positions[UUID()] = NodePosition(x: 1000, y: 800)

        interaction.fitToContent(layout: layout, canvasSize: CGSize(width: 800, height: 600))

        // contentWidth = 1100, contentHeight = 900; scaleY = 600/900 wins
        let expectedScale = 600.0 / 900.0
        XCTAssertEqual(interaction.viewScale, expectedScale, accuracy: 0.001)
        // midX = 500, midY = 400
        XCTAssertEqual(interaction.viewOffset.x, 400 - 500 * expectedScale, accuracy: 0.001)
        XCTAssertEqual(interaction.viewOffset.y, 300 - 400 * expectedScale, accuracy: 0.001)
    }

    func testFitToContentBboxCoversMixedMinMaxDistribution() {
        // Verifies single-fold catches the global bbox even when min/max for x and y
        // come from different positions and aren't the first/last inserted.
        let interaction = MapInteraction()
        let layout = ForceDirectedLayout()
        layout.positions[UUID()] = NodePosition(x: 0, y: 0)
        layout.positions[UUID()] = NodePosition(x: 120, y: -10)   // maxX, minY
        layout.positions[UUID()] = NodePosition(x: -50, y: 30)    // minX
        layout.positions[UUID()] = NodePosition(x: 40, y: 80)     // maxY

        interaction.fitToContent(layout: layout, canvasSize: CGSize(width: 800, height: 600))

        // bbox: (-50,-10) to (120,80). contentWidth=270, contentHeight=190.
        // scaleX≈2.96, scaleY≈3.16; capped at 2.0
        XCTAssertEqual(interaction.viewScale, 2.0)
        // midX = 35, midY = 35; offset = (400-70, 300-70) = (330, 230)
        XCTAssertEqual(interaction.viewOffset.x, 330, accuracy: 0.001)
        XCTAssertEqual(interaction.viewOffset.y, 230, accuracy: 0.001)
    }

    func testEdgeControlPointIsNotCurveMidpointForCurvedEdge() {
        let source = CGPoint(x: 0, y: 0)
        let target = CGPoint(x: 100, y: 0)
        let control = MapCanvasRenderer.edgeControlPoint(from: source, to: target)
        let midpoint = MapCanvasRenderer.quadraticPoint(from: source, control: control, to: target, t: 0.5)

        XCTAssertEqual(control.x, 50, accuracy: 0.001)
        XCTAssertEqual(control.y, 8, accuracy: 0.001)
        XCTAssertEqual(midpoint.x, 50, accuracy: 0.001)
        XCTAssertEqual(midpoint.y, 4, accuracy: 0.001)
    }

    func testEdgeLabelPointOffsetsFromBezierMidpointInCurveDirection() {
        let source = CGPoint(x: 20, y: 40)
        let target = CGPoint(x: 140, y: 100)
        let control = MapCanvasRenderer.edgeControlPoint(from: source, to: target)
        let midpoint = MapCanvasRenderer.quadraticPoint(from: source, control: control, to: target, t: 0.5)
        let labelPoint = MapCanvasRenderer.edgeLabelPoint(from: source, control: control, to: target, viewScale: 1)

        XCTAssertNotEqual(labelPoint, midpoint, "Label should keep a small curve-side offset for readability")

        let chordMidpoint = CGPoint(x: (source.x + target.x) / 2, y: (source.y + target.y) / 2)
        let midpointBow = CGVector(dx: midpoint.x - chordMidpoint.x, dy: midpoint.y - chordMidpoint.y)
        let labelBow = CGVector(dx: labelPoint.x - midpoint.x, dy: labelPoint.y - midpoint.y)
        XCTAssertGreaterThan(midpointBow.dx * labelBow.dx + midpointBow.dy * labelBow.dy, 0)
    }

    func testEdgeLabelPointKeepsReciprocalLabelsSeparated() {
        let source = CGPoint(x: 0, y: 0)
        let target = CGPoint(x: 100, y: 0)
        let forwardControl = MapCanvasRenderer.edgeControlPoint(from: source, to: target)
        let reverseControl = MapCanvasRenderer.edgeControlPoint(from: target, to: source)

        let forwardLabel = MapCanvasRenderer.edgeLabelPoint(from: source, control: forwardControl, to: target, viewScale: 1)
        let reverseLabel = MapCanvasRenderer.edgeLabelPoint(from: target, control: reverseControl, to: source, viewScale: 1)

        XCTAssertEqual(abs(forwardLabel.y - reverseLabel.y), 16, accuracy: 0.001)
    }

    func testEdgeTangentAngleFollowsTargetDirection() {
        let leftControl = CGPoint(x: 100, y: 0)
        let leftTarget = CGPoint(x: 0, y: 0)
        let rightControl = CGPoint(x: 0, y: 0)
        let rightTarget = CGPoint(x: 100, y: 0)

        XCTAssertEqual(MapCanvasRenderer.edgeTangentAngle(control: rightControl, target: rightTarget), 0, accuracy: 0.001)
        XCTAssertEqual(abs(MapCanvasRenderer.edgeTangentAngle(control: leftControl, target: leftTarget)), .pi, accuracy: 0.001)
    }

    func testLayoutComputationKeyIsStableForSameInputs() {
        let nodeA = UUID()
        let nodeB = UUID()
        let edge = GraphEdge(sourceNodeID: nodeA, targetNodeID: nodeB, type: .dependsOn, label: "requires")

        let first = KnowledgeMapView.layoutComputationKey(
            nodeIDs: [nodeB, nodeA],
            edges: [edge],
            zoomLevel: .chapter,
            canvasSize: CGSize(width: 812, height: 602),
            expansionGeneration: 3
        )
        let second = KnowledgeMapView.layoutComputationKey(
            nodeIDs: [nodeA, nodeB],
            edges: [edge],
            zoomLevel: .chapter,
            canvasSize: CGSize(width: 820, height: 604),
            expansionGeneration: 3
        )

        XCTAssertEqual(first, second)
    }

    func testLayoutComputationKeyChangesForLayoutRelevantInputs() {
        let nodeA = UUID()
        let nodeB = UUID()
        let edge = GraphEdge(sourceNodeID: nodeA, targetNodeID: nodeB, type: .dependsOn, label: "requires")
        let changedLabelEdge = GraphEdge(
            id: edge.id,
            sourceNodeID: nodeA,
            targetNodeID: nodeB,
            type: .dependsOn,
            label: "blocks"
        )
        let base = KnowledgeMapView.layoutComputationKey(
            nodeIDs: [nodeA, nodeB],
            edges: [edge],
            zoomLevel: .chapter,
            canvasSize: CGSize(width: 812, height: 602),
            expansionGeneration: 3
        )

        XCTAssertNotEqual(
            base,
            KnowledgeMapView.layoutComputationKey(
                nodeIDs: [nodeA, nodeB],
                edges: [edge],
                zoomLevel: .document,
                canvasSize: CGSize(width: 812, height: 602),
                expansionGeneration: 3
            )
        )
        XCTAssertNotEqual(
            base,
            KnowledgeMapView.layoutComputationKey(
                nodeIDs: [nodeA, nodeB],
                edges: [edge],
                zoomLevel: .chapter,
                canvasSize: CGSize(width: 900, height: 602),
                expansionGeneration: 3
            )
        )
        XCTAssertNotEqual(
            base,
            KnowledgeMapView.layoutComputationKey(
                nodeIDs: [nodeA, nodeB],
                edges: [changedLabelEdge],
                zoomLevel: .chapter,
                canvasSize: CGSize(width: 812, height: 602),
                expansionGeneration: 3
            )
        )
    }
}
