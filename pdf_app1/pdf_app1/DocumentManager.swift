//
//  DocumentManager.swift
//  PDFViewer
//
//  Multi-document management system
//
//  Manages multiple open PDF documents with tabs, windows,
//  and comparison views while maintaining performance.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine
import os.log

private let log = AtlasLogger.ui

// MARK: - Security Scope Accessor

/// Thin seam around `URL.start/stopAccessingSecurityScopedResource()` so the
/// scope ref-count is countable in tests. Production uses the URL methods
/// directly; tests inject a counting fake.
protocol SecurityScopeAccessing {
    @discardableResult
    func start(for url: URL) -> Bool
    func stop(for url: URL)
}

struct DefaultSecurityScopeAccessor: SecurityScopeAccessing {
    @discardableResult
    func start(for url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stop(for url: URL) { url.stopAccessingSecurityScopedResource() }
}

// MARK: - Document Model
struct PDFDocumentItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let document: PDFKit.PDFDocument
    let projectID: UUID?  // Track which project this document belongs to
    /// True only for documents opened via `restoreOpenSession`, which explicitly
    /// starts security-scoped access. NSOpenPanel-opened docs inherit access
    /// implicitly (no balanced `start` exists), so `closeDocument` must not
    /// call `stop` on those — that would log a runtime warning on an unbalanced
    /// pair.
    var needsScopeRelease: Bool = false

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    static func == (lhs: PDFDocumentItem, rhs: PDFDocumentItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Document View Mode
enum DocumentViewMode {
    case single
    case comparison(splitView: ComparisonSplitView)
}

enum ComparisonSplitView {
    case sideBySide
    case vertical
    case horizontal
}

// MARK: - Open Result
enum OpenResult {
    case success
    case alreadyOpen
    case tooManyTabs
    case fileNotReadable
    case invalidPDF
}

// MARK: - Document Manager
class DocumentManager: ObservableObject {
    @Published var documents: [PDFDocumentItem] = []
    @Published var selectedDocumentID: UUID?
    @Published var viewMode: DocumentViewMode = .single
    @Published var comparisonDocuments: (left: PDFDocumentItem?, right: PDFDocumentItem?) = (nil, nil)
    
    private var maxOpenDocuments = 10
    let recentFilesManager: RecentFilesManager
    private let scopeAccessor: SecurityScopeAccessing

    init(recentFilesManager: RecentFilesManager,
         scopeAccessor: SecurityScopeAccessing = DefaultSecurityScopeAccessor()) {
        self.recentFilesManager = recentFilesManager
        self.scopeAccessor = scopeAccessor
    }

    var selectedDocument: PDFDocumentItem? {
        documents.first { $0.id == selectedDocumentID }
    }
    
    var canAddDocument: Bool {
        documents.count < maxOpenDocuments
    }
    
    // MARK: - Document Management
    @discardableResult
    func openDocument(_ url: URL, projectID: UUID? = nil) -> OpenResult {
        guard canAddDocument else {
            log.warning("[DocManager] openDocument rejected: too many tabs (\(self.documents.count)/\(self.maxOpenDocuments))")
            return .tooManyTabs
        }

        // Check if already open
        if documents.contains(where: { $0.url == url }) {
            log.info("[DocManager] openDocument: already open, selecting \(url.lastPathComponent)")
            selectDocument(url: url)
            return .alreadyOpen
        }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            log.error("[DocManager] openDocument: file not readable at \(url.path)")
            return .fileNotReadable
        }
        guard let document = PDFKit.PDFDocument(url: url) else {
            log.error("[DocManager] openDocument: invalid PDF at \(url.lastPathComponent)")
            return .invalidPDF
        }

        let pdfDoc = PDFDocumentItem(url: url, document: document, projectID: projectID)
        documents.append(pdfDoc)
        selectedDocumentID = pdfDoc.id
        recentFilesManager.addRecentFile(url)

        log.info("[DocManager] openDocument: \(url.lastPathComponent), \(document.pageCount) pages, tab \(self.documents.count)/\(self.maxOpenDocuments)")
        saveOpenSession()
        return .success
    }
    
    func openDocuments(_ urls: [URL], projectID: UUID? = nil) {
        for url in urls {
            if !canAddDocument { break }
            _ = openDocument(url, projectID: projectID)
        }
    }
    
    func openProjectFiles(_ projectID: UUID, files: [ProjectFile], projectsManager: ProjectsManager) {
        for file in files {
            if !canAddDocument { break }
            
            // Resolve the URL from the project file
            if let url = projectsManager.resolveURL(for: projectID, fileID: file.id) {
                _ = openDocument(url, projectID: projectID)
            }
        }
    }
    
    func closeDocument(_ document: PDFDocumentItem) {
        log.info("[DocManager] closeDocument: \(document.url.lastPathComponent) (remaining \(self.documents.count - 1)/\(self.maxOpenDocuments))")
        if document.needsScopeRelease {
            scopeAccessor.stop(for: document.url)
        }
        documents.removeAll { $0.id == document.id }

        // Update selection
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.first?.id
        }

        // Update comparison if needed
        updateComparisonAfterClosing(document)
        saveOpenSession()
    }
    
    func selectDocument(url: URL) {
        if let document = documents.first(where: { $0.url == url }) {
            selectedDocumentID = document.id
        }
    }
    
    func selectDocument(id: UUID) {
        selectedDocumentID = id
    }
    
