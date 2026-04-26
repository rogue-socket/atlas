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
    @Published var inaccessibleFiles: [Int] = [] // Track indices of inaccessible files
    
    private let maxRecentFiles = AppConstants.maxRecentFiles
    private let userDefaultsKey = AppConstants.recentFilesBookmarksKey
    private let userDefaults: UserDefaults
    private let bookmarker: RecentFilesBookmarking
    private let fileCheckQueue = DispatchQueue(label: "file.check", qos: .utility)
    private var fileCheckWorkItem: DispatchWorkItem?
    private var lastFileCheckTime: Date = Date.distantPast
    private let fileCheckThrottleInterval: TimeInterval = 5.0
    
    init(userDefaults: UserDefaults = .standard, bookmarker: RecentFilesBookmarking = SecurityScopedRecentFilesBookmarker()) {
        self.userDefaults = userDefaults
        self.bookmarker = bookmarker
        loadRecentFiles()
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
    
    /// Remove inaccessible file at index
    func removeInaccessibleFile(at index: Int) {
        var offsets = IndexSet()
        offsets.insert(index)
        removeFiles(at: offsets)
    }
    
    /// Load recent files from bookmarks with throttled file system checks
    private func loadRecentFiles() {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              var bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            recentFiles = []
            return
        }

        let now = Date()
        let shouldSkipFileCheck = now.timeIntervalSince(lastFileCheckTime) < fileCheckThrottleInterval

        var resolvedURLs: [URL] = []
        var staleIndices: [Int] = []
        var didRefreshAny = false

        for (index, bookmarkData) in bookmarks.enumerated() {
            var isStale = false
            guard let url = bookmarker.resolveBookmark(bookmarkData, isStale: &isStale) else {
                staleIndices.append(index)
                continue
            }

            // Persist refreshed bookmark data when stale
            if isStale, let refreshed = bookmarker.refreshBookmark(for: url) {
                bookmarks[index] = refreshed
                didRefreshAny = true
            }

            // Throttle file existence checks for performance
            if !shouldSkipFileCheck {
                fileCheckQueue.async { [weak self] in
                    if !FileManager.default.fileExists(atPath: url.path) {
                        DispatchQueue.main.async {
                            self?.scheduleFileCleanup()
                        }
                    }
                }
            }
            resolvedURLs.append(url)
        }

        if !shouldSkipFileCheck {
            lastFileCheckTime = now
        }

        // Remove stale bookmarks and save refreshed ones
        if !staleIndices.isEmpty {
            for index in staleIndices.reversed() {
                bookmarks.remove(at: index)
            }
        }

        if !staleIndices.isEmpty || didRefreshAny {
            saveBookmarks(bookmarks)
        }

        recentFiles = resolvedURLs
    }
    
    /// Schedule file cleanup with throttling
    private func scheduleFileCleanup() {
        fileCheckWorkItem?.cancel()
        fileCheckWorkItem = DispatchWorkItem { [weak self] in
            self?.performFileCleanup()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: fileCheckWorkItem!)
    }
    
    /// Perform actual file cleanup
    private func performFileCleanup() {
        guard let data = userDefaults.data(forKey: userDefaultsKey),
              let bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            return
        }
        
        var staleIndices: [Int] = []
        
        for (index, bookmarkData) in bookmarks.enumerated() {
            if let url = resolveBookmark(bookmarkData) {
                if !FileManager.default.fileExists(atPath: url.path) {
                    staleIndices.append(index)
                }
            } else {
                staleIndices.append(index)
            }
        }
        
        if !staleIndices.isEmpty {
            var updatedBookmarks = bookmarks
            for index in staleIndices.reversed() {
                updatedBookmarks.remove(at: index)
            }
            saveBookmarks(updatedBookmarks)
            loadRecentFiles()
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

