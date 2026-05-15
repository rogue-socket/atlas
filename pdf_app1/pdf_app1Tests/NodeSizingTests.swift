import XCTest

@testable import pdf_app1

final class NodeSizingTests: XCTestCase {

    // MARK: - Level scaling: level-0 > level-1 > level-2

    func testLevelZeroIsLargerThanLevelOne() {
        let s0 = NodeSizing.forLevel(0)
        let s1 = NodeSizing.forLevel(1)

        XCTAssertGreaterThan(s0.baseWidth, s1.baseWidth, "level-0 should be wider than level-1")
        XCTAssertGreaterThan(s0.baseHeight, s1.baseHeight, "level-0 should be taller than level-1")
        XCTAssertGreaterThan(s0.fontSize, s1.fontSize, "level-0 font should be larger than level-1")
        XCTAssertGreaterThan(s0.dotSize, s1.dotSize, "level-0 dot should be larger than level-1")
        XCTAssertGreaterThan(s0.borderWidth, s1.borderWidth, "level-0 border should be thicker than level-1")
        XCTAssertGreaterThan(s0.colorStripWidth, s1.colorStripWidth, "level-0 strip should be wider than level-1")
    }

    func testLevelOneIsLargerThanLevelTwo() {
        let s1 = NodeSizing.forLevel(1)
        let s2 = NodeSizing.forLevel(2)

        XCTAssertGreaterThan(s1.baseWidth, s2.baseWidth, "level-1 should be wider than level-2")
        XCTAssertGreaterThan(s1.baseHeight, s2.baseHeight, "level-1 should be taller than level-2")
        XCTAssertGreaterThan(s1.fontSize, s2.fontSize, "level-1 font should be larger than level-2")
        XCTAssertGreaterThan(s1.dotSize, s2.dotSize, "level-1 dot should be larger than level-2")
    }

    // MARK: - Level clamping: levels beyond 2 produce same sizing as level-2

    func testLevelsBeyondTwoClampToLevelTwo() {
        let s2 = NodeSizing.forLevel(2)
        let s5 = NodeSizing.forLevel(5)
        let s99 = NodeSizing.forLevel(99)

        XCTAssertEqual(s2.baseWidth, s5.baseWidth)
        XCTAssertEqual(s2.baseHeight, s5.baseHeight)
        XCTAssertEqual(s2.fontSize, s5.fontSize)
        XCTAssertEqual(s2.dotSize, s5.dotSize)

        XCTAssertEqual(s2.baseWidth, s99.baseWidth)
        XCTAssertEqual(s2.baseHeight, s99.baseHeight)
    }

    func testNegativeLevelsClampsToZero() {
        let s0 = NodeSizing.forLevel(0)
        let sNeg = NodeSizing.forLevel(-1)

        XCTAssertEqual(s0.baseWidth, sNeg.baseWidth)
        XCTAssertEqual(s0.baseHeight, sNeg.baseHeight)
        XCTAssertEqual(s0.fontSize, sNeg.fontSize)
    }

    // MARK: - Summary adds height

    func testSummaryIncreasesHeight() {
        for level in 0...2 {
            let noSummary = NodeSizing.forLevel(level, hasSummary: false)
            let withSummary = NodeSizing.forLevel(level, hasSummary: true)
            XCTAssertGreaterThan(withSummary.baseHeight, noSummary.baseHeight,
                                "level-\(level) with summary should be taller")
            XCTAssertEqual(noSummary.baseWidth, withSummary.baseWidth,
                           "summary should not change width at level-\(level)")
        }
    }

    // MARK: - NodeSizing.forNodeLevel (4-level mapping)

    func testForNodeLevel_documentAndChapterMatchTier0() {
        let doc = NodeSizing.forNodeLevel(.document)
        let chap = NodeSizing.forNodeLevel(.chapter)
        let tier0 = NodeSizing.forLevel(0)

        XCTAssertEqual(doc.baseWidth, tier0.baseWidth)
        XCTAssertEqual(chap.baseWidth, tier0.baseWidth)
    }

    func testForNodeLevel_conceptMatchesTier1() {
        let concept = NodeSizing.forNodeLevel(.concept)
        let tier1 = NodeSizing.forLevel(1)
        XCTAssertEqual(concept.baseWidth, tier1.baseWidth)
        XCTAssertEqual(concept.fontSize, tier1.fontSize)
    }

    func testForNodeLevel_entityMatchesTier2() {
        let entity = NodeSizing.forNodeLevel(.entity)
        let tier2 = NodeSizing.forLevel(2)
        XCTAssertEqual(entity.baseWidth, tier2.baseWidth)
        XCTAssertEqual(entity.fontSize, tier2.fontSize)
    }
}
