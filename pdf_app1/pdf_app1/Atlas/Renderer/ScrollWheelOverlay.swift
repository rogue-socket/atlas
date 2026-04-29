//
//  ScrollWheelOverlay.swift
//  Atlas
//
//  Captures scroll wheel events for zoom on the knowledge map canvas.
//

import SwiftUI
import AppKit

struct ScrollWheelOverlay: NSViewRepresentable {
    let onScrollWheel: (_ deltaY: CGFloat, _ location: CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelCaptureView {
        let view = ScrollWheelCaptureView()
        view.onScrollWheel = onScrollWheel
        return view
    }

    func updateNSView(_ nsView: ScrollWheelCaptureView, context: Context) {
        nsView.onScrollWheel = onScrollWheel
    }
}

class ScrollWheelCaptureView: NSView {
    var onScrollWheel: ((_ deltaY: CGFloat, _ location: CGPoint) -> Void)?
    private var scrollMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil  // Pass all mouse events through to SwiftUI gestures
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollEvent(event)
                return event
            }
        } else if window == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        guard window != nil else { return }
        let viewLocation = convert(event.locationInWindow, from: nil)
        guard bounds.contains(viewLocation) else { return }
        let flippedLocation = CGPoint(x: viewLocation.x, y: bounds.height - viewLocation.y)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard abs(delta) > 0.1 else { return }
        onScrollWheel?(delta, flippedLocation)
    }
}
