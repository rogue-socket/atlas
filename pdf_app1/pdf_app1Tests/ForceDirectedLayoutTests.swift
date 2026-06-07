import XCTest
import CoreGraphics

@testable import pdf_app1

final class ForceDirectedLayoutTests: XCTestCase {

    private func concept(_ label: String, id: UUID = UUID()) -> ConceptNode {
        ConceptNode(id: id, label: label, level: .concept)
    }

    func testComputeLayoutPreservesExistingPositionForKnownNode() throws {
        let layout = ForceDirectedLayout(maxIterations: 0)
        let node = concept("Preserved")
        layout.positions[node.id] = NodePosition(x: 123, y: 456)

        layout.computeLayout(
            nodes: [node],
            edges: [],
            canvasSize: CGSize(width: 800, height: 600),
            validNodeIDs: [node.id]
        )

        let point = try XCTUnwrap(layout.point(for: node.id))
        XCTAssertEqual(point.x, 123, accuracy: 0.001)
        XCTAssertEqual(point.y, 456, accuracy: 0.001)
        XCTAssertEqual(layout.iteration, 0)
    }

    func testComputeLayoutEvictsPositionsOutsideValidNodeIDs() {
        let layout = ForceDirectedLayout(maxIterations: 0)
        let current = concept("Current")
        let staleID = UUID()
        layout.positions[current.id] = NodePosition(x: 100, y: 100)
        layout.positions[staleID] = NodePosition(x: 200, y: 200)

        layout.computeLayout(
            nodes: [current],
            edges: [],
            canvasSize: CGSize(width: 800, height: 600),
            validNodeIDs: [current.id]
        )

        XCTAssertNotNil(layout.point(for: current.id))
        XCTAssertNil(layout.point(for: staleID))
    }

    func testComputeLayoutConvergesAfterStableIterations() {
        let layout = ForceDirectedLayout(maxIterations: AppConstants.layoutMaxIterations)
        let nodes = (0..<20).map { concept("N\($0)") }
        let anchors = Dictionary(
            uniqueKeysWithValues: nodes.enumerated().map { index, node in
                (node.id, CGPoint(x: 100 + index * 250, y: 200))
            }
        )

        layout.computeLayout(
            nodes: nodes,
            edges: [],
            canvasSize: CGSize(width: 6000, height: 1000),
            anchorNodes: anchors,
            validNodeIDs: Set(nodes.map(\.id))
        )

        XCTAssertTrue(layout.isConverged)
        XCTAssertEqual(layout.iteration, 10)
        XCTAssertLessThan(layout.iteration, AppConstants.layoutMaxIterations)
    }
}
