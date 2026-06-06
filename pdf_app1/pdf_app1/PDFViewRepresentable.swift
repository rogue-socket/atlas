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

        // Fit entire page on initial load. The previous version waited a
        // fixed 150ms hoping SwiftUI had assigned a real frame by then —
        // wrong on a slow machine (fit runs against zero bounds, falls back
        // to autoScales), wrong on a fast machine (visible jump from the
        // intermediate state). Observe `frameDidChangeNotification` instead,
        // attempt the fit on each frame change, and detach the observer the
        // first time it succeeds so subsequent user resizes don't yank zoom.
        pdfView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.attemptInitialFit(_:)),
            name: NSView.frameDidChangeNotification,
            object: pdfView
        )
        // Bounds may already be valid by the time we get here (re-entered
        // makeNSView, e.g. tab restore). Try once synchronously — the
        // notification path covers everything else.
        context.coordinator.attemptInitialFit(nil)

         pdfView.onMouseUp = { [weak coordinator = context.coordinator] in
             coordinator?.handleSelectionCompleted()
         }

         pdfView.onMouseDown = { [weak coordinator = context.coordinator, weak pdfView] event in
             guard let pdfView else { return }
             coordinator?.pendingDownLocation = pdfView.convert(event.locationInWindow, from: nil)
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
        
        context.coordinator.clickGesture.isEnabled = [.text, .stickyNote, .select].contains(annotationMode)
        context.coordinator.panGesture.isEnabled = [.select, .highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)
        context.coordinator.installKeyMonitor()
        context.coordinator.installMouseMonitor()
        context.coordinator.selectionOverlay.attach(to: pdfView)

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
        // Closures capture `pdfDocument` / call-site `@State` from the view
        // struct; each render builds fresh ones. Refresh them on the
        // coordinator so callbacks fire against the current document
        // instead of tab-1's stale capture.
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onAnnotationsChanged = onAnnotationsChanged
        context.coordinator.onTextAnnotationRequest = onTextAnnotationRequest

        if previousMode != annotationMode {
            // Update gesture recognizer state only when mode changes
            context.coordinator.clickGesture.isEnabled = [.text, .stickyNote, .select].contains(annotationMode)
            context.coordinator.panGesture.isEnabled = [.select, .highlightArea, .ink, .rectangle, .circle, .line, .arrow].contains(annotationMode)

            // Selection chrome only belongs to .select; drop it when leaving.
            if previousMode == .select && annotationMode != .select {
                context.coordinator.setSelection(nil, page: nil)
                // Hand cursor management back to PDFView's own cursor rects.
                nsView.window?.enableCursorRects()
            }

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
        var onAnnotationsChanged: () -> Void
        var onTextAnnotationRequest: (CGPoint) -> Void
        var onPageChanged: (PDFPage?) -> Void
        var onAnnotationError: ((String) -> Void)?
        var highlightStartPoint: CGPoint?
        var currentHighlight: PDFAnnotation?
        private var hitAnnotation: PDFAnnotation?
        private var hitAnnotationPage: PDFPage?
        
        let clickGesture: NSClickGestureRecognizer
        let panGesture: NSPanGestureRecognizer
        let selectionOverlay = SelectionChromeOverlay()
        private var keyMonitor: Any?
        private var mouseMonitor: Any?
        private var initialFitCompleted = false
        
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
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: pdfView)
            pdfView.onMouseUp = nil
            pdfView.onMouseDown = nil
            pdfView.menuProvider = nil
            pdfView.removeGestureRecognizer(clickGesture)
            pdfView.removeGestureRecognizer(panGesture)
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = mouseMonitor {
                NSEvent.removeMonitor(monitor)
                mouseMonitor = nil
            }
            selectionOverlay.removeFromSuperview()
        }

        /// One-shot fit-to-page driven by `NSView.frameDidChangeNotification`.
        /// Fires on every frame change until the view has real bounds AND the
        /// document has a page 0; on success, sets `scaleFactor` and detaches
        /// the observer so user-driven resizes don't yank the zoom. If the
        /// document has no pages, falls back to `autoScales = true` and stops
        /// trying (matches the old code's degenerate-document fallback).
        @objc func attemptInitialFit(_ notification: Notification?) {
            guard !initialFitCompleted else { return }
            guard let page = pdfView.document?.page(at: 0) else {
                pdfView.autoScales = true
                initialFitCompleted = true
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: pdfView)
                return
            }
            let pageRect = page.bounds(for: .mediaBox)
            let viewSize = pdfView.bounds.size
            guard pageRect.width > 0, pageRect.height > 0,
                  viewSize.width > 40, viewSize.height > 40 else {
                return  // Not ready yet — wait for next frame change.
            }
            let scaleX = (viewSize.width - 20) / pageRect.width
            let scaleY = (viewSize.height - 20) / pageRect.height
            pdfView.scaleFactor = min(scaleX, scaleY)
            initialFitCompleted = true
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: pdfView)
        }

        /// Catches Delete / Forward-Delete on the most recent select-mode hit
        /// annotation (`hitAnnotation` is set by select-pan `.began` and by
        /// right-click context menu). Returns nil to consume the event when a
        /// delete is performed; otherwise passes through.
        /// Tracks the active annotation across hit-tests from click, pan,
        /// context menu, and mode transitions. Mirrors `hitAnnotation` /
        /// `hitAnnotationPage` into the chrome overlay so a click without a
        /// drag still produces a visible selection.
        func setSelection(_ annotation: PDFAnnotation?, page: PDFPage?) {
            hitAnnotation = annotation
            hitAnnotationPage = page
            selectionOverlay.update(annotation: annotation, page: page)
        }

        /// Local NSEvent monitor for `.mouseMoved` — same shape as the keyboard
        /// monitor above. Only fires when our pdfView's window is keyed,
        /// `.select` is active, and the cursor is inside the pdfView frame.
        /// Sets `openHand` over body / `resize*` over corner-edge handles.
        func installMouseMonitor() {
            guard mouseMonitor == nil else { return }
            // mouseMoved events only dispatch when the window opts in.
            // PDFKit may have already enabled it for text selection, but
            // be explicit. Window is typically nil during makeNSView, so
            // defer to next runloop.
            DispatchQueue.main.async { [weak self] in
                self?.pdfView.window?.acceptsMouseMovedEvents = true
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.handleMouseMoved(event)
                return event
            }
        }

        private func handleMouseMoved(_ event: NSEvent) {
            guard annotationMode == .select else { return }
            guard let window = pdfView.window, event.window === window else { return }
            let locInView = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(locInView) else {
                // Off the pdfView — let other views manage the cursor again.
                window.enableCursorRects()
                return
            }
            // Suppress PDFView's text-selection I-beam cursor rect so the
            // select-mode cursor wins; re-enabled once the pointer leaves
            // the pdfView (here) or select mode (updateNSView).
            window.disableCursorRects()
            let cursor = selectModeCursor(at: locInView)
            // Defer the set one runloop tick so it lands after any per-event
            // cursor handling PDFView still does directly.
            DispatchQueue.main.async { cursor.set() }
        }

        /// Cursor for `.select` mode at a pdfView-space point: a resize cursor
        /// over a corner/edge handle of the annotation under the pointer,
        /// `openHand` over its body or empty space.
        private func selectModeCursor(at locInView: CGPoint) -> NSCursor {
            guard let page = pdfView.page(for: locInView, nearest: false) else { return .openHand }
            let pagePoint = pdfView.convert(locInView, to: page)
            guard let annotation = page.annotation(at: pagePoint) else { return .openHand }
            let handle = AnnotationGeometry.handle(
                at: pagePoint, rect: annotation.bounds, handleSize: resizeHandleHitSize) ?? .body
            switch handle {
            case .body: return .openHand
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
            }
        }

        func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Only fire when our PDFView is in the key window's responder
                // path — otherwise text fields, search bars, etc. swallow
                // their own deletes first via the responder chain (this
                // monitor only intercepts events the chain hasn't handled).
                guard self.annotationMode == .select else { return event }
                guard let window = self.pdfView.window, window.isKeyWindow else { return event }
                // 51 = delete/backspace, 117 = forward delete (fn-delete).
                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                // Pass through when the user is editing text. Walk up from
                // firstResponder; only intercept when pdfView (or a descendant)
                // owns focus. Without this, deletes in the search bar / note
                // editor / project rename would silently nuke the most-recent
                // hit annotation instead.
                var responder: NSResponder? = window.firstResponder
                while let r = responder {
                    if r === self.pdfView { break }
                    responder = r.nextResponder
                }
                guard responder != nil else { return event }
                guard let annotation = self.hitAnnotation, let page = self.hitAnnotationPage else {
                    return event
                }
                page.removeAnnotation(annotation)
                self.undoRedoManager.addOperation(.remove(annotation: annotation, page: page))
                self.setSelection(nil, page: nil)
                self.onAnnotationsChanged()
                return nil
            }
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

            if annotation.isKind(.freeText) {
                let editItem = NSMenuItem(title: "Edit Text…", action: #selector(editHitFreeTextAnnotation(_:)), keyEquivalent: "")
                editItem.target = self
                menu.addItem(editItem)
            }

            if annotation.isKind(.highlight) {
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
            guard annotation.isKind(.freeText) else { return }

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
            guard annotation.isKind(.highlight) else { return }

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
            setSelection(nil, page: nil)
            onAnnotationsChanged()
        }
        
        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard [.text, .stickyNote, .select].contains(annotationMode) else { return }
            guard pdfView.document != nil else { return }

            let location = gesture.location(in: pdfView)

            if annotationMode == .select {
                guard let page = pdfView.page(for: location, nearest: false) else {
                    setSelection(nil, page: nil); return
                }
                let pagePoint = pdfView.convert(location, to: page)
                let annotation = page.annotation(at: pagePoint)
                setSelection(annotation, page: annotation == nil ? nil : page)
                return
            }

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

        // MARK: - Select / Move / Resize Drag
        private var dragAnnotation: PDFAnnotation?
        private var dragPage: PDFPage?
        private var dragOriginalBounds: CGRect = .zero
        private var dragStartPagePoint: CGPoint = .zero
        private var dragHandle: AnnotationGeometry.DragHandle = .body
        /// pdfView-space mouse-down point, captured before the pan recognizer's
        /// threshold consumes the first few points — used by select-pan `.began`
        /// for a reliable handle hit-test.
        var pendingDownLocation: CGPoint?

        /// In page-space units. ~12pt at 100% zoom; resize-corner forgiveness.
        private let resizeHandleHitSize: CGFloat = 12
        /// Minimum bounds size on resize (page-space).
        private let annotationMinSize = CGSize(width: 8, height: 8)

        private func resizeCursor(for handle: AnnotationGeometry.DragHandle) -> NSCursor {
            switch handle {
            case .body: return .closedHand
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
            }
        }

        private func handleSelectPan(_ gesture: NSPanGestureRecognizer, location: CGPoint) {
            switch gesture.state {
            case .began:
                // The gesture's .began location is already past the recognition
                // threshold — often off the handle, or off the annotation
                // entirely when a corner is dragged outward. Use the true
                // mouse-down point (captured by pdfView before the threshold)
                // so the handle hit-test is reliable.
                let downLocation = pendingDownLocation ?? location
                guard let page = pdfView.page(for: downLocation, nearest: false) else { return }
                let pagePoint = pdfView.convert(downLocation, to: page)
                // Prefer the already-selected annotation when the press lands on
                // it or one of its handles: handles extend ~12pt beyond the
                // annotation bounds, so page.annotation(at:) alone misses
                // outer-handle presses.
                let annotation: PDFAnnotation
                if let selected = hitAnnotation, hitAnnotationPage === page,
                   selected.bounds.contains(pagePoint)
                       || AnnotationGeometry.handle(at: pagePoint, rect: selected.bounds,
                                                    handleSize: resizeHandleHitSize) != nil {
                    annotation = selected
                } else if let hit = page.annotation(at: pagePoint) {
                    annotation = hit
                } else {
                    return
                }
                dragAnnotation = annotation
                dragPage = page
                dragOriginalBounds = annotation.bounds
                dragStartPagePoint = pagePoint
                dragHandle = AnnotationGeometry.handle(
                    at: pagePoint, rect: annotation.bounds, handleSize: resizeHandleHitSize
                ) ?? .body
                // Track as the active annotation so keyboard delete and the
                // context-menu actions both target the most-recent select.
                setSelection(annotation, page: page)
                resizeCursor(for: dragHandle).set()

            case .changed:
                guard let annotation = dragAnnotation, let page = dragPage else { return }
                let pagePoint = pdfView.convert(location, to: page)
                let delta = CGVector(dx: pagePoint.x - dragStartPagePoint.x,
                                     dy: pagePoint.y - dragStartPagePoint.y)
                let pageBounds = page.bounds(for: .mediaBox)
                let newBounds: CGRect
                if dragHandle == .body {
                    newBounds = AnnotationGeometry.translated(
                        rect: dragOriginalBounds, by: delta, in: pageBounds)
                } else {
                    newBounds = AnnotationGeometry.resized(
                        rect: dragOriginalBounds, handle: dragHandle, by: delta,
                        in: pageBounds, minSize: annotationMinSize)
                }
                annotation.bounds = newBounds
                pdfView.setNeedsDisplay(pdfView.bounds)
                selectionOverlay.needsDisplay = true

            case .ended, .cancelled:
                NSCursor.openHand.set()
                let endedAnnotation = dragAnnotation
                let endedPage = dragPage
                let endedOriginal = dragOriginalBounds
                dragAnnotation = nil
                dragPage = nil
                dragOriginalBounds = .zero
                dragStartPagePoint = .zero
                dragHandle = .body
                guard let annotation = endedAnnotation, let page = endedPage else { return }
                let newBounds = annotation.bounds
                guard newBounds != endedOriginal else { return }
                undoRedoManager.addOperation(.modify(
                    annotation: annotation,
                    oldBounds: endedOriginal,
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

/// Transparent NSView pinned to the pdfView frame that draws selection chrome
/// (1pt outline + 8 filled handles) for the currently-selected annotation in
/// `.select` mode. Click-through via `hitTest` returning nil so the underlying
/// gesture recognizers continue to receive events. Invalidates on scale,
/// page-change, and clip-view bounds-change (scroll) — annotation bounds get
/// re-queried in `draw(_:)` so live drag updates are free as long as the
/// caller marks `needsDisplay`.
final class SelectionChromeOverlay: NSView {
    weak var pdfView: PDFView?
    private(set) var selectedAnnotation: PDFAnnotation?
    private(set) var selectedPage: PDFPage?

    /// Visual size of the handle squares in pdfView (point) coordinates.
    var handleSize: CGFloat = 8

    override var isFlipped: Bool { pdfView?.isFlipped ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(annotation: PDFAnnotation?, page: PDFPage?) {
        selectedAnnotation = annotation
        selectedPage = page
        needsDisplay = true
    }

    func attach(to pdfView: PDFView) {
        self.pdfView = pdfView
        self.autoresizingMask = [.width, .height]
        self.frame = pdfView.bounds
        pdfView.addSubview(self)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(invalidate),
                       name: .PDFViewPageChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(invalidate),
                       name: .PDFViewScaleChanged, object: pdfView)
        nc.addObserver(self, selector: #selector(invalidate),
                       name: .PDFViewVisiblePagesChanged, object: pdfView)
        if let clipView = pdfView.documentView?.enclosingScrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            nc.addObserver(self, selector: #selector(invalidate),
                           name: NSView.boundsDidChangeNotification, object: clipView)
        }
    }

    @objc private func invalidate() { needsDisplay = true }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView, let annotation = selectedAnnotation, let page = selectedPage else { return }
        let r = pdfView.convert(annotation.bounds, from: page)
        guard r.width > 0, r.height > 0, let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))

        let cx = r.midX, cy = r.midY
        let centers: [CGPoint] = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: cx, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: cy),                                CGPoint(x: r.maxX, y: r.maxY),
            CGPoint(x: cx, y: r.maxY),     CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: cy)
        ]
        let fill = NSColor.controlAccentColor.cgColor
        let stroke = NSColor.white.cgColor
        let half = handleSize / 2
        for c in centers {
            let h = CGRect(x: c.x - half, y: c.y - half, width: handleSize, height: handleSize)
            ctx.setFillColor(fill)
            ctx.fill(h)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(1)
            ctx.stroke(h)
        }
    }
}
