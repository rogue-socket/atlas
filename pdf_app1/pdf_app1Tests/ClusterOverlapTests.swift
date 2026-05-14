import XCTest
import CoreGraphics

@testable import pdf_app1

/// Tests for `ForceDirectedLayout.resolveClusterOverlaps` — the post-FDL
/// pass that pushes overlapping concept-plus-entities clusters apart.
final class ClusterOverlapTests: XCTestCase {

    private func concept(_ label: String, id: UUID = UUID()) -> ConceptNode {
        ConceptNode(id: id, label: label, level: .concept)
    }

    private func entity(under parent: UUID, id: UUID = UUID()) -> ConceptNode {
        ConceptNode(id: id, label: "entity-\(id.uuidString.prefix(4))",
                    level: .entity, parentConceptID: parent)
    }

    /// Compute the cluster bbox the renderer would draw — same padding
    /// (40 horizontal, 30 top, 50 bottom) used by the resolve pass.
    private func clusterBBox(conceptID: UUID, entityIDs: [UUID],
                              in layout: ForceDirectedLayout) -> CGRect? {
        let members = [conceptID] + entityIDs
        let pts = members.compactMap { layout.point(for: $0) }
        guard !pts.isEmpty else { return nil }
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        return CGRect(
            x: xs.min()! - 40,
            y: ys.min()! - 30,
            width: (xs.max()! - xs.min()!) + 80,
            height: (ys.max()! - ys.min()!) + 80
        )
    }

    /// Two clusters whose bboxes overlap should be separated. Each cluster
    /// is a concept + 2 entities. We seed positions to force overlap, then
    /// run only the cluster-resolve pass (not full FDL).
    func testResolveClusterOverlaps_twoOverlappingClusters_separates() {
        let layout = ForceDirectedLayout(maxIterations: 1)

        // Cluster A: concept at (100,100), entities nearby
        let cA = concept("A")
        let aE1 = entity(under: cA.id)
        let aE2 = entity(under: cA.id)
        layout.positions[cA.id] = NodePosition(x: 100, y: 100)
        layout.positions[aE1.id] = NodePosition(x: 130, y: 120)
        layout.positions[aE2.id] = NodePosition(x: 90, y: 130)

        // Cluster B: concept at (140,110), entities nearby — overlaps A
        let cB = concept("B")
        let bE1 = entity(under: cB.id)
        let bE2 = entity(under: cB.id)
        layout.positions[cB.id] = NodePosition(x: 140, y: 110)
        layout.positions[bE1.id] = NodePosition(x: 170, y: 130)
        layout.positions[bE2.id] = NodePosition(x: 130, y: 140)

        let nodes = [cA, aE1, aE2, cB, bE1, bE2]

        // Sanity: pre-resolve, bboxes overlap
        let preA = clusterBBox(conceptID: cA.id, entityIDs: [aE1.id, aE2.id], in: layout)!
        let preB = clusterBBox(conceptID: cB.id, entityIDs: [bE1.id, bE2.id], in: layout)!
        XCTAssertTrue(preA.intersects(preB), "Pre-condition: clusters start overlapping")

        layout.resolveClusterOverlaps(nodes: nodes)

        let postA = clusterBBox(conceptID: cA.id, entityIDs: [aE1.id, aE2.id], in: layout)!
        let postB = clusterBBox(conceptID: cB.id, entityIDs: [bE1.id, bE2.id], in: layout)!
        XCTAssertFalse(postA.intersects(postB), "Post-condition: clusters separated")
    }

    /// Cluster shifts as a rigid unit — relative positions of concept and
    /// its entities are preserved.
    func testResolveClusterOverlaps_preservesIntraClusterStructure() {
        let layout = ForceDirectedLayout(maxIterations: 1)

        let cA = concept("A")
        let aE1 = entity(under: cA.id)
        let aE2 = entity(under: cA.id)
        layout.positions[cA.id] = NodePosition(x: 100, y: 100)
        layout.positions[aE1.id] = NodePosition(x: 130, y: 120) // offset (+30, +20)
        layout.positions[aE2.id] = NodePosition(x: 90, y: 130)  // offset (-10, +30)

        let cB = concept("B")
        layout.positions[cB.id] = NodePosition(x: 140, y: 110)

        layout.resolveClusterOverlaps(nodes: [cA, aE1, aE2, cB])

        let cAPos = layout.point(for: cA.id)!
        let e1Pos = layout.point(for: aE1.id)!
        let e2Pos = layout.point(for: aE2.id)!

        // Original offsets preserved (cluster moves rigidly)
        XCTAssertEqual(e1Pos.x - cAPos.x, 30, accuracy: 0.1)
        XCTAssertEqual(e1Pos.y - cAPos.y, 20, accuracy: 0.1)
        XCTAssertEqual(e2Pos.x - cAPos.x, -10, accuracy: 0.1)
        XCTAssertEqual(e2Pos.y - cAPos.y, 30, accuracy: 0.1)
    }

    /// Non-overlapping clusters stay put (no spurious motion).
    func testResolveClusterOverlaps_noOverlap_noChange() {
        let layout = ForceDirectedLayout(maxIterations: 1)

        let cA = concept("A")
        let cB = concept("B")
        layout.positions[cA.id] = NodePosition(x: 100, y: 100)
        layout.positions[cB.id] = NodePosition(x: 500, y: 500)

        layout.resolveClusterOverlaps(nodes: [cA, cB])

        XCTAssertEqual(layout.point(for: cA.id)!.x, 100, accuracy: 0.1)
        XCTAssertEqual(layout.point(for: cA.id)!.y, 100, accuracy: 0.1)
        XCTAssertEqual(layout.point(for: cB.id)!.x, 500, accuracy: 0.1)
        XCTAssertEqual(layout.point(for: cB.id)!.y, 500, accuracy: 0.1)
    }
}
