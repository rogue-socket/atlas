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

    /// Tracer for the async file-check machinery: adding a URL whose target file
    /// doesn't exist on disk should leave that index in `inaccessibleFiles` once
    /// the async file check completes.
    func testInaccessibleFileMarkedAfterAsyncCheck() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let bookmarker = URLDataBookmarker()
        let missing = URL(fileURLWithPath: "/tmp/atlas-nonexistent-\(UUID().uuidString).pdf")

        let manager = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        manager.addRecentFile(missing)

        waitForFileChecks(manager)

        XCTAssertEqual(manager.recentFiles, [missing])
        XCTAssertTrue(manager.inaccessibleFiles.contains(0),
                      "expected index 0 to be marked inaccessible, got \(manager.inaccessibleFiles)")
    }

    /// A file that has been discovered stale on 3 consecutive launches should
    /// be auto-removed on the 3rd stale launch. The initial launch where the
    /// user *adds* the file is a setup step, not a stale discovery.
    func testInaccessibleFileAutoRemovedAfterThreeStaleLaunches() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let bookmarker = URLDataBookmarker()
        let missing = URL(fileURLWithPath: "/tmp/atlas-nonexistent-\(UUID().uuidString).pdf")

        // Launch 1 — user adds the file. Not yet a "stale discovery" since
        // the addRecentFile happens after init's auto-remove barrier fires.
        let s1 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        s1.addRecentFile(missing)
        waitForFileChecks(s1)
        XCTAssertEqual(s1.recentFiles, [missing], "present after add")

        // Launches 2 & 3 — stale discoveries. Counter goes 0→1, then 1→2.
        let s2 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s2)
        XCTAssertEqual(s2.recentFiles, [missing], "still present after 1st stale launch")

        let s3 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s3)
        XCTAssertEqual(s3.recentFiles, [missing], "still present after 2nd stale launch")

        // Launch 4 — 3rd stale discovery, counter hits threshold, file auto-removed.
        let s4 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s4)
        XCTAssertEqual(s4.recentFiles, [], "auto-removed after 3rd stale launch")
    }

    /// Manually removing an inaccessible file should clear its stale counter,
    /// so re-adding the same URL later starts fresh from 0 rather than
    /// inheriting prior stale-launch counts.
    func testRemoveInaccessibleFileResetsStaleCounter() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let bookmarker = URLDataBookmarker()
        let missing = URL(fileURLWithPath: "/tmp/atlas-nonexistent-\(UUID().uuidString).pdf")

        // Setup: add the file, then 2 stale launches (counter → 2).
        let s1 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        s1.addRecentFile(missing)
        waitForFileChecks(s1)

        let s2 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s2)
        let s3 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s3)
        XCTAssertEqual(s3.recentFiles, [missing], "still present at counter=2")

        // Manual remove + re-add (counter should reset).
        s3.removeInaccessibleFile(at: 0)
        XCTAssertEqual(s3.recentFiles, [])
        s3.addRecentFile(missing)
        waitForFileChecks(s3)

        // Two more stale launches. If the counter had inherited the prior 2,
        // launch 5 here would auto-remove (2 + 1 + 1 = 4). With the reset
        // it's only at 2 — still under threshold.
        let s4 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s4)
        let s5 = RecentFilesManager(userDefaults: defaults, bookmarker: bookmarker)
        waitForFileChecks(s5)
        XCTAssertEqual(s5.recentFiles, [missing],
                       "still present — counter should have reset on removeInaccessibleFile")
    }

    /// Data-loss regression: when `resolveBookmark` fails transiently (USB
    /// unplugged, sandbox revoked, ScopedBookmarksAgent hung — none of which
    /// mean the file is actually gone), `loadRecentFiles` previously deleted
    /// the bookmark from persistence immediately, bypassing the 3-launch
    /// stale counter. The graph orphan sweep then GC'd the per-doc graph file
    /// because the URL was no longer in any alive-set source.
    ///
    /// Expected behavior: the bookmark survives on disk, the URL surfaces in
    /// `recentFiles` (extracted from the bookmark blob via `pathFromBookmark`,
    /// no security scope needed), and the index is marked inaccessible so the
    /// existing 3-launch counter can own the eventual cleanup.
    func testUnresolvableBookmark_PreservesEntryAndBookmarkForSweep() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let url = URL(fileURLWithPath: "/tmp/atlas-bookmark-recovery-\(UUID().uuidString).pdf")

        // Setup: add a file with a working bookmarker so a real bookmark blob
        // lands in UserDefaults.
        let workingBookmarker = URLDataBookmarker()
        let s1 = RecentFilesManager(userDefaults: defaults, bookmarker: workingBookmarker)
        s1.addRecentFile(url)
        XCTAssertEqual(s1.recentFiles, [url])

        let persistedBefore = (try? JSONDecoder().decode([Data].self,
            from: defaults.data(forKey: AppConstants.recentFilesBookmarksKey) ?? Data())) ?? []
        XCTAssertEqual(persistedBefore.count, 1, "1 bookmark on disk after add")

        // Simulated "next launch": same UserDefaults, but the resolver now fails.
        let failingBookmarker = FailingResolveBookmarker()
        let s2 = RecentFilesManager(userDefaults: defaults, bookmarker: failingBookmarker)
        waitForFileChecks(s2)

        // (a) Bookmark blob must NOT be deleted from persistence.
        let persistedAfter = (try? JSONDecoder().decode([Data].self,
            from: defaults.data(forKey: AppConstants.recentFilesBookmarksKey) ?? Data())) ?? []
        XCTAssertEqual(persistedAfter.count, 1,
                       "bookmark must survive a transient resolve failure (got \(persistedAfter.count))")

        // (b) URL must surface in recentFiles (path extracted from bookmark blob)
        //     so the orphan-sweep alive-set keeps the per-doc graph file.
        XCTAssertEqual(s2.recentFiles, [url],
                       "URL must be derivable from bookmark blob even when resolve fails")

        // (c) Index 0 must be marked inaccessible so the 3-launch stale counter
        //     can own the eventual cleanup.
        XCTAssertTrue(s2.inaccessibleFiles.contains(0),
                      "expected index 0 to be marked inaccessible, got \(s2.inaccessibleFiles)")
    }

    /// Companion: even when `resolveBookmark` fails for 3 launches in a row,
    /// the stale counter still fires and removes the entry. The fix must not
    /// break the existing auto-removal contract.
    func testUnresolvableBookmark_StillAutoRemovedAfterThreeStaleLaunches() throws {
        let suiteName = "RecentFilesManagerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        let url = URL(fileURLWithPath: "/tmp/atlas-stale-recovery-\(UUID().uuidString).pdf")

        let s1 = RecentFilesManager(userDefaults: defaults, bookmarker: URLDataBookmarker())
        s1.addRecentFile(url)
        waitForFileChecks(s1)

        // Three consecutive failing-resolve launches: counter goes 1, 2, 3.
        let failing = FailingResolveBookmarker()
        let s2 = RecentFilesManager(userDefaults: defaults, bookmarker: failing)
        waitForFileChecks(s2)
        XCTAssertEqual(s2.recentFiles, [url], "present after 1st stale launch")

        let s3 = RecentFilesManager(userDefaults: defaults, bookmarker: failing)
        waitForFileChecks(s3)
        XCTAssertEqual(s3.recentFiles, [url], "present after 2nd stale launch")

        let s4 = RecentFilesManager(userDefaults: defaults, bookmarker: failing)
        waitForFileChecks(s4)
        XCTAssertEqual(s4.recentFiles, [], "auto-removed after 3rd stale launch")

        let persistedAfter = (try? JSONDecoder().decode([Data].self,
            from: defaults.data(forKey: AppConstants.recentFilesBookmarksKey) ?? Data())) ?? []
        XCTAssertEqual(persistedAfter.count, 0,
                       "bookmark blob also removed on the auto-remove pass")
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
