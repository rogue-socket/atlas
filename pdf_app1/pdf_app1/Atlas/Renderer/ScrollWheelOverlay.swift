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

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let flippedLocation = CGPoint(x: location.x, y: bounds.height - location.y)
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        guard abs(delta) > 0.1 else { return }
        onScrollWheel?(delta, flippedLocation)
    }
}
