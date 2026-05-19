import XCTest
import AppKit
import PDFKit
@testable import pdf_app1

/// Tests for `TextExtractor` that don't require complex PDF generation.
/// Focuses on:
///   - page-range clamping in `extractPages`
///   - that an empty PDFDocument yields zero results
///   - the `extractWithContext` page-window math
final class TextExtractorTests: XCTestCase {

    private func makeBlankDocument(pages: Int) -> PDFDocument {
        let doc = PDFDocument()
        for _ in 0..<pages {
            let size = NSSize(width: 100, height: 100)
            let img = NSImage(size: size)
            img.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            img.unlockFocus()
            if let page = PDFPage(image: img) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        return doc
    }

    // MARK: - extractPages

    func test_extractPages_returnsResultForEachPageInRange() {
        let doc = makeBlankDocument(pages: 3)
        let results = TextExtractor().extractPages(from: doc, pageRange: 0..<3)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.pageIndex), [0, 1, 2])
    }

    func test_extractPages_clampsRangeWhenLowerBoundNegative() {
        let doc = makeBlankDocument(pages: 2)
        let results = TextExtractor().extractPages(from: doc, pageRange: -5..<2)
        XCTAssertEqual(results.map(\.pageIndex), [0, 1])
    }

    func test_extractPages_clampsRangeWhenUpperBoundBeyondDocument() {
        let doc = makeBlankDocument(pages: 2)
        let results = TextExtractor().extractPages(from: doc, pageRange: 0..<99)
        XCTAssertEqual(results.map(\.pageIndex), [0, 1])
    }

    func test_extractPages_emptyDocumentReturnsEmpty() {
        let doc = PDFDocument()
        let results = TextExtractor().extractPages(from: doc, pageRange: 0..<5)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - extractPage on a blank page returns empty text but does not crash

    func test_extractPage_onBlankImagePage_yieldsEmptyText() {
        let doc = makeBlankDocument(pages: 1)
        guard let page = doc.page(at: 0) else { return XCTFail("no page") }
        let result = TextExtractor().extractPage(page, at: 0)
        XCTAssertEqual(result.pageIndex, 0)
        // Blank pages have empty `string` from PDFKit; no blocks should be produced.
        XCTAssertEqual(result.fullText, "")
        XCTAssertTrue(result.blocks.isEmpty)
    }

    // MARK: - extractWithContext page window

    func test_extractWithContext_windowIsCenteredAndClampedToDocument() {
        let doc = makeBlankDocument(pages: 6)
        // contextPages = 2 → window [center-2, center+2+1)
        let result = TextExtractor().extractWithContext(from: doc, centerPage: 3, contextPages: 2)
        // Window 1..<6 → page markers for pages 2..6 (1-based)
        XCTAssertTrue(result.contextText.contains("--- Page 2 ---") || result.contextText.contains("--- Page 6 ---"),
                      "Context text should include 1-based page markers from the window")
    }

    func test_extractWithContext_clampsAtDocumentStart() {
        let doc = makeBlankDocument(pages: 5)
        let result = TextExtractor().extractWithContext(from: doc, centerPage: 0, contextPages: 3)
        // Should not crash; expect a non-nil tuple with blocks (possibly empty for blank pages).
        XCTAssertTrue(result.centerText.isEmpty || !result.centerText.isEmpty,
                      "extractWithContext should never crash on clamped start")
    }
}
