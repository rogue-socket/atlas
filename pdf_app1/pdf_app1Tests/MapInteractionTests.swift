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

    func testFocusOnNodeCentersNodeAndSelectsIt() {
        let interaction = MapInteraction()
        let layout = ForceDirectedLayout()
        let nodeID = UUID()
        layout.positions[nodeID] = NodePosition(x: 100, y: 80)

        interaction.focusOnNode(
            id: nodeID,
            layout: layout,
            canvasSize: CGSize(width: 800, height: 600),
            targetScale: 1.5
        )

        XCTAssertEqual(interaction.viewScale, 1.5)
        XCTAssertEqual(interaction.viewOffset.x, 250, accuracy: 0.001)
        XCTAssertEqual(interaction.viewOffset.y, 180, accuracy: 0.001)
        XCTAssertEqual(interaction.selectedNodeID, nodeID)
    }
}
