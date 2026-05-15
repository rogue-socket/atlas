import XCTest
@testable import pdf_app1

/// Tests for B3 — `LevelBandSeeder` places each node in a horizontal
/// band corresponding to its `NodeLevel`, sub-clustered by parent.
final class LevelBandSeederTests: XCTestCase {

    private let canvas = CGSize(width: 1000, height: 1000)

    func test_bandY_orderingTopToBottomMatchesLevelFold() {
        let docY = LevelBandSeeder.bandY(for: .document, canvasHeight: canvas.height)
        let chapY = LevelBandSeeder.bandY(for: .chapter, canvasHeight: canvas.height)
        let conY = LevelBandSeeder.bandY(for: .concept, canvasHeight: canvas.height)
        let entY = LevelBandSeeder.bandY(for: .entity, canvasHeight: canvas.height)
        XCTAssertLessThan(docY, chapY)
        XCTAssertLessThan(chapY, conY)
        XCTAssertLessThan(conY, entY)
    }

    func test_seed_placesEachNodeAtItsLevelsBand() {
        let docNode  = ConceptNode(label: "D",  level: .document)
        let chapNode = ConceptNode(label: "Ch", level: .chapter)
        let conNode  = ConceptNode(label: "C",  level: .concept)
        let entNode  = ConceptNode(label: "E",  level: .entity)

        let result = LevelBandSeeder.seed(
            nodes: [docNode, chapNode, conNode, entNode],
            canvasSize: canvas,
            parentByEntity: [:],
            parentByConcept: [:]
        )

        // Y of each node should land within ±cellH (70) of its band Y.
        for (node, level) in [(docNode, NodeLevel.document), (chapNode, .chapter), (conNode, .concept), (entNode, .entity)] {
            let expectedY = LevelBandSeeder.bandY(for: level, canvasHeight: canvas.height)
            let actualY = result[node.id]?.y ?? -1
            XCTAssertEqual(actualY, expectedY, accuracy: 100, "Node at level \(level) should be near its band Y")
        }
    }

    func test_seed_entitiesUnderSameParentClusterTogether() {
        // Two parent concepts, three entities each. Entities under the
        // same concept should land close in X; entities under different
        // concepts should be further apart.
        let conA = ConceptNode(label: "A", level: .concept)
        let conB = ConceptNode(label: "B", level: .concept)
        let entsA = (0..<3).map { i in ConceptNode(label: "a\(i)", level: .entity) }
        let entsB = (0..<3).map { i in ConceptNode(label: "b\(i)", level: .entity) }

        var parentByEntity: [UUID: UUID] = [:]
        for ent in entsA { parentByEntity[ent.id] = conA.id }
        for ent in entsB { parentByEntity[ent.id] = conB.id }

        let result = LevelBandSeeder.seed(
            nodes: [conA, conB] + entsA + entsB,
            canvasSize: canvas,
            parentByEntity: parentByEntity,
            parentByConcept: [:]
        )

        let aXs = entsA.compactMap { result[$0.id]?.x }
        let bXs = entsB.compactMap { result[$0.id]?.x }
        XCTAssertEqual(aXs.count, 3)
        XCTAssertEqual(bXs.count, 3)

        let aSpread = (aXs.max() ?? 0) - (aXs.min() ?? 0)
        let bSpread = (bXs.max() ?? 0) - (bXs.min() ?? 0)
        let crossDist = abs((aXs.reduce(0, +) / 3) - (bXs.reduce(0, +) / 3))

        XCTAssertGreaterThan(crossDist, max(aSpread, bSpread),
                             "Cross-cluster X distance should exceed intra-cluster spread")
    }
}
