//
//  MapInteraction.swift
//  Atlas
//
//  Handles pan, zoom, click, and drag interactions for the knowledge map
//

import SwiftUI
import Observation

@Observable
class MapInteraction {
    var viewScale: CGFloat = 1.0
    var viewOffset: CGPoint = .zero
    var selectedNodeID: UUID?
    var hoveredNodeID: UUID?

    private var dragStartOffset: CGPoint = .zero
    private(set) var isDragging: Bool = false
    private(set) var isDraggingNode: Bool = false
    private var draggingNodeID: UUID?
    private var dragStartNodePosition: CGPoint = .zero

    // MARK: - Zoom

    func handleMagnification(_ value: CGFloat, anchor: CGPoint) {
        let newScale = max(0.1, min(5.0, viewScale * value))
        viewScale = newScale
    }

    func zoomIn() {
        viewScale = min(5.0, viewScale * 1.2)
    }

    func zoomOut() {
        viewScale = max(0.1, viewScale / 1.2)
    }

    func resetZoom() {
        viewScale = 1.0
        viewOffset = .zero
    }

    // MARK: - Pan

    func handleDragStart(at location: CGPoint, layout: ForceDirectedLayout, graph: KnowledgeGraph) {
        isDragging = true
        if let nodeID = hitTest(location: location, layout: layout, graph: graph) {
            isDraggingNode = true
            draggingNodeID = nodeID
            dragStartNodePosition = layout.point(for: nodeID) ?? .zero
            selectedNodeID = nodeID
        } else {
            isDraggingNode = false
            draggingNodeID = nil
            dragStartOffset = viewOffset
        }
    }

    func handleDragChanged(translation: CGSize, layout: ForceDirectedLayout) {
        if isDraggingNode, let nodeID = draggingNodeID {
            let newPos = CGPoint(
                x: dragStartNodePosition.x + translation.width / viewScale,
                y: dragStartNodePosition.y + translation.height / viewScale
            )
            layout.setPosition(newPos, for: nodeID)
        } else {
            viewOffset = CGPoint(
                x: dragStartOffset.x + translation.width,
                y: dragStartOffset.y + translation.height
            )
        }
    }

    func handleDragEnded() {
        isDragging = false
        isDraggingNode = false
        draggingNodeID = nil
    }

    // MARK: - Click

    func handleClick(at location: CGPoint, layout: ForceDirectedLayout, graph: KnowledgeGraph) {
        if let nodeID = hitTest(location: location, layout: layout, graph: graph) {
            selectedNodeID = (selectedNodeID == nodeID) ? nil : nodeID
        } else {
            selectedNodeID = nil
        }
    }

    // MARK: - Hit Testing

    func hitTest(location: CGPoint, layout: ForceDirectedLayout, graph: KnowledgeGraph) -> UUID? {
        let nodeWidth = AppConstants.mapNodeWidth * viewScale
        let nodeHeight = AppConstants.mapNodeHeight * viewScale

        // Transform the click location to graph space
        let graphLocation = CGPoint(
            x: (location.x - viewOffset.x) / viewScale,
            y: (location.y - viewOffset.y) / viewScale
        )

        for node in graph.allNodes {
            guard let pos = layout.point(for: node.id) else { continue }

            let nodeRect = CGRect(
                x: pos.x - AppConstants.mapNodeWidth / 2,
                y: pos.y - AppConstants.mapNodeHeight / 2,
                width: AppConstants.mapNodeWidth,
                height: AppConstants.mapNodeHeight
            )

            if nodeRect.contains(graphLocation) {
                return node.id
            }
        }
        return nil
    }

    // MARK: - Scroll Wheel Zoom

    func handleScrollWheel(deltaY: CGFloat, cursorLocation: CGPoint) {
        let factor: CGFloat = deltaY > 0 ? 1.05 : 0.95
        let newScale = max(0.1, min(5.0, viewScale * factor))
        let cursorInGraph = CGPoint(
            x: (cursorLocation.x - viewOffset.x) / viewScale,
            y: (cursorLocation.y - viewOffset.y) / viewScale
        )
        viewScale = newScale
        viewOffset = CGPoint(
            x: cursorLocation.x - cursorInGraph.x * newScale,
            y: cursorLocation.y - cursorInGraph.y * newScale
        )
    }

    // MARK: - Fit to Content

    func fitToContent(layout: ForceDirectedLayout, canvasSize: CGSize) {
        guard !layout.positions.isEmpty, !isDragging else { return }

        let positions = layout.positions.values
        let minX = positions.map { $0.x }.min() ?? 0
        let maxX = positions.map { $0.x }.max() ?? canvasSize.width
        let minY = positions.map { $0.y }.min() ?? 0
        let maxY = positions.map { $0.y }.max() ?? canvasSize.height

        let contentWidth = maxX - minX + 100
        let contentHeight = maxY - minY + 100

        let scaleX = canvasSize.width / contentWidth
        let scaleY = canvasSize.height / contentHeight
        viewScale = min(scaleX, scaleY, 2.0)

        viewOffset = CGPoint(
            x: canvasSize.width / 2 - (minX + maxX) / 2 * viewScale,
            y: canvasSize.height / 2 - (minY + maxY) / 2 * viewScale
        )
    }
}
