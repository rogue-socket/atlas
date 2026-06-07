//
//  HighlightingPDFView.swift
//  PDFViewer
//
//  PDFView subclass with PDF viewer event hooks.
//

import AppKit
import PDFKit

final class HighlightingPDFView: PDFView {
    var onMouseUp: (() -> Void)?
    var onMouseDown: ((NSEvent) -> Void)?
    var menuProvider: ((NSEvent) -> NSMenu?)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupPerformanceOptimizations()
            // Ensure .mouseMoved events flow so the select-mode hover-cursor
            // monitor fires; PDFKit does not reliably enable this itself.
            window?.acceptsMouseMovedEvents = true
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

    override func mouseDown(with event: NSEvent) {
        // Capture the press point before the pan recognizer's threshold
        // consumes the first few points of movement — the select-mode
        // handle hit-test needs the true mouse-down location.
        onMouseDown?(event)
        super.mouseDown(with: event)
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
