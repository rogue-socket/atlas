import Foundation
import XCTest

@testable import pdf_app1

final class RecentFilesManagerTests: XCTestCase {
    func testAddRecentFileDedupesAndKeepsMostRecentFirst() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)

        let bookmarker = URLDataBookmarker()
        let manager = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)

        let url1 = URL(fileURLWithPath: "/tmp/a.pdf")
        let url2 = URL(fileURLWithPath: "/tmp/b.pdf")

        manager.addRecentFile(url1)
        manager.addRecentFile(url2)
        manager.addRecentFile(url1)

        XCTAssertEqual(manager.recentFiles.first, url1)
        XCTAssertEqual(manager.recentFiles.count, 2)
    }

    /// Cross-reboot tracer: a file added in one manager instance is still
    /// present after a "reboot" (new manager with the same UserDefaults).
    func testFilesPersistAcrossReboot() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let bookmarker = URLDataBookmarker()
        let url = URL(fileURLWithPath: "/tmp/persist.pdf")

        let session1 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        session1.addRecentFile(url)
        XCTAssertEqual(session1.recentFiles, [url])

        // Reboot: throw away session1, build a fresh manager from the same defaults.
        let session2 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        XCTAssertEqual(session2.recentFiles, [url])
    }
}
