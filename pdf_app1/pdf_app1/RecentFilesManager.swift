//
//  RecentFilesManager.swift
//  PDFViewer
//
//  Manages recent PDF files using security-scoped bookmarks for persistence
//
//  Uses security-scoped bookmarks to maintain file access across app sessions.
//  This allows the app to access files even after restart, as long as the files
//  haven't been moved or deleted.
//

import SwiftUI
import Combine
import AppKit

protocol RecentFilesBookmarking {
    func createBookmark(for url: URL) -> Data?
    func resolveBookmark(_ data: Data, isStale: inout Bool) -> URL?
    func refreshBookmark(for url: URL) -> Data?
    /// Returns the URL the bookmark blob was originally created for, without
    /// going through the security-scope daemon. Lets us recover the path of
    /// an unresolvable bookmark (USB unplugged, sandbox revoked, etc.) so the
    /// orphan-sweep alive-set still finds the graph file before the 3-launch
    /// stale counter runs to completion.
    func pathFromBookmark(_ data: Data) -> URL?
}

struct SecurityScopedRecentFilesBookmarker: RecentFilesBookmarking {
    func createBookmark(for url: URL) -> Data? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data, isStale: inout Bool) -> URL? {
        try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    func refreshBookmark(for url: URL) -> Data? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func pathFromBookmark(_ data: Data) -> URL? {
        guard let values = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: data),
              let path = values.path else { return nil }
        return URL(fileURLWithPath: path)
    }
}

class RecentFilesManager: ObservableObject {
    @Published var recentFiles: [URL] = []
    @Published var inaccessibleFiles: Set<Int> = [] // Track indices of inaccessible files

    private let maxRecentFiles = AppConstants.maxRecentFiles
    private let userDefaultsKey = AppConstants.recentFilesBookmarksKey
    private let staleLaunchCounterKey = "RecentFiles.staleLaunchCounter"
    private let userDefaults: UserDefaults
    private let bookmarker: RecentFilesBookmarking
    let fileCheckQueue = DispatchQueue(label: "file.check", qos: .utility)
    private var lastFileCheckTime: Date = Date.distantPast
    private let fileCheckThrottleInterval: TimeInterval = 5.0

    init(userDefaults: UserDefaults = .standard, bookmarker: RecentFilesBookmarking = SecurityScopedRecentFilesBookmarker()) {
        self.userDefaults = userDefaults
        self.bookmarker = bookmarker
        loadRecentFiles()
        // autoRemoveStaleFiles must run AFTER the async file-existence checks
        // queued by loadRecentFiles populate `inaccessibleFiles`. fileCheckQueue
        // is serial, so this trailing dispatch acts as a barrier; the inner
        // main.async then runs after the per-file `inaccessibleFiles.insert`
        // hops (also queued on main).
        fileCheckQueue.async { [weak self] in
            DispatchQueue.main.async {
                self?.autoRemoveStaleFiles()
            }
        }
    }
    
    /// Add a file to recent files list using security-scoped bookmark
    func addRecentFile(_ url: URL) {
        // Create bookmark data
        guard let bookmarkData = bookmarker.createBookmark(for: url) else {
            print("Warning: Failed to create bookmark for \(url.path)")
            return
        }

        // Load existing bookmarks
        var bookmarks: [Data] = []
        if let existingData = userDefaults.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([Data].self, from: existingData) {
            bookmarks = decoded
        }

        // Dedup by URL match against in-memory `recentFiles`. The list
        // was already resolved on app start; comparing URLs directly
        // avoids re-resolving every bookmark just to find a duplicate.
        if let dupIndex = recentFiles.firstIndex(of: url), dupIndex < bookmarks.count {
            bookmarks.remove(at: dupIndex)
            recentFiles.remove(at: dupIndex)
            inaccessibleFiles = Set(inaccessibleFiles.compactMap {
                $0 == dupIndex ? nil : ($0 > dupIndex ? $0 - 1 : $0)
            })
        }

        // Insert at top
        bookmarks.insert(bookmarkData, at: 0)
        recentFiles.insert(url, at: 0)
        // Existing inaccessible indices shift up by 1; the new entry at
        // index 0 was just successfully opened so it's not inaccessible.
        inaccessibleFiles = Set(inaccessibleFiles.map { $0 + 1 })

        // Trim to maxRecentFiles
        if bookmarks.count > maxRecentFiles {
            let droppedRange = maxRecentFiles..<bookmarks.count
            bookmarks = Array(bookmarks.prefix(maxRecentFiles))
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
            inaccessibleFiles = inaccessibleFiles.filter { !droppedRange.contains($0) }
        }

        saveBookmarks(bookmarks)

        // Async file-existence check for the newly-added URL only
        // (mirrors the per-entry check that used to fire via loadRecentFiles).
        // Look up the index when the check completes since other adds may
        // shift it in the meantime.
        let addedURL = url
        fileCheckQueue.async { [weak self] in
            if !FileManager.default.fileExists(atPath: addedURL.path) {
                DispatchQueue.main.async {
                    guard let self,
                          let idx = self.recentFiles.firstIndex(of: addedURL) else { return }
                    self.inaccessibleFiles.insert(idx)
                }
            }
        }
    }

