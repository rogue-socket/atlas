import XCTest
import PDFKit

@testable import pdf_app1

final class PDFSearchManagerTests: XCTestCase {
    func testHistoryDedupesCaseInsensitiveAndTrims() {
        let manager = PDFSearchManager()
        let doc = PDFDocument()

        manager.performSearch("  hello ", in: doc)
        manager.performSearch("HELLO", in: doc)

        XCTAssertEqual(manager.searchHistory.count, 1)
        XCTAssertEqual(manager.searchHistory.first, "HELLO")
    }

    func testClearHistory() {
        let manager = PDFSearchManager()
        let doc = PDFDocument()

        manager.performSearch("one", in: doc)
        manager.performSearch("two", in: doc)
        XCTAssertFalse(manager.searchHistory.isEmpty)

        manager.clearHistory()
        XCTAssertTrue(manager.searchHistory.isEmpty)
    }
}
