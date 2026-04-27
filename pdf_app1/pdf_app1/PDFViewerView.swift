//
//  PDFViewerView.swift
//  PDFViewer
//
//  PDF viewing component with annotation support
//
//  This view handles:
//  - PDF document display using PDFKit
//  - Annotation tools (highlight, text)
//  - Navigation controls (page, zoom)
//  - Search functionality
//  - Undo/redo operations
//  - Print and save operations
//

import SwiftUI
import PDFKit
import AppKit
import Combine
import UniformTypeIdentifiers

final class BookmarkManager: ObservableObject {
    @Published private(set) var bookmarks: [Int] = []

    private var documentID: String?
    private let keyPrefix = "PDFBookmarks:"

    func setDocumentID(_ id: String?) {
        documentID = id
        load()
    }

    func isBookmarked(_ pageIndex: Int) -> Bool {
        bookmarks.contains(pageIndex)
    }

    func toggle(_ pageIndex: Int) {
        if let idx = bookmarks.firstIndex(of: pageIndex) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(pageIndex)
        }
        bookmarks.sort()
        save()
    }

    func clear() {
        bookmarks.removeAll()
        save()
    }

    private func storageKey() -> String? {
        guard let documentID else { return nil }
        return keyPrefix + documentID
    }

    private func load() {
        guard let key = storageKey(),
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Int].self, from: data) else {
            bookmarks = []
            return
        }
        bookmarks = decoded.sorted()
    }

    private func save() {
        guard let key = storageKey() else { return }
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

 final class HighlightingPDFView: PDFView {
     var onMouseUp: (() -> Void)?
     var menuProvider: ((NSEvent) -> NSMenu?)?
     private var pageCache: [Int: NSImage] = [:]
     private let maxCacheSize = 10
     private var pageChangeDebounceTimer: Timer?

     override func viewDidMoveToWindow() {
         super.viewDidMoveToWindow()
         if window != nil {
             setupPerformanceOptimizations()
         }
     }
     
     private func setupPerformanceOptimizations() {
         self.displayMode = .singlePageContinuous
         self.displayDirection = .vertical
         self.autoScales = true
         self.layer?.drawsAsynchronously = true
         
         NotificationCenter.default.addObserver(
             self,
             selector: #selector(pageChanged),
             name: NSView.boundsDidChangeNotification,
             object: self.enclosingScrollView?.contentView
         )
     }
     
     @objc private func pageChanged() {
         pageChangeDebounceTimer?.invalidate()
         pageChangeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
             guard let self,
                   let currentPage = self.currentPage,
                   let document = self.document else { return }
             let currentIndex = document.index(for: currentPage)
             self.preloadPages(around: currentIndex, in: document)
         }
     }
     
     private func preloadPages(around currentIndex: Int, in document: PDFDocument) {
         // All PDFKit and pageCache access must happen on the main thread
         let preloadRange = max(0, currentIndex - 1)...min(document.pageCount - 1, currentIndex + 1)

         for pageIndex in preloadRange {
             if pageCache[pageIndex] == nil {
                 cachePageThumbnail(at: pageIndex, in: document)
             }
         }
     }

     private func cachePageThumbnail(at index: Int, in document: PDFDocument) {
         guard let page = document.page(at: index) else { return }

         let pageRect = page.bounds(for: .mediaBox)
         let scale: CGFloat = 0.2
         let imageSize = NSSize(width: pageRect.width * scale, height: pageRect.height * scale)

         guard let rep = NSBitmapImageRep(
             bitmapDataPlanes: nil,
             pixelsWide: Int(imageSize.width),
             pixelsHigh: Int(imageSize.height),
             bitsPerSample: 8,
             samplesPerPixel: 4,
             hasAlpha: true,
             isPlanar: false,
             colorSpaceName: .deviceRGB,
             bytesPerRow: 0,
             bitsPerPixel: 0
         ) else { return }

         let ctx = NSGraphicsContext(bitmapImageRep: rep)
         NSGraphicsContext.saveGraphicsState()
         NSGraphicsContext.current = ctx
         ctx?.cgContext.scaleBy(x: scale, y: scale)
         page.draw(with: .mediaBox, to: ctx!.cgContext)
         NSGraphicsContext.restoreGraphicsState()

         let image = NSImage(size: imageSize)
         image.addRepresentation(rep)

         pageCache[index] = image

         if pageCache.count > maxCacheSize {
             let sortedKeys = pageCache.keys.sorted()
             let middleIndex = sortedKeys.count / 2
             let keysToRemove = sortedKeys.filter { abs($0 - index) > middleIndex }
             keysToRemove.forEach { pageCache.removeValue(forKey: $0) }
         }
     }

     override func keyDown(with event: NSEvent) {
         switch event.keyCode {
         case 116: // Page Up
             goToPreviousPage(nil)
         case 121: // Page Down
             goToNextPage(nil)
         default:
             super.keyDown(with: event)
         }
     }

     override func mouseUp(with event: NSEvent) {
         super.mouseUp(with: event)
         onMouseUp?()
     }

     override func menu(for event: NSEvent) -> NSMenu? {
         if let menu = menuProvider?(event) {
             return menu
         }
         return super.menu(for: event)
     }
     
     deinit {
         NotificationCenter.default.removeObserver(self)
     }
 }

struct PDFViewerView: View {
    let pdfDocument: PDFDocument
    let pdfURL: URL?
    @Binding var annotationMode: AnnotationMode
    @Binding var highlightColor: Color
    let notificationManager: NotificationManager
    @EnvironmentObject var alertManager: AlertManager

    @StateObject private var undoRedoManager = UndoRedoManager()
    @StateObject private var searchManager = PDFSearchManager()
    @StateObject private var bookmarkManager = BookmarkManager()
    @State private var pdfView = HighlightingPDFView()
    @State private var currentPage: PDFPage?
    @State private var isSaving = false
    @State private var toolbarIsCompact = false
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var showingSearch = false
    @State private var isFullscreen = false
    @State private var sidebarPanel: SidebarPanel?
    @State private var hideToolbarInFullscreen = false
    @State private var pageNumberText: String = ""
    @State private var zoomText: String = "100%"
    @State private var pdfDisplayMode: PDFDisplayMode = .singlePageContinuous
    @State private var readingMode: ReadingMode = .normal

    private var currentPageIndex: Int {
        if let page = currentPage {
            let idx = pdfDocument.index(for: page)
            // Clamp to valid range; NSNotFound can be Int.max
            if idx < 0 || idx >= pdfDocument.pageCount {
                return 0
            }
            return idx
        }
        return 0
    }

