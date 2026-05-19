import XCTest
import PDFKit
@testable import pdf_app1

/// Tests for `Atlas/Annotations/PDFAnnotation+Kind.swift`.
/// PDFKit's `.type` strips the leading slash while `PDFAnnotationSubtype.rawValue`
/// keeps it; the extension normalizes so call-sites can compare with typed
/// constants.
final class PDFAnnotationKindTests: XCTestCase {

    private func annotation(for subtype: PDFAnnotationSubtype) -> PDFAnnotation {
        PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                      forType: subtype, withProperties: nil)
    }

    func test_atlasSubtype_recognizesHighlight() {
        let a = annotation(for: .highlight)
        XCTAssertEqual(a.atlasSubtype, .highlight)
    }

    func test_atlasSubtype_recognizesUnderlineSquareInkCircleStrikeOut() {
        for subtype: PDFAnnotationSubtype in [.underline, .square, .ink, .circle, .strikeOut, .freeText] {
            let a = annotation(for: subtype)
            XCTAssertEqual(a.atlasSubtype, subtype, "round-trip failed for \(subtype.rawValue)")
        }
    }

    func test_isKind_matchesEquivalentSubtype() {
        let a = annotation(for: .highlight)
        XCTAssertTrue(a.isKind(.highlight))
        XCTAssertFalse(a.isKind(.underline))
    }
}