    /// Remove files at specified indices
    func removeFiles(at offsets: IndexSet) {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              var bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            return
        }

        bookmarks.remove(atOffsets: offsets)
        recentFiles.remove(atOffsets: offsets)
        // Drop removed indices from inaccessibleFiles; shift the rest down.
        inaccessibleFiles = Set(inaccessibleFiles.compactMap { idx in
            if offsets.contains(idx) { return nil }
            let shift = offsets.filter { $0 < idx }.count
            return idx - shift
        })

        saveBookmarks(bookmarks)
    }
    
    /// Remove inaccessible file at index and clear its stale counter
    func removeInaccessibleFile(at index: Int) {
        if index < recentFiles.count {
            var counter = userDefaults.dictionary(forKey: staleLaunchCounterKey) as? [String: Int] ?? [:]
            counter.removeValue(forKey: recentFiles[index].path)
            userDefaults.set(counter, forKey: staleLaunchCounterKey)
        }
        removeFiles(at: IndexSet(integer: index))
    }
    
    /// Load recent files from bookmarks. Bookmarks that can't be resolved
    /// right now are kept on disk and surfaced via the path embedded in the
    /// bookmark blob (`pathFromBookmark`), marked inaccessible so the existing
    /// 3-launch stale counter owns the eventual cleanup. Bookmarks whose blob
    /// can't even yield a path are the only entries we drop here.
    func loadRecentFiles() {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              var bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            recentFiles = []
            inaccessibleFiles = []
            return
        }

        let now = Date()
        let shouldSkipFileCheck = now.timeIntervalSince(lastFileCheckTime) < fileCheckThrottleInterval

        var loadedURLs: [URL] = []
        var inaccessibleSet: Set<Int> = []
        var unrecoverableIndices: [Int] = []   // bookmark blob can't even yield a path → drop
        var didRefreshAny = false

        for (index, bookmarkData) in bookmarks.enumerated() {
            var isStale = false
            if let url = bookmarker.resolveBookmark(bookmarkData, isStale: &isStale) {
                if isStale, let refreshed = bookmarker.refreshBookmark(for: url) {
                    bookmarks[index] = refreshed
                    didRefreshAny = true
                }
                loadedURLs.append(url)

                // Check file existence (throttled). If the file is gone, mark
                // the index inaccessible so the 3-launch counter can fire.
                if !shouldSkipFileCheck {
                    let loadedIndex = loadedURLs.count - 1
                    fileCheckQueue.async { [weak self] in
                        if !FileManager.default.fileExists(atPath: url.path) {
                            DispatchQueue.main.async {
                                self?.inaccessibleFiles.insert(loadedIndex)
                            }
                        }
                    }
                }
            } else if let url = bookmarker.pathFromBookmark(bookmarkData) {
                // Transient resolve failure (USB unplugged, sandbox quirk,
                // ScopedBookmarksAgent hung). Keep the bookmark on disk, surface
                // the URL so orphan-sweep doesn't GC the per-doc graph, and
                // mark inaccessible so the 3-launch counter owns deletion.
                loadedURLs.append(url)
                inaccessibleSet.insert(loadedURLs.count - 1)
            } else {
                // Bookmark blob is unrecoverable — neither resolve nor path
                // extraction works. Rare; drop it so the list doesn't grow
                // dead entries forever.
                unrecoverableIndices.append(index)
            }
        }

        if !shouldSkipFileCheck {
            lastFileCheckTime = now
        }

        if !unrecoverableIndices.isEmpty {
            for index in unrecoverableIndices.reversed() {
                bookmarks.remove(at: index)
            }
        }

        if !unrecoverableIndices.isEmpty || didRefreshAny {
            saveBookmarks(bookmarks)
        }

        recentFiles = loadedURLs
        inaccessibleSet.formUnion(inaccessibleFiles) // keep any previously detected inaccessible entries
        inaccessibleFiles = inaccessibleSet
    }

    /// Increment stale launch counter for inaccessible files and auto-remove those seen stale for 3+ launches.
    private func autoRemoveStaleFiles() {
        guard !inaccessibleFiles.isEmpty else { return }

        var counter = userDefaults.dictionary(forKey: staleLaunchCounterKey) as? [String: Int] ?? [:]
        var indicesToRemove: [Int] = []

        for index in inaccessibleFiles {
            guard index < recentFiles.count else { continue }
            let key = recentFiles[index].path
            let count = (counter[key] ?? 0) + 1
            counter[key] = count

            if count >= 3 {
                indicesToRemove.append(index)
                counter.removeValue(forKey: key)
            }
        }

        userDefaults.set(counter, forKey: staleLaunchCounterKey)

        if !indicesToRemove.isEmpty {
            removeFiles(at: IndexSet(indicesToRemove))
        }
    }
    
    /// Resolve bookmark data to URL (for duplicate checking only)
    private func resolveBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        return bookmarker.resolveBookmark(bookmarkData, isStale: &isStale)
    }
    
    /// Save bookmarks to UserDefaults
    private func saveBookmarks(_ bookmarks: [Data]) {
        do {
            let data = try JSONEncoder().encode(bookmarks)
            userDefaults.set(data, forKey: userDefaultsKey)
        } catch {
            print("Error saving recent files bookmarks: \(error.localizedDescription)")
        }
    }
}

