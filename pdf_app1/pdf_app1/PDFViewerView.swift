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

struct PDFViewerView: View {
    let pdfDocument: PDFDocument
    let pdfURL: URL?
    @Binding var annotationMode: AnnotationMode
    @Binding var highlightColor: Color
    let notificationManager: NotificationManager
    let toolbarBridge: PDFToolbarBridge
    @EnvironmentObject var alertManager: AlertManager

    @StateObject var undoRedoManager = UndoRedoManager()
    @StateObject var searchManager = PDFSearchManager()
    @StateObject var bookmarkManager = BookmarkManager()
    @State var pdfView = HighlightingPDFView()
    @State var currentPage: PDFPage?
    @State var isSaving = false
    @State var autoSaveDebouncer = Debouncer(delay: 1.0)
    @State var showingSearch = false
    @State var isFullscreen = false
    @State var sidebarPanel: SidebarPanel?
    @State var hideToolbarInFullscreen = false
    @State var pageNumberText: String = ""
    @State var zoomText: String = "100%"
    @State var pdfDisplayMode: PDFDisplayMode = .singlePageContinuous
    @State var readingMode: ReadingMode = .normal

    var currentPageIndex: Int {
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

    @State var inkStrokeWidth: CGFloat = 2.0

    @State var showingTextAnnotationDialog = false
    @State var textAnnotationContent = ""
    @State var textAnnotationPoint: CGPoint = .zero


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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            updateFullscreenState(from: notification, fullscreen: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            updateFullscreenState(from: notification, fullscreen: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPage)) { notification in
            if let pageIndex = notification.object as? Int {
                let userInfo = notification.userInfo
                // When a notification carries a sourceDocumentURL, only the
                // PDFViewerView whose document matches it should handle it —
                // otherwise clicking a map source-link routes to the wrong
                // tab's PDFView. Notifications from Command Palette / Chat
                // (no sourceDocumentURL) still hit the active tab as before.
                if let sourceURL = userInfo?["sourceDocumentURL"] as? URL,
                   sourceURL != pdfDocument.documentURL {
                    return
                }

                goToPage(pageIndex)
                guard let document = pdfView.document,
                      pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex) else { return }

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
}
