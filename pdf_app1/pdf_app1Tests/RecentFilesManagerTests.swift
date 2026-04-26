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
}
