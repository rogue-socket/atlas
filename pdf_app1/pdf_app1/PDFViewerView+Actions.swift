//
//  PDFViewerView+Actions.swift
//  PDFViewer
//
//  Toolbar actions and PDFKit side effects for PDFViewerView.
//

import AppKit
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension PDFViewerView {
    func toggleFullscreen() {
        if let window = pdfView.window ?? NSApplication.shared.windows.first {
            window.toggleFullScreen(nil)
        }
    }

    func updateFullscreenState(from notification: Notification, fullscreen: Bool) {
        guard let window = notification.object as? NSWindow,
              let currentWindow = pdfView.window,
              window === currentWindow else {
            return
        }

        isFullscreen = fullscreen
        UserDefaults.standard.set(fullscreen, forKey: AppConstants.windowStateKey)
        if !fullscreen {
            hideToolbarInFullscreen = false
        }
    }

    func goToPageFromField() {
        let trimmed = pageNumberText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let desired = Int(trimmed) else {
            pageNumberText = "\(currentPageIndex + 1)"
            return
        }
        goToPage(desired - 1)
    }

    func goToPage(_ index: Int) {
        let clamped = max(0, min(index, pdfDocument.pageCount - 1))
        guard let page = pdfDocument.page(at: clamped) else { return }
        pdfView.go(to: page)
        currentPage = page
        pageNumberText = "\(clamped + 1)"
    }

    func refreshToolbarBridge() {
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

    func wireToolbarBridge() {
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

    func setupPDFView() {
        pdfView.document = pdfDocument
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        // Initial fit is owned by PDFViewRepresentable's frame-change observer,
        // which fires deterministically when AppKit lays out the view. Calling
        // here directly handles the re-appear path (tab switch back) where
        // bounds are already valid; if bounds aren't valid yet, fitEntirePage
        // falls back to autoScales and the representable's observer lands the
        // real fit shortly after.
        fitEntirePage()
    }

    func fitEntirePage() {
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

    func goBack() {
        pdfView.goToPreviousPage(nil)
    }

    func goForward() {
        pdfView.goToNextPage(nil)
    }

    func goToFirstPage() {
        pdfView.goToFirstPage(nil)
        currentPage = pdfView.currentPage
        pageNumberText = "\(currentPageIndex + 1)"
    }

    func goToLastPage() {
        pdfView.goToLastPage(nil)
        currentPage = pdfView.currentPage
        pageNumberText = "\(currentPageIndex + 1)"
    }

    func zoomIn() {
        pdfView.scaleFactor *= AppConstants.zoomMultiplier
    }

    func zoomOut() {
        pdfView.scaleFactor /= AppConstants.zoomMultiplier
    }

    func fitToPage() {
        fitEntirePage()
    }

    func fitToWidth() {
        guard let page = pdfView.currentPage else { return }
        let pageWidth = page.bounds(for: .mediaBox).width
        let viewWidth = pdfView.bounds.width - 20
        guard pageWidth > 0 else { return }
        pdfView.scaleFactor = viewWidth / pageWidth
    }

    func syncZoomText() {
        let pct = Int(pdfView.scaleFactor * 100)
        zoomText = "\(pct)%"
    }

    func applyZoomFromField() {
        let cleaned = zoomText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(cleaned) else {
            syncZoomText()
            return
        }
        let clamped = max(25, min(500, value))
        pdfView.scaleFactor = clamped / 100.0
        syncZoomText()
    }

    func setDisplayMode(_ mode: PDFDisplayMode) {
        pdfDisplayMode = mode
        pdfView.displayMode = mode
        pdfView.displaysAsBook = (mode == .twoUp || mode == .twoUpContinuous)
    }

    func rotatePageCW() {
        guard let page = pdfView.currentPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation + 90) % 360
        page.rotation = newRotation
        undoRedoManager.addOperation(.rotatePage(page: page, oldRotation: oldRotation, newRotation: newRotation))
        scheduleAutoSave()
    }

    func rotatePageCCW() {
        guard let page = pdfView.currentPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation + 270) % 360
        page.rotation = newRotation
        undoRedoManager.addOperation(.rotatePage(page: page, oldRotation: oldRotation, newRotation: newRotation))
        scheduleAutoSave()
    }

    func setReadingMode(_ mode: ReadingMode) {
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

    func savePDF(to url: URL, showNotifications: Bool) {
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
            let detachedAtlasAnnotations = HighlightSyncBridge.detachAtlasAnnotations(from: self.pdfDocument)
            let success = self.pdfDocument.write(to: url)
            HighlightSyncBridge.restoreAtlasAnnotations(detachedAtlasAnnotations)

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

    func scheduleAutoSave() {
        guard let url = pdfURL else { return }
        autoSaveDebouncer.schedule {
            savePDF(to: url, showNotifications: false)
        }
    }

    func addTextAnnotation(at point: CGPoint, text: String) {
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

    func performUndo() {
        guard let operation = undoRedoManager.undo() else { return }
        undoRedoManager.executeUndo(operation)
        notificationManager.showInfo("Undone")
        scheduleAutoSave()
    }

    func performRedo() {
        guard let operation = undoRedoManager.redo() else { return }
        undoRedoManager.executeRedo(operation)
        notificationManager.showInfo("Redone")
        scheduleAutoSave()
    }

    /// Print the PDF document
    func saveAs() {
        let panel = NSSavePanel()
        panel.title = "Save PDF As"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfURL?.lastPathComponent ?? "Document.pdf"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let detachedAtlasAnnotations = HighlightSyncBridge.detachAtlasAnnotations(from: pdfDocument)
            let success = pdfDocument.write(to: url)
            HighlightSyncBridge.restoreAtlasAnnotations(detachedAtlasAnnotations)
            if success {
                notificationManager.showSuccess("Saved to \(url.lastPathComponent)")
            } else {
                notificationManager.showError("Failed to save PDF")
            }
        }
    }

    func printPDF() {
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
