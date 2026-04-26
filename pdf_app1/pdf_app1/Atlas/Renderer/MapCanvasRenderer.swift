//
//  MapCanvasRenderer.swift
//  Atlas
//
//  SwiftUI Canvas-based renderer for the knowledge graph.
//  Nodes sized by content, grouped by type, with summaries visible.
//

import SwiftUI

struct MapCanvasRenderer: View {
    var graph: KnowledgeGraph
    @Bindable var layout: ForceDirectedLayout
    @Binding var zoomLevel: SemanticZoomLevel
    @Binding var selectedNodeID: UUID?
    var activeNodeID: UUID?
    var highlightedNodeIDs: Set<UUID>
    var viewScale: CGFloat
    var viewOffset: CGPoint

    var body: some View {
        Canvas { context, size in
            let transform = CGAffineTransform(translationX: viewOffset.x, y: viewOffset.y)
                .scaledBy(x: viewScale, y: viewScale)

            drawGroupBackgrounds(context: context, transform: transform, size: size)
            drawEdges(context: context, transform: transform, size: size)
            drawNodes(context: context, transform: transform, size: size)
        }
    }

    // MARK: - Group Backgrounds

    private func drawGroupBackgrounds(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        let groups = Dictionary(grouping: graph.allNodes, by: { $0.type })

        for (type, nodes) in groups {
            let groupPoints = nodes.compactMap { layout.point(for: $0.id)?.applying(transform) }
            guard groupPoints.count >= 2 else { continue }

            let minX = groupPoints.map(\.x).min()! - 40 * viewScale
            let maxX = groupPoints.map(\.x).max()! + 40 * viewScale
            let minY = groupPoints.map(\.y).min()! - 30 * viewScale
            let maxY = groupPoints.map(\.y).max()! + 50 * viewScale

            let groupRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard groupRect.maxX >= 0, groupRect.minX <= size.width,
                  groupRect.maxY >= 0, groupRect.minY <= size.height else { continue }

            let path = Path(roundedRect: groupRect, cornerRadius: 12 * viewScale)
            context.fill(path, with: .color(type.color.opacity(0.04)))
            context.stroke(path, with: .color(type.color.opacity(0.15)), lineWidth: 1)

            // Group label
            if viewScale > 0.3 {
                let label = Text(type.displayName)
                    .font(.system(size: max(9, 10 * viewScale), weight: .semibold))
                    .foregroundColor(type.color.opacity(0.5))
                context.draw(context.resolve(label), at: CGPoint(x: minX + 8 * viewScale, y: minY + 4 * viewScale), anchor: .topLeading)
            }
        }
    }

    // MARK: - Edges

