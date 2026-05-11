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
    private var fileCheckWorkItem: DispatchWorkItem?
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
        
        // Remove duplicate bookmark (if exists)
        bookmarks.removeAll { existingBookmark in
            if let existingURL = resolveBookmark(existingBookmark), existingURL == url {
                return true
            }
            return false
        }
        
        // Add new bookmark to beginning
        bookmarks.insert(bookmarkData, at: 0)
        
        // Limit to maxRecentFiles
        if bookmarks.count > maxRecentFiles {
            bookmarks = Array(bookmarks.prefix(maxRecentFiles))
        }
        
        // Save bookmarks
        saveBookmarks(bookmarks)
        
        // Reload recent files
        loadRecentFiles()
    }
    
    /// Remove files at specified indices
    func removeFiles(at offsets: IndexSet) {
        // Load bookmarks
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              var bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            return
        }
        
        // Remove bookmarks at offsets
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks(bookmarks)
        
        // Reload recent files
        loadRecentFiles()
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
    
    /// Load recent files from bookmarks. Inaccessible files are kept but tracked in `inaccessibleFiles`.
    func loadRecentFiles() {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              var bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            recentFiles = []
            inaccessibleFiles = []
            return
        }

        let now = Date()
        let shouldSkipFileCheck = now.timeIntervalSince(lastFileCheckTime) < fileCheckThrottleInterval

        var resolvedURLs: [URL] = []
        var unresolvedIndices: [Int] = []
        var inaccessible: Set<Int> = []
        var didRefreshAny = false

        for (index, bookmarkData) in bookmarks.enumerated() {
            var isStale = false
            guard let url = bookmarker.resolveBookmark(bookmarkData, isStale: &isStale) else {
                // Bookmark can't be resolved at all — keep in list as inaccessible
                unresolvedIndices.append(index)
                continue
            }

            // Persist refreshed bookmark data when stale
            if isStale, let refreshed = bookmarker.refreshBookmark(for: url) {
                bookmarks[index] = refreshed
                didRefreshAny = true
            }

            resolvedURLs.append(url)

            // Check file existence (throttled)
            if !shouldSkipFileCheck {
                let resolvedIndex = resolvedURLs.count - 1
                fileCheckQueue.async { [weak self] in
                    if !FileManager.default.fileExists(atPath: url.path) {
                        DispatchQueue.main.async {
                            self?.inaccessibleFiles.insert(resolvedIndex)
                        }
                    }
                }
            }
        }

        if !shouldSkipFileCheck {
            lastFileCheckTime = now
        }

        // For unresolved bookmarks, add placeholder URLs so indices stay aligned
        // Actually, we skip them and track by resolved index — simpler to just remove unresolvable ones
        if !unresolvedIndices.isEmpty {
            for index in unresolvedIndices.reversed() {
                bookmarks.remove(at: index)
            }
        }

        if !unresolvedIndices.isEmpty || didRefreshAny {
            saveBookmarks(bookmarks)
        }

        recentFiles = resolvedURLs
        inaccessible.formUnion(inaccessibleFiles) // keep any previously detected inaccessible entries
        inaccessibleFiles = inaccessible
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

