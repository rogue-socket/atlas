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
        UserDefaults.standard.removeObject(forKey: AppConstants.openSessionBookmarksKey)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            UserDefaults.standard.removeObject(forKey: AppConstants.openSessionBookmarksKey)
        }

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
    func testCloseOtherDocuments_restoredDocuments_releaseClosedScopesAndKeepSelection() {
        let urls = (0..<3).compactMap { _ in writeTempPDF() }
        guard urls.count == 3 else {
            XCTFail("Failed to write temp PDFs")
            return
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let scope = CountingScopeAccessor()
        let (manager, userDefaults, suiteName) = makeManager(scope: scope)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        manager.restoreFromBookmarks([Data([0]), Data([1]), Data([2])], resolver: { bookmark in
            urls[Int(bookmark.first ?? 0)]
        })
        XCTAssertEqual(manager.documents.count, 3)

        let retained = manager.documents[1]
        let closedURLs = [manager.documents[0].url, manager.documents[2].url]
        manager.startComparison(left: manager.documents[0], right: manager.documents[2])

        manager.closeOtherDocuments(keeping: retained)

        XCTAssertEqual(manager.documents, [retained])
        XCTAssertEqual(manager.selectedDocumentID, retained.id)
        XCTAssertEqual(scope.stopCount, 2, "Closing other restored tabs should release each closed scope")
        XCTAssertEqual(Set(scope.stoppedURLs), Set(closedURLs))
        XCTAssertNil(manager.comparisonDocuments.left)
        XCTAssertNil(manager.comparisonDocuments.right)
        guard let sessionData = UserDefaults.standard.data(forKey: AppConstants.openSessionBookmarksKey),
              let bookmarks = try? JSONDecoder().decode([Data].self, from: sessionData) else {
            XCTFail("Close Other Tabs should persist the retained tab snapshot")
            return
        }
        XCTAssertEqual(bookmarks.count, 1)
        if case .single = manager.viewMode {
            // Expected after both comparison documents were closed.
        } else {
            XCTFail("Comparison mode should exit when both comparison documents are closed")
        }
    }
}