    private func drawEdges(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        for edge in graph.allEdges {
            guard let srcPos = layout.point(for: edge.sourceNodeID),
                  let tgtPos = layout.point(for: edge.targetNodeID) else { continue }
            let src = srcPos.applying(transform)
            let tgt = tgtPos.applying(transform)

            guard max(src.x, tgt.x) >= 0, min(src.x, tgt.x) <= size.width,
                  max(src.y, tgt.y) >= 0, min(src.y, tgt.y) <= size.height else { continue }

            // Curved edge
            var path = Path()
            let dx = tgt.x - src.x
            let dy = tgt.y - src.y
            let ctrl = CGPoint(x: (src.x + tgt.x) / 2 - dy * 0.08, y: (src.y + tgt.y) / 2 + dx * 0.08)
            path.move(to: src)
            path.addQuadCurve(to: tgt, control: ctrl)

            let alpha: Double = (edge.sourceNodeID == selectedNodeID || edge.targetNodeID == selectedNodeID) ? 0.7 : 0.25
            context.stroke(path, with: .color(edge.type.color.opacity(alpha)), lineWidth: 1.2)

            // Arrow
            let arrowLen: CGFloat = 7 * viewScale
            let angle = atan2(tgt.y - ctrl.y, tgt.x - ctrl.x)
            var arrow = Path()
            arrow.move(to: tgt)
            arrow.addLine(to: CGPoint(x: tgt.x - arrowLen * cos(angle - .pi/6), y: tgt.y - arrowLen * sin(angle - .pi/6)))
            arrow.addLine(to: CGPoint(x: tgt.x - arrowLen * cos(angle + .pi/6), y: tgt.y - arrowLen * sin(angle + .pi/6)))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(edge.type.color.opacity(alpha)))
        }
    }

    // MARK: - Nodes

    private func drawNodes(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        for node in graph.allNodes {
            guard let pos = layout.point(for: node.id) else { continue }
            let tp = pos.applying(transform)

            let isSelected = node.id == selectedNodeID
            let isActive = node.id == activeNodeID
            let isHighlighted = highlightedNodeIDs.contains(node.id)
            let isDimmed = !highlightedNodeIDs.isEmpty && !isHighlighted && !isSelected

            // Dynamic node size based on content
            let hasSummary = node.summary != nil && viewScale >= 0.7
            let nodeW: CGFloat = (hasSummary ? 200 : 140) * viewScale
            let nodeH: CGFloat = (hasSummary ? 56 : 34) * viewScale
            let cr: CGFloat = 8 * viewScale

            let rect = CGRect(x: tp.x - nodeW / 2, y: tp.y - nodeH / 2, width: nodeW, height: nodeH)
            guard rect.maxX >= 0, rect.minX <= size.width, rect.maxY >= 0, rect.minY <= size.height else { continue }

            // Far zoom: dots only
            if viewScale < 0.35 {
                let ds: CGFloat = isDimmed ? 4 : 8
                let dr = CGRect(x: tp.x - ds/2, y: tp.y - ds/2, width: ds, height: ds)
                context.fill(Path(ellipseIn: dr), with: .color(isDimmed ? node.type.color.opacity(0.2) : node.type.color))
                continue
            }

            // Background
            let bgAlpha: Double = isDimmed ? 0.3 : 1.0
            let bg: Color
            if isSelected { bg = Color.accentColor.opacity(0.18) }
            else if isHighlighted { bg = node.type.color.opacity(0.12) }
            else if isActive { bg = node.type.color.opacity(0.10) }
            else { bg = Color(nsColor: .controlBackgroundColor).opacity(0.9) }

            let nodePath = Path(roundedRect: rect, cornerSize: CGSize(width: cr, height: cr))
            context.fill(nodePath, with: .color(bg.opacity(bgAlpha)))

            // Border
            let borderColor: Color = isSelected ? .accentColor : (isHighlighted ? node.type.color : .gray.opacity(0.3))
            let bw: CGFloat = isSelected || isHighlighted ? 2 : 1
            if node.confidence < 0.6 {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), style: StrokeStyle(lineWidth: bw, dash: [4, 3]))
            } else {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), lineWidth: bw)
            }

            guard viewScale >= 0.45 else { continue }

            // Type color strip on left
            let stripW: CGFloat = 3 * viewScale
            let stripPath = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: stripW, height: rect.height),
                                 cornerSize: CGSize(width: cr, height: cr))
            context.fill(stripPath, with: .color(node.type.color.opacity(isDimmed ? 0.2 : 0.8)))

            // Label
            let fontSize = max(10, 11 * viewScale)
            let labelX = rect.minX + stripW + 4 * viewScale
            let label = Text(node.label)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(isDimmed ? .secondary.opacity(0.4) : .primary)
            context.draw(context.resolve(label), in: CGRect(x: labelX, y: rect.minY + 3 * viewScale, width: nodeW - stripW - 8 * viewScale, height: fontSize + 4))

            // Summary (when zoomed in enough and node has one)
            if hasSummary, let summary = node.summary {
                let sumFontSize = max(8, 9 * viewScale)
                let sumText = Text(summary)
                    .font(.system(size: sumFontSize))
                    .foregroundColor(isDimmed ? .secondary.opacity(0.3) : .secondary)
                context.draw(context.resolve(sumText), in: CGRect(
                    x: labelX,
                    y: rect.minY + (fontSize + 6) * viewScale,
                    width: nodeW - stripW - 8 * viewScale,
                    height: nodeH - (fontSize + 8) * viewScale
                ))
            }

            // Source indicator (clickable hint)
            if !node.sourceAnchors.isEmpty && viewScale >= 0.6 {
                let iconSize: CGFloat = 10 * viewScale
                let iconRect = CGRect(x: rect.maxX - iconSize - 3 * viewScale, y: rect.maxY - iconSize - 3 * viewScale, width: iconSize, height: iconSize)
                let linkIcon = Text(Image(systemName: "link"))
                    .font(.system(size: max(7, 8 * viewScale)))
                    .foregroundColor(.secondary.opacity(isDimmed ? 0.2 : 0.5))
                context.draw(context.resolve(linkIcon), in: iconRect)
            }
        }
    }
}
