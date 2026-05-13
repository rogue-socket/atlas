//
//  PDFViewRepresentable.swift
//  PDFViewer
//
//  NSViewRepresentable bridge to PDFKit's PDFView, plus its Coordinator.
//  Handles gesture-driven annotation creation/editing and context menus.
//

import SwiftUI
import PDFKit
import AppKit

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
        context.coordinator.panGesture.isEnabled = [.select, .highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)
        
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
            context.coordinator.panGesture.isEnabled = [.select, .highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)

            // Clear selection when leaving text-selection modes
            if ![AnnotationMode.highlightText, .underline, .strikethrough].contains(annotationMode) {
                nsView.clearSelection()
            }

            // Update cursor based on annotation mode
            DispatchQueue.main.async {
                switch annotationMode {
                case .none:
                    NSCursor.arrow.set()
                case .select:
                    NSCursor.openHand.set()
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

            if annotationMode == .select {
                handleSelectPan(gesture, location: location)
                return
            }

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

        // MARK: - Select / Move Drag
        private var dragAnnotation: PDFAnnotation?
        private var dragPage: PDFPage?
        private var dragOriginalBounds: CGRect = .zero
        private var dragStartPagePoint: CGPoint = .zero

        private func handleSelectPan(_ gesture: NSPanGestureRecognizer, location: CGPoint) {
            switch gesture.state {
            case .began:
                guard let page = pdfView.page(for: location, nearest: false) else { return }
                let pagePoint = pdfView.convert(location, to: page)
                guard let annotation = page.annotation(at: pagePoint) else { return }
                dragAnnotation = annotation
                dragPage = page
                dragOriginalBounds = annotation.bounds
                dragStartPagePoint = pagePoint
                NSCursor.closedHand.set()

            case .changed:
                guard let annotation = dragAnnotation, let page = dragPage else { return }
                let pagePoint = pdfView.convert(location, to: page)
                let delta = CGVector(dx: pagePoint.x - dragStartPagePoint.x,
                                     dy: pagePoint.y - dragStartPagePoint.y)
                let newBounds = AnnotationGeometry.translated(
                    rect: dragOriginalBounds, by: delta,
                    in: page.bounds(for: .mediaBox))
                annotation.bounds = newBounds
                pdfView.setNeedsDisplay(pdfView.bounds)

            case .ended, .cancelled:
                NSCursor.openHand.set()
                defer {
                    dragAnnotation = nil
                    dragPage = nil
                    dragOriginalBounds = .zero
                    dragStartPagePoint = .zero
                }
                guard let annotation = dragAnnotation, let page = dragPage else { return }
                let newBounds = annotation.bounds
                guard newBounds != dragOriginalBounds else { return }
                undoRedoManager.addOperation(.modify(
                    annotation: annotation,
                    oldBounds: dragOriginalBounds,
                    newBounds: newBounds,
                    page: page))
                onAnnotationsChanged()

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
