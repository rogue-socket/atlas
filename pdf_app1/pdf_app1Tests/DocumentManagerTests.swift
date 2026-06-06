import XCTest
import PDFKit
import AppKit

@testable import pdf_app1

final class DocumentManagerTests: XCTestCase {

    /// Counts start/stop calls so tests can assert scope balance without
    /// touching the real sandbox.
    final class CountingScopeAccessor: SecurityScopeAccessing {
        var startCount = 0
        var stopCount = 0
        var stoppedURLs: [URL] = []

        func start(for url: URL) -> Bool {
            startCount += 1
            return true
        }

        func stop(for url: URL) {
            stopCount += 1
            stoppedURLs.append(url)
        }
    }

    private func writeTempPDF() -> URL? {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.string = "Test PDF content"
        guard let pdfData = textView.dataWithPDF(inside: textView.bounds) as Data? else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("docmgr-test-\(UUID().uuidString).pdf")
        do {
            try pdfData.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func makeManager(scope: SecurityScopeAccessing) -> (DocumentManager, UserDefaults, String) {
        let suiteName = "test-docmgr-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let recent = RecentFilesManager(userDefaults: userDefaults)
        let manager = DocumentManager(recentFilesManager: recent, scopeAccessor: scope)
        return (manager, userDefaults, suiteName)
    }

    // The dedup guard at the top of the per-bookmark loop used to fire AFTER
    // `startAccessingSecurityScopedResource`, so a duplicate bookmark
    // (two distinct bookmark Datas resolving to the same canonical URL)
    // would leak one scope ref-count per dup. After the fix, dedup runs
    // before scope acquisition; the second iteration short-circuits with
    // no scope acquired.
    @MainActor
    func testRestoreFromBookmarks_duplicateBookmarksResolveToSameURL_acquiresScopeOnce() {
        guard let url = writeTempPDF() else {
            XCTFail("Failed to write temp PDF")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        // Two distinct bookmark blobs both pointing at the same URL — the
        // resolver collapses them deterministically.
        let bookmarkA = Data([0x01])
        let bookmarkB = Data([0x02])
        manager.restoreFromBookmarks([bookmarkA, bookmarkB], resolver: { _ in url })

        XCTAssertEqual(manager.documents.count, 1, "Duplicate URLs should produce one document")
        XCTAssertEqual(scope.startCount, 1, "Scope should be acquired exactly once (pre-fix: 2 — leak)")
        XCTAssertEqual(scope.stopCount, 0, "Successful restore should not stop scope (held until close)")
    }

    // Closing a restored document must release the scope acquired by
    // `restoreFromBookmarks`. Without `needsScopeRelease` + the stop
    // call in `closeDocument`, the scope leaks until app termination —
    // bounded but real across long open/close cycles.
    @MainActor
    func testCloseDocument_restoredDocument_releasesScope() {
        guard let url = writeTempPDF() else {
            XCTFail("Failed to write temp PDF")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        manager.restoreFromBookmarks([Data([0x01])], resolver: { _ in url })
        XCTAssertEqual(manager.documents.count, 1)
        guard let doc = manager.documents.first else {
            XCTFail("Document not added")
            return
        }

        manager.closeDocument(doc)
        XCTAssertEqual(scope.stopCount, 1, "Closing a restored document should release its scope")
        XCTAssertEqual(scope.stoppedURLs.first, url, "Stop should be called on the restored URL")
    }

    // NSOpenPanel-opened docs (the `openDocument` path) get implicit
    // access from the system — no explicit `start` happens. `closeDocument`
    // must not call `stop` on them, or PDFKit will log an unbalanced-pair
    // warning at runtime.
    @MainActor
    func testCloseDocument_openedDocument_doesNotCallStop() {
        guard let url = writeTempPDF() else {
            XCTFail("Failed to write temp PDF")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let result = manager.openDocument(url)
        XCTAssertEqual(result, .success)
        guard let doc = manager.documents.first else {
            XCTFail("Document not added")
            return
        }

        manager.closeDocument(doc)
        XCTAssertEqual(scope.startCount, 0, "openDocument should not acquire scope")
        XCTAssertEqual(scope.stopCount, 0, "closing an openDocument-tab must not call stop")
    }

    @MainActor
    func testCloseDocument_openedDocumentWithStartedScope_releasesScope() {
        guard let url = writeTempPDF() else {
            XCTFail("Failed to write temp PDF")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let result = manager.openDocument(url, securityScopedAccessStarted: true)
        XCTAssertEqual(result, .success)
        guard let doc = manager.documents.first else {
            XCTFail("Document not added")
            return
        }

        manager.closeDocument(doc)
        XCTAssertEqual(scope.stopCount, 1, "closing an explicitly scoped openDocument-tab should release its scope")
        XCTAssertEqual(scope.stoppedURLs.first, url)
    }

    @MainActor
    func testOpenDocument_existingURLAtCapacity_returnsAlreadyOpen() {
        var urls: [URL] = []
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        for _ in 0..<10 {
            guard let url = writeTempPDF() else {
                XCTFail("Failed to write temp PDF")
                return
            }
            urls.append(url)
            XCTAssertEqual(manager.openDocument(url), .success)
        }

        XCTAssertEqual(manager.documents.count, 10)
        let result = manager.openDocument(urls[0], securityScopedAccessStarted: true)
        XCTAssertEqual(result, .alreadyOpen)
        XCTAssertEqual(manager.documents.count, 10)
        XCTAssertEqual(manager.selectedDocument?.url, urls[0])
    }
}
