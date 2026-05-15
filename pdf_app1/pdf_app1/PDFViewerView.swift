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
 }

struct PDFViewerView: View {
    let pdfDocument: PDFDocument
    let pdfURL: URL?
    @Binding var annotationMode: AnnotationMode
    @Binding var highlightColor: Color
    let notificationManager: NotificationManager
    let toolbarBridge: PDFToolbarBridge
    @EnvironmentObject var alertManager: AlertManager

    @StateObject private var undoRedoManager = UndoRedoManager()
    @StateObject private var searchManager = PDFSearchManager()
    @StateObject private var bookmarkManager = BookmarkManager()
    @State private var pdfView = HighlightingPDFView()
    @State private var currentPage: PDFPage?
    @State private var isSaving = false
    @State private var autoSaveDebouncer = Debouncer(delay: 1.0)
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

    @State private var showingTextAnnotationDialog = false
    @State private var textAnnotationContent = ""
    @State private var textAnnotationPoint: CGPoint = .zero


    var body: some View {
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
                    EmptyView()
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
                    onAnnotationsChanged: { scheduleAutoSave() },
                    onTextAnnotationRequest: { point in
                        textAnnotationPoint = point
                        showingTextAnnotationDialog = true
                    },
                    onPageChanged: { page in
                        // PDFKit posts `PDFViewPageChanged` synchronously when
                        // `pdfView.document` is reassigned during `updateNSView`,
                        // so this closure can run mid-view-update. Defer the
                        // `@State` write to avoid "Modifying state during view update".
                        DispatchQueue.main.async {
                            if let page {
                                let idx = pdfDocument.index(for: page)
                                currentPage = (idx >= 0 && idx < pdfDocument.pageCount) ? page : nil
                            } else {
                                currentPage = nil
                            }
                        }
                    },
                    onAnnotationError: { errorMessage in
                        notificationManager.showError(errorMessage)
                    }
                )
                .onAppear { setupPDFView() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if readingMode == .sepia {
                    Color(red: 0.94, green: 0.87, blue: 0.74)
                        .opacity(0.15)
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(
            Group {
                Button("") { goToFirstPage() }
                    .keyboardShortcut(.upArrow, modifiers: [.command])
                Button("") { goToLastPage() }
                    .keyboardShortcut(.downArrow, modifiers: [.command])
            }
            .frame(width: 0, height: 0).opacity(0)
        )
        .onAppear {
            searchManager.setDocument(pdfDocument)
            if let url = pdfURL {
                bookmarkManager.setDocumentID(url.absoluteString)
            } else {
                bookmarkManager.setDocumentID(nil)
            }
            pageNumberText = "\(currentPageIndex + 1)"
            syncZoomText()
            wireToolbarBridge()
        }
        .onChange(of: currentPageIndex) { _, _ in refreshToolbarBridge() }
        .onChange(of: undoRedoManager.canUndo) { _, _ in refreshToolbarBridge() }
        .onChange(of: undoRedoManager.canRedo) { _, _ in refreshToolbarBridge() }
        .onChange(of: sidebarPanel) { _, new in toolbarBridge.sidebarPanel = new }
        .onChange(of: isFullscreen) { _, new in toolbarBridge.isFullscreen = new }
        .onChange(of: isSaving) { _, new in toolbarBridge.isSaving = new }
        .onChange(of: bookmarkManager.bookmarks) { _, _ in refreshToolbarBridge() }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: pdfView)) { _ in
            syncZoomText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPage)) { notification in
            if let pageIndex = notification.object as? Int {
                goToPage(pageIndex)
                guard let document = pdfView.document,
                      pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex) else { return }

                let userInfo = notification.userInfo
                let boundingBox = userInfo?["boundingBox"] as? CGRect
                let textSnippet = userInfo?["textSnippet"] as? String

                let passageRects: [CGRect]
                if let snippet = textSnippet,
                   let found = HighlightSyncBridge.findPassageRects(snippet: snippet, on: page) {
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
    
    private func refreshToolbarBridge() {
        toolbarBridge.currentPageIndex = currentPageIndex
        toolbarBridge.pageCount = pdfDocument.pageCount
        toolbarBridge.canGoBack = pdfView.canGoBack
        toolbarBridge.canGoForward = pdfView.canGoForward
        toolbarBridge.canUndo = undoRedoManager.canUndo
        toolbarBridge.canRedo = undoRedoManager.canRedo
        toolbarBridge.bookmarks = bookmarkManager.bookmarks
        toolbarBridge.currentPageBookmarked = bookmarkManager.isBookmarked(currentPageIndex)
        toolbarBridge.hasURL = pdfURL != nil
    }

    private func wireToolbarBridge() {
        refreshToolbarBridge()
        toolbarBridge.sidebarPanel = sidebarPanel
        toolbarBridge.isFullscreen = isFullscreen
        toolbarBridge.isSaving = isSaving

        toolbarBridge.onGoBack = { goBack() }
        toolbarBridge.onGoForward = { goForward() }
        toolbarBridge.onGoToFirstPage = { goToFirstPage() }
        toolbarBridge.onGoToLastPage = { goToLastPage() }
        toolbarBridge.onGoToPage = { goToPage($0) }
        toolbarBridge.onZoomIn = { zoomIn() }
        toolbarBridge.onZoomOut = { zoomOut() }
        toolbarBridge.onFitToPage = { fitToPage() }
        toolbarBridge.onSetDisplayMode = { setDisplayMode($0) }
        toolbarBridge.onRotateCW = { rotatePageCW() }
        toolbarBridge.onRotateCCW = { rotatePageCCW() }
        toolbarBridge.onSetReadingMode = { setReadingMode($0) }
        toolbarBridge.onToggleSearch = { showingSearch.toggle() }
        toolbarBridge.onTogglePanel = { panel in
            sidebarPanel = sidebarPanel == panel ? nil : panel
        }
        toolbarBridge.onUndo = { performUndo() }
        toolbarBridge.onRedo = { performRedo() }
        toolbarBridge.onToggleFullscreen = { toggleFullscreen() }
        toolbarBridge.onToggleBookmark = { bookmarkManager.toggle(currentPageIndex) }
        toolbarBridge.onClearBookmarks = { bookmarkManager.clear() }
        toolbarBridge.onSave = {
            if let url = pdfURL { savePDF(to: url, showNotifications: true) }
        }
        toolbarBridge.onSaveAs = { saveAs() }
        toolbarBridge.onPrint = { printPDF() }
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
        
        // Perform save on background queue. Scope is released inside the
        // completion path — a `defer` at function scope would fire on the
        // synchronous return below, before the background write actually
        // runs, revoking scope mid-write.
        DispatchQueue.global(qos: .userInitiated).async {
            let success = self.pdfDocument.write(to: url)

            DispatchQueue.main.async {
                url.stopAccessingSecurityScopedResource()
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
        autoSaveDebouncer.schedule {
            savePDF(to: url, showNotifications: false)
        }
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
