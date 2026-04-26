import XCTest
import AppKit
import PDFKit

final class PDFPersistenceIntegrationTests: XCTestCase {
    func testHighlightPersistsAfterSaveAndReload() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("sample.pdf")

        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let page = try XCTUnwrap(PDFPage(image: image))
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        XCTAssertTrue(doc.write(to: url))

        let opened = try XCTUnwrap(PDFDocument(url: url))
        let openedPage = try XCTUnwrap(opened.page(at: 0))

        let highlightBounds = CGRect(x: 10, y: 10, width: 50, height: 12)
        let highlight = PDFAnnotation(bounds: highlightBounds, forType: .highlight, withProperties: nil)
        highlight.color = NSColor.yellow.withAlphaComponent(0.3)
        openedPage.addAnnotation(highlight)

        XCTAssertTrue(opened.write(to: url))

        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        let reloadedPage = try XCTUnwrap(reloaded.page(at: 0))

        XCTAssertTrue(reloadedPage.annotations.contains { $0.type == "Highlight" })
    }
}
