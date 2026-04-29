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

// MARK: - Document Model
struct PDFDocumentItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let document: PDFKit.PDFDocument
    let projectID: UUID?  // Track which project this document belongs to
    var title: String {
        url.lastPathComponent.replacingOccurrences(of: ".pdf", with: "")
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
    weak var recentFilesManager: RecentFilesManager?

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
        recentFilesManager?.addRecentFile(url)

        log.info("[DocManager] openDocument: \(url.lastPathComponent), \(document.pageCount) pages, tab \(self.documents.count)/\(self.maxOpenDocuments)")
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
        log.info("[DocManager] closeDocument: \(document.url.lastPathComponent)")
        documents.removeAll { $0.id == document.id }
        
        // Update selection
        if selectedDocumentID == document.id {
            selectedDocumentID = documents.first?.id
        }
        
        // Update comparison if needed
        updateComparisonAfterClosing(document)
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
    }
    
    // MARK: - Window Management
    func openInNewWindow(_ document: PDFDocumentItem) {
        NSWorkspace.shared.open(document.url)
    }

    // MARK: - Session Persistence

    /// Save bookmarks for all currently open tabs so they can be restored on next launch.
    func saveOpenSession() {
        let bookmarks: [Data] = documents.compactMap { item in
            try? item.url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: AppConstants.openSessionBookmarksKey)
        }
        log.info("[DocManager] saveOpenSession: saved \(bookmarks.count) tab(s)")
    }

    /// Restore tabs from the previous session's bookmarks.
    /// Uses security-scoped access directly instead of `openDocument` because
    /// `FileManager.isReadableFile` returns false for bookmark-resolved URLs in a sandboxed app.
    func restoreOpenSession() {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.openSessionBookmarksKey),
              let bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            return
        }

        var restoredCount = 0
        for bookmark in bookmarks {
            guard canAddDocument else { break }

            var isStale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) else {
                continue
            }

            // Start security-scoped access — do NOT stop it, the document needs
            // continued access for rendering. Access is released on app termination.
            _ = url.startAccessingSecurityScopedResource()

            guard !documents.contains(where: { $0.url == url }) else { continue }
            guard let document = PDFKit.PDFDocument(url: url) else {
                url.stopAccessingSecurityScopedResource()
                log.warning("[DocManager] restoreOpenSession: failed to open \(url.lastPathComponent)")
                continue
            }

            let pdfDoc = PDFDocumentItem(url: url, document: document, projectID: nil)
            documents.append(pdfDoc)
            selectedDocumentID = pdfDoc.id
            recentFilesManager?.addRecentFile(url)
            restoredCount += 1
        }
        log.info("[DocManager] restoreOpenSession: restored \(restoredCount)/\(bookmarks.count) tab(s)")
    }
}