    @State private var inkStrokeWidth: CGFloat = 2.0

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 2)
    }

    // MARK: - Compact Toolbar (categorized burger menus)

    private var compactToolbarMenus: some View {
        HStack(spacing: 2) {
            // View menu
            Menu {
                Section("Display Mode") {
                    Button("Single Page") { setDisplayMode(.singlePage) }
                    Button("Continuous") { setDisplayMode(.singlePageContinuous) }
                    Button("Two Pages") { setDisplayMode(.twoUp) }
                    Button("Two Pages Continuous") { setDisplayMode(.twoUpContinuous) }
                }
                Section("Rotation") {
                    Button("Rotate Left") { rotatePageCCW() }
                    Button("Rotate Right") { rotatePageCW() }
                }
                Section("Reading Mode") {
                    Button("Normal") { setReadingMode(.normal) }
                    Button("Sepia") { setReadingMode(.sepia) }
                    Button("Dark") { setReadingMode(.dark) }
                }
                Section("Panels") {
                    Button("Thumbnails") { sidebarPanel = sidebarPanel == .thumbnails ? nil : .thumbnails }
                    Button("Table of Contents") { sidebarPanel = sidebarPanel == .outline ? nil : .outline }
                    Button("Annotations") { sidebarPanel = sidebarPanel == .annotations ? nil : .annotations }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("View")

            // Markup menu
            Menu {
                Section("Markup") {
                    Button("None") { annotationMode = .none }
                    Button("Highlight") { annotationMode = .highlightText }
                    Button("Underline") { annotationMode = .underline }
                    Button("Strikethrough") { annotationMode = .strikethrough }
                    Button("Area Highlight") { annotationMode = .highlightArea }
                }
                Section("Shapes") {
                    Button("Rectangle") { annotationMode = .rectangle }
                    Button("Circle") { annotationMode = .circle }
                    Button("Line") { annotationMode = .line }
                    Button("Arrow") { annotationMode = .arrow }
                }
                Section("Other") {
                    Button("Text") { annotationMode = .text }
                    Button("Sticky Note") { annotationMode = .stickyNote }
                    Button("Ink") { annotationMode = .ink }
                }
            } label: {
                Image(systemName: annotationModeLabel.icon)
            }
            .help("Markup")

            if annotationUsesColor {
                ColorPicker("", selection: $highlightColor)
                    .labelsHidden()
            }

            // Tools menu
            Menu {
                Button("Search") { showingSearch.toggle() }
                Button("Undo") { performUndo() }
                    .disabled(!undoRedoManager.canUndo)
                Button("Redo") { performRedo() }
                    .disabled(!undoRedoManager.canRedo)
                Divider()
                Button(bookmarkManager.isBookmarked(currentPageIndex) ? "Remove Bookmark" : "Add Bookmark") {
                    bookmarkManager.toggle(currentPageIndex)
                }
                if !bookmarkManager.bookmarks.isEmpty {
                    Divider()
                    ForEach(bookmarkManager.bookmarks, id: \.self) { index in
                        Button("Page \(index + 1)") { goToPage(index) }
                    }
                }
                Divider()
                Button("Fullscreen") { toggleFullscreen() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Tools")
        }
        .buttonStyle(.borderless)
        // Keep hidden keyboard shortcuts active
        .background(
            Group {
                Button("") { showingSearch.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            .frame(width: 0, height: 0).opacity(0)
        )
    }

    // MARK: - Expanded Toolbar (full controls)

    private var expandedToolbarControls: some View {
        HStack(spacing: 4) {
            // Display & Reading
            Menu {
                Section("Display Mode") {
                    Button("Single Page") { setDisplayMode(.singlePage) }
                    Button("Continuous") { setDisplayMode(.singlePageContinuous) }
                    Button("Two Pages") { setDisplayMode(.twoUp) }
                    Button("Two Pages Continuous") { setDisplayMode(.twoUpContinuous) }
                }
                Section("Rotation") {
                    Button("Rotate Left") { rotatePageCCW() }
                    Button("Rotate Right") { rotatePageCW() }
                }
                Section("Reading Mode") {
                    Button("Normal") { setReadingMode(.normal) }
                    Button("Sepia") { setReadingMode(.sepia) }
                    Button("Dark") { setReadingMode(.dark) }
                }
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Display & Reading")

            toolbarDivider

            // Search
            Button(action: { showingSearch.toggle() }) {
                Image(systemName: "magnifyingglass")
            }
            .help("Search (⌘F)")
            .keyboardShortcut("f", modifiers: .command)

            // Annotation
            Menu {
                Section("Markup") {
                    Button("None") { annotationMode = .none }
                    Button("Highlight") { annotationMode = .highlightText }
                    Button("Underline") { annotationMode = .underline }
                    Button("Strikethrough") { annotationMode = .strikethrough }
                    Button("Area Highlight") { annotationMode = .highlightArea }
                }
                Section("Shapes") {
                    Button("Rectangle") { annotationMode = .rectangle }
                    Button("Circle") { annotationMode = .circle }
                    Button("Line") { annotationMode = .line }
                    Button("Arrow") { annotationMode = .arrow }
                }
                Section("Other") {
                    Button("Text") { annotationMode = .text }
                    Button("Sticky Note") { annotationMode = .stickyNote }
                    Button("Ink") { annotationMode = .ink }
                }
            } label: {
                Label(annotationModeLabel.title, systemImage: annotationModeLabel.icon)
                    .labelStyle(.titleAndIcon)
            }
            .help("Annotation")
            .fixedSize()

            if annotationUsesColor {
                ColorPicker("", selection: $highlightColor)
                    .labelsHidden()
            }

            toolbarDivider

            // Panels
            HStack(spacing: 1) {
                Button(action: { sidebarPanel = sidebarPanel == .thumbnails ? nil : .thumbnails }) {
                    Image(systemName: "square.grid.2x2")
                }
                .help("Thumbnails")
                Button(action: { sidebarPanel = sidebarPanel == .outline ? nil : .outline }) {
                    Image(systemName: "list.bullet")
                }
                .help("Table of Contents")
                Button(action: { sidebarPanel = sidebarPanel == .annotations ? nil : .annotations }) {
                    Image(systemName: "note.text")
                }
                .help("Annotations")
            }

            // Undo / Redo
            HStack(spacing: 1) {
                Button(action: performUndo) { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!undoRedoManager.canUndo)
                Button(action: performRedo) { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⌘⇧Z)")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!undoRedoManager.canRedo)
            }

            toolbarDivider

            // Fullscreen + Bookmarks
            Button(action: toggleFullscreen) {
                Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .help("Fullscreen (⌘⌃F)")
            .keyboardShortcut("f", modifiers: [.command, .control])

            Menu {
                Button(bookmarkManager.isBookmarked(currentPageIndex) ? "Remove Bookmark" : "Add Bookmark") {
                    bookmarkManager.toggle(currentPageIndex)
                }
                .disabled(pdfDocument.pageCount == 0)
                if !bookmarkManager.bookmarks.isEmpty {
                    Divider()
                    ForEach(bookmarkManager.bookmarks, id: \.self) { index in
                        Button("Page \(index + 1)") { goToPage(index) }
                    }
                    Divider()
                    Button("Clear Bookmarks") { bookmarkManager.clear() }
                }
            } label: {
                Image(systemName: bookmarkManager.isBookmarked(currentPageIndex) ? "bookmark.fill" : "bookmark")
            }
            .help("Bookmarks")

            if isFullscreen {
                Button(action: { hideToolbarInFullscreen.toggle() }) {
                    Image(systemName: hideToolbarInFullscreen ? "pin.slash" : "pin")
                }
                .help("Pin Toolbar")
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - File Toolbar Actions (always visible)

    private var fileToolbarActions: some View {
        HStack(spacing: 2) {
            if let url = pdfURL {
                Button(action: { savePDF(to: url, showNotifications: true) }) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
                .disabled(isSaving)
                .help("Save (⌘S)")
                .keyboardShortcut("s", modifiers: .command)

                Menu {
                    Button("Save As...") { saveAs() }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("Print...") { printPDF() }
                        .keyboardShortcut("p", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("More")
            }
        }
        .buttonStyle(.borderless)
    }

    private var annotationModeLabel: (title: String, icon: String) {
        switch annotationMode {
        case .none: return ("None", "hand.point.up.left")
        case .highlightText: return ("Highlight", "highlighter")
        case .highlightArea: return ("Area", "rectangle.dashed")
        case .text: return ("Text", "text.bubble")
        case .underline: return ("Underline", "underline")
        case .strikethrough: return ("Strikethrough", "strikethrough")
        case .stickyNote: return ("Note", "note.text")
        case .ink: return ("Ink", "pencil.tip")
        case .rectangle: return ("Rectangle", "rectangle")
        case .circle: return ("Circle", "circle")
        case .line: return ("Line", "line.diagonal")
        case .arrow: return ("Arrow", "arrow.right")
        }
    }

    private var annotationUsesColor: Bool {
        switch annotationMode {
        case .none, .text, .stickyNote: return false
        default: return true
        }
    }

    @State private var showingTextAnnotationDialog = false
    @State private var textAnnotationContent = ""
    @State private var textAnnotationPoint: CGPoint = .zero
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            if !(isFullscreen && hideToolbarInFullscreen) {
                HStack(spacing: toolbarIsCompact ? 2 : 4) {
                        // ── Navigation (always visible) ──
                        HStack(spacing: 1) {
                            Button(action: goBack) { Image(systemName: "chevron.left") }
                                .help("Previous Page (⌘←)")
                                .disabled(!pdfView.canGoBack)
                                .keyboardShortcut(.leftArrow, modifiers: [.command])
                            Button(action: goForward) { Image(systemName: "chevron.right") }
                                .help("Next Page (⌘→)")
                                .disabled(!pdfView.canGoForward)
                                .keyboardShortcut(.rightArrow, modifiers: [.command])
                        }
                        .buttonStyle(.borderless)

                        // Hidden shortcuts for first/last page
                        Button("") { goToFirstPage() }
                            .keyboardShortcut(.upArrow, modifiers: [.command])
                            .frame(width: 0, height: 0).opacity(0)
                        Button("") { goToLastPage() }
                            .keyboardShortcut(.downArrow, modifiers: [.command])
                            .frame(width: 0, height: 0).opacity(0)

                        // Page indicator
                        Text("\(currentPageIndex + 1)/\(pdfDocument.pageCount)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()

                        if !toolbarIsCompact {
                            TextField("", text: $pageNumberText)
                                .frame(width: 36)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(goToPageFromField)
                                .help("Go to Page")
                        }

                        toolbarDivider

                        // ── Zoom (always visible, compact adjusts) ──
                        HStack(spacing: 1) {
                            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                                .help("Zoom Out")
                            if !toolbarIsCompact {
                                TextField("", text: $zoomText)
                                    .frame(width: 40)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(applyZoomFromField)
                            }
                            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                                .help("Zoom In")
                            Button(action: fitToPage) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                                .help("Fit to Page")
                        }
                        .buttonStyle(.borderless)

                        toolbarDivider

                        if toolbarIsCompact {
                            // ── COMPACT: everything else in categorized menus ──
                            compactToolbarMenus
                        } else {
                            // ── EXPANDED: individual controls ──
                            expandedToolbarControls
                        }

                        Spacer(minLength: 0)

                        // ── File actions (always visible) ──
                        fileToolbarActions
                    }
                .padding(.horizontal, 8)
                .frame(height: 36)
                .background(Color(NSColor.windowBackgroundColor))
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { toolbarIsCompact = geo.size.width < 580 }
                            .onChange(of: geo.size.width) { _, w in
                                let shouldBeCompact = w < 580
                                if toolbarIsCompact != shouldBeCompact {
                                    toolbarIsCompact = shouldBeCompact
                                }
                            }
                    }
                )
            } else {
                HStack {
                    Spacer()
                    Button(action: { hideToolbarInFullscreen = false }) {
                        Image(systemName: "chevron.down")
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .help("Show Toolbar")
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            
            Divider()
            
            // PDF View
            HStack(spacing: 0) {
                if let panel = sidebarPanel {
                    switch panel {
                    case .thumbnails:
                        PDFThumbnailViewRepresentable(pdfView: pdfView)
                            .frame(width: 140)
                    case .outline:
                        PDFOutlinePanel(pdfDocument: pdfDocument, pdfView: pdfView)
                            .frame(width: 220)
                    case .annotations:
                        AnnotationListPanel(
                            pdfDocument: pdfDocument,
                            pdfView: pdfView,
                            undoRedoManager: undoRedoManager,
                            onAnnotationsChanged: { scheduleAutoSave() }
                        )
                        .frame(width: 250)
                    case .projectCorrelations:
                        EmptyView() // Handled in MultiDocumentView
                    }
                    Divider()
                }

                ZStack {
                    PDFViewRepresentable(
                    pdfView: $pdfView,
                    pdfDocument: pdfDocument,
                    annotationMode: annotationMode,
                    highlightColor: highlightColor,
                    undoRedoManager: undoRedoManager,
                    onAnnotationsChanged: {
                        scheduleAutoSave()
                    },
                    onTextAnnotationRequest: { point in
                        textAnnotationPoint = point
                        showingTextAnnotationDialog = true
                    },
                    onPageChanged: { page in
                        if let page = page {
                            let idx = pdfDocument.index(for: page)
                            if idx >= 0 && idx < pdfDocument.pageCount {
                                currentPage = page
                            } else {
                                currentPage = nil
                            }
                        } else {
                            currentPage = nil
                        }
                    },
                    onAnnotationError: { errorMessage in
                        notificationManager.showError(errorMessage)
                    }
                )
                .onAppear {
                    setupPDFView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Reading mode overlay
                    if readingMode == .sepia {
                        Color(red: 0.94, green: 0.87, blue: 0.74)
                            .opacity(0.15)
                            .blendMode(.multiply)
                            .allowsHitTesting(false)
                    }
                } // ZStack
            }
        }
        .onAppear {
            searchManager.setDocument(pdfDocument)
            if let url = pdfURL {
                bookmarkManager.setDocumentID(url.absoluteString)
            } else {
                bookmarkManager.setDocumentID(nil)
            }
            pageNumberText = "\(currentPageIndex + 1)"
            syncZoomText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: pdfView)) { _ in
            syncZoomText()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToPage"))) { notification in
            if let pageIndex = notification.object as? Int {
                goToPage(pageIndex)
                guard let document = pdfView.document,
                      pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex) else { return }

                let userInfo = notification.userInfo
                let boundingBox = userInfo?["boundingBox"] as? CGRect
                let textSnippet = userInfo?["textSnippet"] as? String

                let bridge = HighlightSyncBridge()
                let passageRects: [CGRect]
                if let snippet = textSnippet,
                   let found = bridge.findPassageRects(snippet: snippet, on: page) {
                    passageRects = found
                } else if let bb = boundingBox {
                    passageRects = [bb]
                } else {
                    return
                }

                var annotations: [PDFAnnotation] = []
                for rect in passageRects {
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = NSColor.systemYellow.withAlphaComponent(0.4)
                    page.addAnnotation(annotation)
                    annotations.append(annotation)
                }

                let scrollTarget = passageRects.first ?? passageRects[0]
                let destination = PDFDestination(page: page, at: CGPoint(x: scrollTarget.midX, y: scrollTarget.midY))
                pdfView.go(to: destination)

                DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.sourcePulseDuration) {
                    for annotation in annotations {
                        page.removeAnnotation(annotation)
                    }
                    pdfView.setNeedsDisplay(pdfView.bounds)
                }
            }
        }
        .sheet(isPresented: $showingTextAnnotationDialog) {
            TextAnnotationDialog(
                content: $textAnnotationContent,
                isPresented: $showingTextAnnotationDialog,
                onSave: {
                    addTextAnnotation(at: textAnnotationPoint, text: textAnnotationContent)
                    textAnnotationContent = ""
                }
            )
        }
        .overlay(alignment: .top) {
            if showingSearch {
                SearchBarView(
                    searchManager: searchManager,
                    pdfView: pdfView,
                    isPresented: $showingSearch
                )
                .padding()
                .zIndex(1000)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    private func toggleFullscreen() {
        if let window = NSApplication.shared.windows.first {
            window.toggleFullScreen(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let fullscreenNow = window.styleMask.contains(.fullScreen)
                isFullscreen = fullscreenNow
                UserDefaults.standard.set(fullscreenNow, forKey: AppConstants.windowStateKey)
                if !fullscreenNow {
                    hideToolbarInFullscreen = false
                }
            }
        }
    }

    private func goToPageFromField() {
        let trimmed = pageNumberText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let desired = Int(trimmed) else {
            pageNumberText = "\(currentPageIndex + 1)"
            return
        }
        goToPage(desired - 1)
    }

    private func goToPage(_ index: Int) {
        let clamped = max(0, min(index, pdfDocument.pageCount - 1))
        guard let page = pdfDocument.page(at: clamped) else { return }
        pdfView.go(to: page)
        currentPage = page
        pageNumberText = "\(clamped + 1)"
    }
    
    private func setupPDFView() {
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        // Defer scaling to allow layout to settle, then fit entire page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.fitEntirePage()
        }
    }

    private func fitEntirePage() {
        guard let page = pdfView.document?.page(at: 0) else {
            pdfView.autoScales = true
            return
        }
        let pageRect = page.bounds(for: .mediaBox)
        let viewSize = pdfView.bounds.size
        guard pageRect.width > 0, pageRect.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            pdfView.autoScales = true
            return
        }
        let scaleX = (viewSize.width - 20) / pageRect.width
        let scaleY = (viewSize.height - 20) / pageRect.height
        pdfView.scaleFactor = min(scaleX, scaleY)
    }
    
    
    private func goBack() {
        pdfView.goToPreviousPage(nil)
    }
    
    private func goForward() {
        pdfView.goToNextPage(nil)
    }

    private func goToFirstPage() {
        pdfView.goToFirstPage(nil)
        currentPage = pdfView.currentPage
        pageNumberText = "\(currentPageIndex + 1)"
    }

    private func goToLastPage() {
        pdfView.goToLastPage(nil)
        currentPage = pdfView.currentPage
        pageNumberText = "\(currentPageIndex + 1)"
    }
    
    private func zoomIn() {
        pdfView.scaleFactor *= AppConstants.zoomMultiplier
    }
    
    private func zoomOut() {
        pdfView.scaleFactor /= AppConstants.zoomMultiplier
    }
    
    private func fitToPage() {
        fitEntirePage()
    }

    private func fitToWidth() {
        guard let page = pdfView.currentPage else { return }
        let pageWidth = page.bounds(for: .mediaBox).width
        let viewWidth = pdfView.bounds.width - 20
        guard pageWidth > 0 else { return }
        pdfView.scaleFactor = viewWidth / pageWidth
    }

    private func syncZoomText() {
        let pct = Int(pdfView.scaleFactor * 100)
        zoomText = "\(pct)%"
    }

    private func applyZoomFromField() {
        let cleaned = zoomText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned) else {
            syncZoomText()
            return
        }
        let clamped = max(25, min(500, value))
        pdfView.scaleFactor = clamped / 100.0
        syncZoomText()
    }

    private func setDisplayMode(_ mode: PDFDisplayMode) {
        pdfDisplayMode = mode
        pdfView.displayMode = mode
        pdfView.displaysAsBook = (mode == .twoUp || mode == .twoUpContinuous)
    }

    private func rotatePageCW() {
        guard let page = pdfView.currentPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation + 90) % 360
        page.rotation = newRotation
        undoRedoManager.addOperation(.rotatePage(page: page, oldRotation: oldRotation, newRotation: newRotation))
        scheduleAutoSave()
    }

    private func rotatePageCCW() {
        guard let page = pdfView.currentPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation + 270) % 360
        page.rotation = newRotation
        undoRedoManager.addOperation(.rotatePage(page: page, oldRotation: oldRotation, newRotation: newRotation))
        scheduleAutoSave()
    }

    private func setReadingMode(_ mode: ReadingMode) {
        readingMode = mode
        // Dark mode uses layer filter
        if mode == .dark {
            pdfView.wantsLayer = true
            if let filter = CIFilter(name: "CIColorInvert") {
                pdfView.layer?.filters = [filter]
            }
        } else {
            pdfView.layer?.filters = nil
        }
    }

    private func savePDF(to url: URL, showNotifications: Bool) {
        guard !isSaving else { return }
        
        // Validate file is writable
        guard FileManager.default.isWritableFile(atPath: url.path) || FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            if showNotifications {
                notificationManager.showError("Cannot save: File is read-only or location is not writable")
            }
            return
        }
        
        isSaving = true
        
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            isSaving = false
            if showNotifications {
                notificationManager.showError("Cannot save: Security access denied")
            }
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        // Perform save on background queue
        DispatchQueue.global(qos: .userInitiated).async {
            let success = self.pdfDocument.write(to: url)
            
            DispatchQueue.main.async {
                self.isSaving = false
                if success {
                    if showNotifications {
                        self.notificationManager.showSuccess("PDF saved successfully")
                    }
                } else {
                    if showNotifications {
                        self.notificationManager.showError("Failed to save PDF. Please try again.")
                    }
                }
            }
        }
    }

    private func scheduleAutoSave() {
        guard let url = pdfURL else { return }
        autoSaveWorkItem?.cancel()

        let item = DispatchWorkItem {
            savePDF(to: url, showNotifications: false)
        }
        autoSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }
    
    private func addTextAnnotation(at point: CGPoint, text: String) {
        guard let page = pdfView.currentPage else {
            notificationManager.showError("Cannot add annotation: No page selected")
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notificationManager.showError("Cannot add empty annotation")
            return
        }

        let pagePoint = pdfView.convert(point, to: page)
        let pageBounds = page.bounds(for: .mediaBox)
        guard pagePoint.x.isFinite, pagePoint.y.isFinite,
              pageBounds.contains(pagePoint) else {
            notificationManager.showError("Cannot add annotation: Position out of bounds")
            return
        }

        let annotation: PDFAnnotation
        let label: String

        if annotationMode == .stickyNote {
            // Sticky note — small icon, PDFKit renders the popup
            let bounds = CGRect(x: pagePoint.x, y: pagePoint.y - 12, width: 24, height: 24)
            annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.contents = text
            annotation.color = .yellow
            label = "Sticky note added"
        } else {
            // Free text annotation
            let bounds = CGRect(
                x: pagePoint.x,
                y: pagePoint.y - AppConstants.textAnnotationVerticalOffset,
                width: AppConstants.textAnnotationWidth,
                height: AppConstants.textAnnotationHeight
            )
            guard bounds.minX >= 0, bounds.minY >= 0,
                  bounds.maxX <= pageBounds.width, bounds.maxY <= pageBounds.height else {
                notificationManager.showError("Cannot add annotation: Annotation bounds out of page bounds")
                return
            }
            annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: AppConstants.annotationFontSize)
            annotation.fontColor = .black
            annotation.backgroundColor = .yellow.withAlphaComponent(AppConstants.annotationAlpha)
            label = "Text annotation added"
        }

        page.addAnnotation(annotation)
        undoRedoManager.addOperation(.add(annotation: annotation, page: page))
        notificationManager.showSuccess(label)
        scheduleAutoSave()
    }
    
    private func performUndo() {
        guard let operation = undoRedoManager.undo() else { return }
        undoRedoManager.executeUndo(operation)
        notificationManager.showInfo("Undone")
        scheduleAutoSave()
    }
    
    private func performRedo() {
        guard let operation = undoRedoManager.redo() else { return }
        undoRedoManager.executeRedo(operation)
        notificationManager.showInfo("Redone")
        scheduleAutoSave()
    }
    
    /// Print the PDF document
    private func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save PDF As"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfURL?.lastPathComponent ?? "Document.pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let success = pdfDocument.write(to: url)
            if success {
                notificationManager.showSuccess("Saved to \(url.lastPathComponent)")
            } else {
                notificationManager.showError("Failed to save PDF")
            }
        }
    }

    private func printPDF() {
        guard let window = NSApplication.shared.windows.first else { return }
        
        let printInfo = NSPrintInfo.shared
        printInfo.isVerticallyCentered = false
        printInfo.isHorizontallyCentered = true
        
        guard let printOperation = pdfDocument.printOperation(
            for: printInfo,
            scalingMode: .pageScaleDownToFit,
            autoRotate: true
        ) else {
            return
        }
        
        printOperation.canSpawnSeparateThread = true
        printOperation.jobTitle = pdfURL?.lastPathComponent ?? "PDF Document"
        
        printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    @Binding var pdfView: HighlightingPDFView
    let pdfDocument: PDFDocument
    let annotationMode: AnnotationMode
    let highlightColor: Color
    let undoRedoManager: UndoRedoManager
    let onAnnotationsChanged: () -> Void
    let onTextAnnotationRequest: (CGPoint) -> Void
    let onPageChanged: (PDFPage?) -> Void
    let onAnnotationError: ((String) -> Void)?
    
    init(
        pdfView: Binding<HighlightingPDFView>,
        pdfDocument: PDFDocument,
        annotationMode: AnnotationMode,
        highlightColor: Color,
        undoRedoManager: UndoRedoManager,
        onAnnotationsChanged: @escaping () -> Void,
        onTextAnnotationRequest: @escaping (CGPoint) -> Void,
        onPageChanged: @escaping (PDFPage?) -> Void,
        onAnnotationError: ((String) -> Void)? = nil
    ) {
        self._pdfView = pdfView
        self.pdfDocument = pdfDocument
        self.annotationMode = annotationMode
        self.highlightColor = highlightColor
        self.undoRedoManager = undoRedoManager
        self.onAnnotationsChanged = onAnnotationsChanged
        self.onTextAnnotationRequest = onTextAnnotationRequest
        self.onPageChanged = onPageChanged
        self.onAnnotationError = onAnnotationError
    }
    
    func makeNSView(context: Context) -> PDFView {
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageBreakMargins = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        pdfView.backgroundColor = NSColor.controlBackgroundColor

        // Fit entire page on initial load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let page = pdfView.document?.page(at: 0) else {
                pdfView.autoScales = true
                return
            }
            let pageRect = page.bounds(for: .mediaBox)
            let viewSize = pdfView.bounds.size
            guard pageRect.width > 0, pageRect.height > 0,
                  viewSize.width > 40, viewSize.height > 40 else {
                pdfView.autoScales = true
                return
            }
            let scaleX = (viewSize.width - 20) / pageRect.width
            let scaleY = (viewSize.height - 20) / pageRect.height
            pdfView.scaleFactor = min(scaleX, scaleY)
        }

         pdfView.onMouseUp = { [weak coordinator = context.coordinator] in
             coordinator?.handleSelectionCompleted()
         }

         pdfView.menuProvider = { [weak coordinator = context.coordinator] event in
             coordinator?.contextMenu(for: event)
         }
        
        context.coordinator.clickGesture.numberOfClicksRequired = 1
        context.coordinator.panGesture.delegate = context.coordinator
        
        pdfView.addGestureRecognizer(context.coordinator.clickGesture)
        pdfView.addGestureRecognizer(context.coordinator.panGesture)
        
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handlePageChange(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
        
        context.coordinator.clickGesture.isEnabled = [.text, .stickyNote].contains(annotationMode)
        context.coordinator.panGesture.isEnabled = [.highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)
        
        return pdfView
    }
    
    func updateNSView(_ nsView: PDFView, context: Context) {
        // Update document if changed
        if nsView.document != pdfDocument {
            nsView.document = pdfDocument
        }

        let previousMode = context.coordinator.annotationMode

        // Update coordinator state
        context.coordinator.annotationMode = annotationMode
        context.coordinator.highlightColor = highlightColor
        context.coordinator.onAnnotationError = onAnnotationError
        context.coordinator.undoRedoManager = undoRedoManager

        if previousMode != annotationMode {
            // Update gesture recognizer state only when mode changes
            context.coordinator.clickGesture.isEnabled = [.text, .stickyNote].contains(annotationMode)
            context.coordinator.panGesture.isEnabled = [.highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)

            // Clear selection when leaving text-selection modes
            if ![AnnotationMode.highlightText, .underline, .strikethrough].contains(annotationMode) {
                nsView.clearSelection()
            }

            // Update cursor based on annotation mode
            DispatchQueue.main.async {
                switch annotationMode {
                case .none:
                    NSCursor.arrow.set()
                case .highlightText, .underline, .strikethrough:
                    NSCursor.iBeam.set()
                case .highlightArea, .text, .stickyNote, .ink, .rectangle, .circle, .line, .arrow:
                    NSCursor.crosshair.set()
                }
            }
        }
    }

    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            pdfView: pdfView,
            annotationMode: annotationMode,
            highlightColor: highlightColor,
            undoRedoManager: undoRedoManager,
            onAnnotationsChanged: onAnnotationsChanged,
            onTextAnnotationRequest: onTextAnnotationRequest,
            onPageChanged: onPageChanged,
            onAnnotationError: onAnnotationError
        )
    }
    
    class Coordinator: NSObject, NSGestureRecognizerDelegate {
        let pdfView: HighlightingPDFView
        var annotationMode: AnnotationMode
        var highlightColor: Color
        var undoRedoManager: UndoRedoManager
        let onAnnotationsChanged: () -> Void
        let onTextAnnotationRequest: (CGPoint) -> Void
        let onPageChanged: (PDFPage?) -> Void
        var onAnnotationError: ((String) -> Void)?
        var highlightStartPoint: CGPoint?
        var currentHighlight: PDFAnnotation?
        private var hitAnnotation: PDFAnnotation?
        private var hitAnnotationPage: PDFPage?
        
        let clickGesture: NSClickGestureRecognizer
        let panGesture: NSPanGestureRecognizer
        
        init(
            pdfView: HighlightingPDFView,
            annotationMode: AnnotationMode,
            highlightColor: Color,
            undoRedoManager: UndoRedoManager,
            onAnnotationsChanged: @escaping () -> Void,
            onTextAnnotationRequest: @escaping (CGPoint) -> Void,
            onPageChanged: @escaping (PDFPage?) -> Void,
            onAnnotationError: ((String) -> Void)? = nil
        ) {
            self.pdfView = pdfView
            self.annotationMode = annotationMode
            self.highlightColor = highlightColor
            self.undoRedoManager = undoRedoManager
            self.onAnnotationsChanged = onAnnotationsChanged
            self.onTextAnnotationRequest = onTextAnnotationRequest
            self.onPageChanged = onPageChanged
            self.onAnnotationError = onAnnotationError
            
            self.clickGesture = NSClickGestureRecognizer(target: nil, action: nil)
            self.panGesture = NSPanGestureRecognizer(target: nil, action: nil)
            
            super.init()
            
            self.clickGesture.target = self
            self.clickGesture.action = #selector(handleClick(_:))
            
            self.panGesture.target = self
            self.panGesture.action = #selector(handlePan(_:))
            self.panGesture.buttonMask = 0x1
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: pdfView)
            pdfView.onMouseUp = nil
            pdfView.menuProvider = nil
            pdfView.removeGestureRecognizer(clickGesture)
            pdfView.removeGestureRecognizer(panGesture)
        }

        func contextMenu(for event: NSEvent) -> NSMenu? {
            let locationInWindow = event.locationInWindow
            let locationInView = pdfView.convert(locationInWindow, from: nil)

            guard let page = pdfView.page(for: locationInView, nearest: true) else {
                hitAnnotation = nil
                hitAnnotationPage = nil
                return nil
            }
            let pagePoint = pdfView.convert(locationInView, to: page)
            guard let annotation = page.annotation(at: pagePoint) else {
                hitAnnotation = nil
                hitAnnotationPage = nil
                return nil
            }

            hitAnnotation = annotation
            hitAnnotationPage = page

            let menu = NSMenu()

            if annotation.type == "FreeText" {
                let editItem = NSMenuItem(title: "Edit Text…", action: #selector(editHitFreeTextAnnotation(_:)), keyEquivalent: "")
                editItem.target = self
                menu.addItem(editItem)
            }

            if annotation.type == "Highlight" {
                let recolorItem = NSMenuItem(title: "Apply Current Highlight Color", action: #selector(applyCurrentHighlightColor(_:)), keyEquivalent: "")
                recolorItem.target = self
                menu.addItem(recolorItem)
            }

            if menu.items.count > 0 {
                menu.addItem(.separator())
            }

            let deleteItem = NSMenuItem(title: "Delete Annotation", action: #selector(deleteHitAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            menu.addItem(deleteItem)
            return menu
        }

        @objc private func editHitFreeTextAnnotation(_ sender: Any?) {
            guard let annotation = hitAnnotation, let page = hitAnnotationPage else { return }
            guard annotation.type == "FreeText" else { return }

            let oldContents = annotation.contents

            let alert = NSAlert()
            alert.messageText = "Edit Annotation"
            alert.informativeText = "Update the annotation text."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 22))
            field.stringValue = oldContents ?? ""
            alert.accessoryView = field

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }

            let newContents = field.stringValue
            
            DispatchQueue.main.async {
                annotation.contents = newContents
                self.undoRedoManager.addOperation(.modifyContents(annotation: annotation, oldContents: oldContents, newContents: newContents, page: page))
                self.onAnnotationsChanged()
            }
        }

        @objc private func applyCurrentHighlightColor(_ sender: Any?) {
            guard let annotation = hitAnnotation, let page = hitAnnotationPage else { return }
            guard annotation.type == "Highlight" else { return }

            let oldColor = annotation.color
            let newColor = NSColor(highlightColor).withAlphaComponent(AppConstants.annotationAlpha)
            
            DispatchQueue.main.async {
                annotation.color = newColor
                self.undoRedoManager.addOperation(.modifyColor(annotation: annotation, oldColor: oldColor, newColor: newColor, page: page))
                self.onAnnotationsChanged()
            }
        }

        @objc private func deleteHitAnnotation(_ sender: Any?) {
            guard let annotation = hitAnnotation, let page = hitAnnotationPage else { return }
            page.removeAnnotation(annotation)
            undoRedoManager.addOperation(.remove(annotation: annotation, page: page))
            hitAnnotation = nil
            hitAnnotationPage = nil
            onAnnotationsChanged()
        }
        
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard [.text, .stickyNote].contains(annotationMode) else { return }
            guard pdfView.document != nil else { return }

            let location = gesture.location(in: pdfView)

            if annotationMode == .stickyNote {
                // Create sticky note at click position
                guard let page = pdfView.page(for: location, nearest: true) else { return }
                let pagePoint = pdfView.convert(location, to: page)
                guard pagePoint.x.isFinite, pagePoint.y.isFinite else { return }

                let bounds = CGRect(x: pagePoint.x, y: pagePoint.y - 12, width: 24, height: 24)
                let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
                annotation.color = NSColor(highlightColor)

                // Show dialog for note content
                onTextAnnotationRequest(location)
                // The actual creation happens via onTextAnnotationRequest → addStickyNote path
                // Store mode info so the dialog handler knows to create a sticky note
                return
            }

            onTextAnnotationRequest(location)
        }

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard pdfView.document != nil else { return }

            let location = gesture.location(in: pdfView)

            if annotationMode == .ink {
                handleInkPan(gesture, location: location)
                return
            }

            // Shape and area highlight modes
            switch gesture.state {
            case .began:
                highlightStartPoint = location
            case .changed:
                if let startPoint = highlightStartPoint,
                   let page = pdfView.page(for: location, nearest: true) {

                    if let currentHighlight = currentHighlight {
                        page.removeAnnotation(currentHighlight)
                    }

                    let startPagePoint = pdfView.convert(startPoint, to: page)
                    let endPagePoint = pdfView.convert(location, to: page)

                    guard startPagePoint.x.isFinite, startPagePoint.y.isFinite,
                          endPagePoint.x.isFinite, endPagePoint.y.isFinite else {
                        return
                    }

                    let rect = CGRect(
                        x: min(startPagePoint.x, endPagePoint.x),
                        y: min(startPagePoint.y, endPagePoint.y),
                        width: abs(endPagePoint.x - startPagePoint.x),
                        height: abs(endPagePoint.y - startPagePoint.y)
                    )

                    guard rect.width.isFinite, rect.height.isFinite else { return }

                    if rect.width > AppConstants.minimumHighlightSize && rect.height > AppConstants.minimumHighlightSize {
                        let pageBounds = page.bounds(for: .mediaBox)
                        guard rect.intersects(pageBounds) else { return }

                        let annotationType: PDFAnnotationSubtype
                        switch annotationMode {
                        case .rectangle: annotationType = .square
                        case .circle: annotationType = .circle
                        case .line, .arrow: annotationType = .line
                        default: annotationType = .highlight
                        }

                        let annotation = PDFAnnotation(bounds: rect, forType: annotationType, withProperties: nil)
                        annotation.color = NSColor(highlightColor).withAlphaComponent(AppConstants.annotationAlpha)

                        if annotationType == .square || annotationType == .circle {
                            let border = PDFBorder()
                            border.lineWidth = 2.0
                            annotation.border = border
                        }

                        if annotationMode == .line || annotationMode == .arrow {
                            annotation.setValue([startPagePoint, endPagePoint], forAnnotationKey: .linePoints)
                            if annotationMode == .arrow {
                                annotation.setValue([PDFLineStyle.none.rawValue, PDFLineStyle.openArrow.rawValue], forAnnotationKey: .lineEndingStyles)
                            }
                        }

                        page.addAnnotation(annotation)
                        currentHighlight = annotation
                    }
                }
            case .ended:
                if let page = pdfView.page(for: location, nearest: true),
                   let highlight = currentHighlight {
                    undoRedoManager.addOperation(.add(annotation: highlight, page: page))
                    onAnnotationsChanged()
                }
                currentHighlight = nil
                highlightStartPoint = nil
            default:
                break
            }
        }

        // MARK: - Ink Drawing
        private var inkPath: NSBezierPath?
        private var inkPage: PDFPage?
        private var inkPoints: [CGPoint] = []

        private func handleInkPan(_ gesture: NSPanGestureRecognizer, location: CGPoint) {
            switch gesture.state {
            case .began:
                guard let page = pdfView.page(for: location, nearest: true) else { return }
                inkPage = page
                let pagePoint = pdfView.convert(location, to: page)
                guard pagePoint.x.isFinite, pagePoint.y.isFinite else { return }
                inkPath = NSBezierPath()
                inkPath?.move(to: pagePoint)
                inkPoints = [pagePoint]

            case .changed:
                guard let page = inkPage, let path = inkPath else { return }
                let pagePoint = pdfView.convert(location, to: page)
                guard pagePoint.x.isFinite, pagePoint.y.isFinite else { return }
                path.line(to: pagePoint)
                inkPoints.append(pagePoint)

            case .ended:
                guard let page = inkPage, let path = inkPath, inkPoints.count >= 2 else {
                    inkPath = nil
                    inkPage = nil
                    inkPoints = []
                    return
                }

                // Compute bounding box
                var minX = CGFloat.infinity, minY = CGFloat.infinity
                var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
                for pt in inkPoints {
                    minX = min(minX, pt.x)
                    minY = min(minY, pt.y)
                    maxX = max(maxX, pt.x)
                    maxY = max(maxY, pt.y)
                }
                let padding: CGFloat = 5
                let bounds = CGRect(x: minX - padding, y: minY - padding,
                                    width: maxX - minX + padding * 2, height: maxY - minY + padding * 2)

                let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                annotation.color = NSColor(highlightColor)
                let border = PDFBorder()
                border.lineWidth = 2.0
                annotation.border = border
                annotation.add(path)
                page.addAnnotation(annotation)
                undoRedoManager.addOperation(.add(annotation: annotation, page: page))
                onAnnotationsChanged()

                inkPath = nil
                inkPage = nil
                inkPoints = []

            default:
                break
            }
        }
        
        @objc func handlePageChange(_ notification: Notification) {
            onPageChanged(pdfView.currentPage)
        }

        func handleSelectionCompleted() {
            let annotationType: PDFAnnotationSubtype
            switch annotationMode {
            case .highlightText: annotationType = .highlight
            case .underline: annotationType = .underline
            case .strikethrough: annotationType = .strikeOut
            default: return
            }

            guard let selection = pdfView.currentSelection,
                  let selectedText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !selectedText.isEmpty else {
                return
            }

            let lineSelections = selection.selectionsByLine()
            let selectionsToUse: [PDFSelection] = lineSelections.isEmpty ? [selection] : lineSelections

            var addedAny = false
            for lineSelection in selectionsToUse {
                for page in lineSelection.pages {
                    let selectionBounds = lineSelection.bounds(for: page)
                    let pageBounds = page.bounds(for: .mediaBox)
                    guard selectionBounds.width.isFinite, selectionBounds.height.isFinite,
                          selectionBounds.width > 0, selectionBounds.height > 0,
                          selectionBounds.intersects(pageBounds) else {
                        continue
                    }

                    let annotation = PDFAnnotation(bounds: selectionBounds, forType: annotationType, withProperties: nil)
                    annotation.color = NSColor(highlightColor).withAlphaComponent(AppConstants.annotationAlpha)
                    page.addAnnotation(annotation)
                    undoRedoManager.addOperation(.add(annotation: annotation, page: page))
                    addedAny = true
                }
            }

            if addedAny {
                onAnnotationsChanged()
            }

            if !addedAny {
                onAnnotationError?("Cannot annotate: No selectable text found. Use Area highlight for scanned PDFs.")
            }

            pdfView.clearSelection()
        }
        
        private func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive event: NSEvent) -> Bool {
            guard gestureRecognizer === panGesture else { return true }
            guard let window = pdfView.window, let contentView = window.contentView else { return true }
            let locationInWindow = event.locationInWindow
            if let hitView = contentView.hitTest(locationInWindow) {
                // If the hit view is a scroller or inside a scroller, don't receive
                if hitView is NSScroller { return false }
                var v: NSView? = hitView
                while let current = v {
                    if current is NSScroller { return false }
                    v = current.superview
                }
            }
            return true
        }
    }
}

