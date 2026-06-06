import XCTest
@testable import pdf_app1

/// Tests for `Atlas/UI/UnifiedSearchManager.swift` — the routing flags for
/// Cmd+F context-aware search vs Cmd+Shift+F unified search.
final class UnifiedSearchManagerTests: XCTestCase {

    // MARK: - Initial state

    func test_defaultStateAllOff_focusOnPDF() {
        let m = UnifiedSearchManager()
        XCTAssertEqual(m.focusedPane, .pdf)
        XCTAssertFalse(m.isSearchingPDF)
        XCTAssertFalse(m.isSearchingMap)
        XCTAssertFalse(m.isSearchingBoth)
    }

    // MARK: - activateContextSearch routes by focusedPane

    func test_activateContextSearch_pdfFocus_routesToPDFOnly() {
        let m = UnifiedSearchManager()
        m.focusedPane = .pdf
        m.activateContextSearch()
        XCTAssertTrue(m.isSearchingPDF)
        XCTAssertFalse(m.isSearchingMap)
        XCTAssertFalse(m.isSearchingBoth)
    }

    func test_activateContextSearch_mapFocus_routesToMapOnly() {
        let m = UnifiedSearchManager()
        m.focusedPane = .map
        m.activateContextSearch()
        XCTAssertTrue(m.isSearchingMap)
        XCTAssertFalse(m.isSearchingPDF)
        XCTAssertFalse(m.isSearchingBoth)
    }

    func test_activateContextSearch_clearsAnyPriorBothFlag() {
        let m = UnifiedSearchManager()
        m.isSearchingBoth = true
        m.focusedPane = .pdf
        m.activateContextSearch()
        XCTAssertFalse(m.isSearchingBoth)
    }

    // MARK: - activateUnifiedSearch enables all three flags

    func test_activateUnifiedSearch_enablesAllThreeFlags() {
        let m = UnifiedSearchManager()
        m.activateUnifiedSearch()
        XCTAssertTrue(m.isSearchingPDF)
        XCTAssertTrue(m.isSearchingMap)
        XCTAssertTrue(m.isSearchingBoth)
    }

    // MARK: - dismissSearch resets

    func test_dismissSearch_resetsAllFlagsButKeepsFocusedPane() {
        let m = UnifiedSearchManager()
        m.focusedPane = .map
        m.activateUnifiedSearch()
        m.dismissSearch()
        XCTAssertFalse(m.isSearchingPDF)
        XCTAssertFalse(m.isSearchingMap)
        XCTAssertFalse(m.isSearchingBoth)
        XCTAssertEqual(m.focusedPane, .map, "Focus survives dismissal")
    }
}
