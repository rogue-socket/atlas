import XCTest
@testable import pdf_app1

/// Tests for `Atlas/AI/LayoutAnalyzer.swift` — heuristic block classifier.
/// Each test seeds synthetic `PageTextBlock`s, runs `classify(blocks:pageSize:)`,
/// and asserts on the resulting `blockType` for the targeted block.
final class LayoutAnalyzerTests: XCTestCase {

    private let page = CGSize(width: 612, height: 792)
    private let medianBox = CGRect(x: 50, y: 400, width: 500, height: 12)

    private func block(_ text: String, _ box: CGRect) -> PageTextBlock {
        PageTextBlock(text: text, pageIndex: 0, boundingBox: box, blockType: .unknown)
    }

    private func type(of label: String, in classified: [PageTextBlock]) -> TextBlockType? {
        classified.first(where: { $0.text == label })?.blockType
    }

    // MARK: - classify

    func test_classify_emptyInputReturnsEmpty() {
        let result = LayoutAnalyzer().classify(blocks: [], pageSize: page)
        XCTAssertTrue(result.isEmpty)
    }

    func test_classify_tallBlockShorterTextIsHeading() {
        // Need an odd-counted majority of body blocks at the median height so
        // median picks 12 (not the outlier 22).
        let blocks = [
            block("Body block one with body text length.",   medianBox),
            block("Body block two with body text length.",   medianBox),
            block("Body block three with body text length.", medianBox),
            block("Title Of Chapter", CGRect(x: 50, y: 700, width: 200, height: 22))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "Title Of Chapter", in: result), .heading)
    }

    func test_classify_allCapsShortLineIsHeading() {
        // Same height as median, but all-caps short text → heading
        let blocks = [
            block("body block sets median", medianBox),
            block("INTRODUCTION", CGRect(x: 50, y: 700, width: 200, height: 12))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "INTRODUCTION", in: result), .heading)
    }

    func test_classify_lowYIsFootnote() {
        // Block near the bottom (small y) classified as footnote when short.
        let blocks = [
            block("Body line for median", medianBox),
            block("1. See appendix.", CGRect(x: 50, y: 40, width: 300, height: 10))  // y < 15% of 792 = 118
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "1. See appendix.", in: result), .footnote)
    }

    func test_classify_smallShortLineIsCaption() {
        // Below 0.7 × median height (12 → < 8.4), short text.
        let blocks = [
            block("Body line for median", medianBox),
            block("Fig 1: comparison", CGRect(x: 50, y: 400, width: 300, height: 7))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "Fig 1: comparison", in: result), .caption)
    }

    func test_classify_figureRefIsCaption() {
        // Even at median height, a "Figure 1" prefix tags it as a caption.
        let blocks = [
            block("Body line for median", medianBox),
            block("Figure 1 shows the breakdown.", CGRect(x: 50, y: 400, width: 400, height: 12))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "Figure 1 shows the breakdown.", in: result), .caption)
    }

    func test_classify_equationViaMathSymbols() {
        // 4 math symbols (>2 threshold) → equation
        let blocks = [
            block("Body line for median", medianBox),
            block("∑ x · ∫ y ≈ π", CGRect(x: 50, y: 400, width: 200, height: 12))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "∑ x · ∫ y ≈ π", in: result), .equation)
    }

    func test_classify_equationViaOperatorDensity() {
        // High operator density → equation (>30% operator chars).
        let blocks = [
            block("Body line that drives the median height here.", medianBox),
            block("x=y+z*(a-b)/c^2", CGRect(x: 50, y: 400, width: 200, height: 12))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: "x=y+z*(a-b)/c^2", in: result), .equation)
    }

    func test_classify_normalParagraphIsBody() {
        let body = "This is a perfectly normal paragraph of body text that's long enough to avoid caption or heading heuristics."
        let blocks = [
            block("Filler median block which is also body", medianBox),
            block(body, CGRect(x: 50, y: 400, width: 500, height: 12))
        ]
        let result = LayoutAnalyzer().classify(blocks: blocks, pageSize: page)
        XCTAssertEqual(type(of: body, in: result), .body)
    }

    // MARK: - config override

    func test_classify_respectsHeadingHeightRatioOverride() {
        // Default heading ratio is 1.4. Bump it high enough that nothing qualifies.
        var cfg = LayoutAnalyzer.LayoutConfig()
        cfg.headingHeightRatio = 10
        let analyzer = LayoutAnalyzer(config: cfg)

        let blocks = [
            block("body median height block ok", medianBox),
            block("Title Looks Like A Heading", CGRect(x: 50, y: 700, width: 200, height: 22))
        ]
        let result = analyzer.classify(blocks: blocks, pageSize: page)
        // With the absurdly high heading ratio, the title falls through to body.
        XCTAssertNotEqual(type(of: "Title Looks Like A Heading", in: result), .heading)
    }
}