    // MARK: - Comparison Mode
    func startComparison(left: PDFDocumentItem?, right: PDFDocumentItem?) {
        comparisonDocuments = (left, right)
        viewMode = .comparison(splitView: .sideBySide)
    }
    
    func setComparisonSplitView(_ splitView: ComparisonSplitView) {
        if case .comparison = viewMode {
            viewMode = .comparison(splitView: splitView)
        }
    }
    
    func exitComparisonMode() {
        viewMode = .single
        comparisonDocuments = (nil, nil)
    }
    
    private func updateComparisonAfterClosing(_ closedDocument: PDFDocumentItem) {
        if comparisonDocuments.left?.id == closedDocument.id {
            comparisonDocuments.left = nil
        }
        if comparisonDocuments.right?.id == closedDocument.id {
            comparisonDocuments.right = nil
        }
        
        // Exit comparison if both sides are empty
        if comparisonDocuments.left == nil && comparisonDocuments.right == nil {
            exitComparisonMode()
        }
    }
    
    // MARK: - Tab Management
    func moveDocument(from source: IndexSet, to destination: Int) {
        var newDocuments = documents
        newDocuments.move(fromOffsets: source, toOffset: destination)
        documents = newDocuments
        saveOpenSession()
    }
    
    // MARK: - Window Management
    func openInNewWindow(_ document: PDFDocumentItem) {
        NSWorkspace.shared.open(document.url)
    }

    // MARK: - Session Persistence

    /// Save bookmarks for all currently open tabs so they can be restored on next launch.
    /// Called both after each open/close/reorder (crash-safe snapshot) and from
    /// `willTerminate` (final flush). UserDefaults coalesces writes, so per-mutation
    /// calls are cheap.
    func saveOpenSession() {
        var failed: [String] = []
        let bookmarks: [Data] = documents.compactMap { item in
            if let data = try? item.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                return data
            } else {
                failed.append(item.url.lastPathComponent)
                return nil
            }
        }
        guard let encoded = try? JSONEncoder().encode(bookmarks) else {
            log.error("[DocManager] saveOpenSession: JSON encode failed for \(bookmarks.count) bookmark(s)")
            return
        }
        UserDefaults.standard.set(encoded, forKey: AppConstants.openSessionBookmarksKey)
        if failed.isEmpty {
            log.info("[DocManager] saveOpenSession: persisted \(bookmarks.count)/\(self.documents.count) tab(s)")
        } else {
            let failedList = failed.joined(separator: ", ")
            log.warning("[DocManager] saveOpenSession: persisted \(bookmarks.count)/\(self.documents.count) tab(s); bookmark creation failed for: \(failedList)")
        }
    }

    /// Restore tabs from the previous session's bookmarks.
    /// Uses security-scoped access directly instead of `openDocument` because
    /// `FileManager.isReadableFile` returns false for bookmark-resolved URLs in a sandboxed app.
    func restoreOpenSession() {
        // Skip session restore when the app is hosting an XCTest bundle —
        // loading real user PDFs/graphs during tests crashes the host (malloc
        // double-free observed 2026-05-09) and is wrong on principle.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        guard let data = UserDefaults.standard.data(forKey: AppConstants.openSessionBookmarksKey) else {
            log.info("[DocManager] restoreOpenSession: no saved session (key absent)")
            return
        }
        guard let bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            log.warning("[DocManager] restoreOpenSession: session data found but decode failed")
            return
        }
        if bookmarks.isEmpty {
            log.info("[DocManager] restoreOpenSession: saved session is empty")
            return
        }

        restoreFromBookmarks(bookmarks, resolver: resolveSessionBookmark)
    }

    /// Loop body of session restore, factored out so tests can inject a
    /// counting `SecurityScopeAccessing` and a pass-through resolver
    /// (the real `.withSecurityScope` resolver only works on bookmarks
    /// created with that flag, which tests can't readily produce).
    typealias BookmarkResolver = (Data) -> URL?

    func restoreFromBookmarks(_ bookmarks: [Data], resolver: BookmarkResolver) {
        var restoredCount = 0
        for bookmark in bookmarks {
            guard canAddDocument else { break }
            guard let url = resolver(bookmark) else { continue }

            // Dedup BEFORE acquiring scope. Two bookmarks can resolve to the
            // same canonical URL (symlinks, `/private` prefix on macOS), and
            // a start-then-skip path would leak a scope ref-count per dup.
            guard !documents.contains(where: { $0.url == url }) else { continue }

            // Start security-scoped access — held until `closeDocument`
            // releases it (the document needs continued access for PDFKit
            // page reads and any later `pdfDocument.write(to:)`).
            _ = scopeAccessor.start(for: url)

            guard let document = PDFKit.PDFDocument(url: url) else {
                scopeAccessor.stop(for: url)
                log.warning("[DocManager] restoreOpenSession: failed to open \(url.lastPathComponent)")
                continue
            }

            let pdfDoc = PDFDocumentItem(url: url, document: document, projectID: nil, needsScopeRelease: true)
            documents.append(pdfDoc)
            selectedDocumentID = pdfDoc.id
            recentFilesManager.addRecentFile(url)
            restoredCount += 1
        }
        log.info("[DocManager] restoreOpenSession: restored \(restoredCount)/\(bookmarks.count) tab(s)")
    }

    private func resolveSessionBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale {
                log.info("[DocManager] restoreOpenSession: stale bookmark for \(url.lastPathComponent) — will refresh on next saveOpenSession")
            }
            return url
        } catch {
            log.warning("[DocManager] restoreOpenSession: bookmark resolution failed (\(bookmark.count) bytes): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