struct TextAnnotationDialog: View {
    @Binding var content: String
    @Binding var isPresented: Bool
    let onSave: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Text Annotation")
                .font(.headline)
            
            TextField("Enter text", text: $content, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .frame(width: 300)
            
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Add") {
                    onSave()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(content.isEmpty)
            }
        }
        .padding()
        .frame(width: 350, height: 200)
    }
}

struct PDFThumbnailViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 90, height: 120)
        thumbnailView.backgroundColor = NSColor.controlBackgroundColor
        return thumbnailView
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView {
            nsView.pdfView = pdfView
        }
    }
}

// MARK: - PDF Outline Panel (Table of Contents)
struct PDFOutlinePanel: View {
    let pdfDocument: PDFDocument
    let pdfView: PDFView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Table of Contents")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if let root = pdfDocument.outlineRoot, root.numberOfChildren > 0 {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<root.numberOfChildren, id: \.self) { i in
                            if let child = root.child(at: i) {
                                OutlineItemView(outline: child, pdfView: pdfView, depth: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } else {
                VStack {
                    Spacer()
                    Text("No table of contents")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct OutlineItemView: View {
    let outline: PDFOutline
    let pdfView: PDFView
    let depth: Int
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if outline.numberOfChildren > 0 {
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Spacer().frame(width: 14)
                }

                Button(action: {
                    if let destination = outline.destination {
                        pdfView.go(to: destination)
                    }
                }) {
                    Text(outline.label ?? "Untitled")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(0..<outline.numberOfChildren, id: \.self) { i in
                    if let child = outline.child(at: i) {
                        OutlineItemView(outline: child, pdfView: pdfView, depth: depth + 1)
                    }
                }
            }
        }
    }
}

// MARK: - Annotation List Panel
struct AnnotationListPanel: View {
    let pdfDocument: PDFDocument
    let pdfView: PDFView
    let undoRedoManager: UndoRedoManager
    let onAnnotationsChanged: () -> Void
    @State private var annotations: [(pageIndex: Int, annotation: PDFAnnotation)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
                Button(action: refreshAnnotations) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if annotations.isEmpty {
                VStack {
                    Spacer()
                    Text("No annotations")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(annotations.enumerated()), id: \.offset) { idx, item in
                            AnnotationRowView(
                                pageIndex: item.pageIndex,
                                annotation: item.annotation,
                                onNavigate: {
                                    if let page = pdfDocument.page(at: item.pageIndex) {
                                        pdfView.go(to: item.annotation.bounds, on: page)
                                    }
                                },
                                onDelete: {
                                    if let page = pdfDocument.page(at: item.pageIndex) {
                                        page.removeAnnotation(item.annotation)
                                        undoRedoManager.addOperation(.remove(annotation: item.annotation, page: page))
                                        onAnnotationsChanged()
                                        refreshAnnotations()
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .onAppear { refreshAnnotations() }
    }

    private func refreshAnnotations() {
        var result: [(pageIndex: Int, annotation: PDFAnnotation)] = []
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            for annotation in page.annotations {
                // Skip built-in widget annotations
                if annotation.type == "Widget" { continue }
                result.append((pageIndex: i, annotation: annotation))
            }
        }
        annotations = result
    }
}

struct AnnotationRowView: View {
    let pageIndex: Int
    let annotation: PDFAnnotation
    let onNavigate: () -> Void
    let onDelete: () -> Void

    private var typeIcon: String {
        switch annotation.type {
        case "Highlight": return "highlighter"
        case "Underline": return "underline"
        case "StrikeOut": return "strikethrough"
        case "FreeText": return "text.bubble"
        case "Text": return "note.text"
        case "Ink": return "pencil.tip"
        case "Square": return "rectangle"
        case "Circle": return "circle"
        case "Line": return "line.diagonal"
        default: return "pencil"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: typeIcon)
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(pageIndex + 1) — \(annotation.type ?? "Annotation")")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if let contents = annotation.contents, !contents.isEmpty {
                    Text(contents)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onNavigate() }
    }
}
