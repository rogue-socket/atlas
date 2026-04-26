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

    // MARK: - Group Backgrounds (hierarchy-based)

    private func drawGroupBackgrounds(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        // Group by concept node: each concept + its entities form a cluster
        let conceptNodes = graph.allNodes.filter { $0.level == .concept }

        for conceptNode in conceptNodes {
            // Collect concept + its visible entities
            let entityNodes = graph.entities(for: conceptNode.id)
            let clusterNodes = [conceptNode] + entityNodes
            let groupPoints = clusterNodes.compactMap { layout.point(for: $0.id)?.applying(transform) }
            guard groupPoints.count >= 1 else { continue }

            let padding: CGFloat = 40 * viewScale
            let minX = groupPoints.map(\.x).min()! - padding
            let maxX = groupPoints.map(\.x).max()! + padding
            let minY = groupPoints.map(\.y).min()! - 30 * viewScale
            let maxY = groupPoints.map(\.y).max()! + 50 * viewScale

            let groupRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            guard groupRect.maxX >= 0, groupRect.minX <= size.width,
                  groupRect.maxY >= 0, groupRect.minY <= size.height else { continue }

            let color = conceptNode.type.color
            let path = Path(roundedRect: groupRect, cornerRadius: 12 * viewScale)
            context.fill(path, with: .color(color.opacity(0.04)))
            context.stroke(path, with: .color(color.opacity(0.15)), lineWidth: 1)

            // Group label (concept name as header)
            if viewScale > 0.3 && !entityNodes.isEmpty {
                let label = Text(conceptNode.label)
                    .font(.system(size: max(9, 10 * viewScale), weight: .semibold))
                    .foregroundColor(color.opacity(0.5))
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

            // Hide containsEntity edges (hierarchy is shown via grouping)
            if edge.type == .containsEntity { continue }

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
        // Draw entities first, then concepts on top
        let sortedNodes = graph.allNodes.sorted { a, b in
            if a.level == b.level { return false }
            return a.level == .entity
        }

        // Precompute entity counts per concept to avoid O(n) filter per node per frame
        var entityCountByParent: [UUID: Int] = [:]
        for n in graph.allNodes where n.level == .entity {
            if let pid = n.parentConceptID {
                entityCountByParent[pid, default: 0] += 1
            }
        }

        for node in sortedNodes {
            guard let pos = layout.point(for: node.id) else { continue }
            let tp = pos.applying(transform)

            let isSelected = node.id == selectedNodeID
            let isActive = node.id == activeNodeID
            let isHighlighted = highlightedNodeIDs.contains(node.id)
            let isDimmed = !highlightedNodeIDs.isEmpty && !isHighlighted && !isSelected
            let isConcept = node.level == .concept
            let isMultiDoc = node.sourceAnchors.contains { $0.documentURL != node.sourceAnchors.first?.documentURL }

            // Dynamic node size — concepts are larger
            let hasSummary = node.summary != nil && viewScale >= 0.7
            let baseW: CGFloat = isConcept ? 200 : (hasSummary ? 180 : 140)
            let baseH: CGFloat = isConcept ? (hasSummary ? 60 : 42) : (hasSummary ? 50 : 34)
            let nodeW = baseW * viewScale
            let nodeH = baseH * viewScale
            let cr: CGFloat = 8 * viewScale

            let rect = CGRect(x: tp.x - nodeW / 2, y: tp.y - nodeH / 2, width: nodeW, height: nodeH)
            guard rect.maxX >= 0, rect.minX <= size.width, rect.maxY >= 0, rect.minY <= size.height else { continue }

            // Far zoom: dots only
            if viewScale < 0.35 {
                let ds: CGFloat = isDimmed ? 4 : (isConcept ? 10 : 6)
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
            else { bg = Color(nsColor: .controlBackgroundColor).opacity(isConcept ? 0.95 : 0.85) }

            let nodePath = Path(roundedRect: rect, cornerSize: CGSize(width: cr, height: cr))
            context.fill(nodePath, with: .color(bg.opacity(bgAlpha)))

            // Border — concepts get thicker, multi-doc nodes get a distinctive border
            let borderColor: Color
            if isSelected { borderColor = .accentColor }
            else if isHighlighted { borderColor = node.type.color }
            else if isMultiDoc { borderColor = .orange.opacity(0.6) }
            else { borderColor = isConcept ? node.type.color.opacity(0.4) : .gray.opacity(0.3) }

            let bw: CGFloat = isSelected || isHighlighted ? 2 : (isConcept ? 1.5 : 1)
            if node.confidence < 0.6 {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), style: StrokeStyle(lineWidth: bw, dash: [4, 3]))
            } else if isMultiDoc {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), style: StrokeStyle(lineWidth: bw, dash: [6, 2]))
            } else {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), lineWidth: bw)
            }

            guard viewScale >= 0.45 else { continue }

            // Type color strip on left — thicker for concepts
            let stripW: CGFloat = (isConcept ? 4 : 3) * viewScale
            let stripPath = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: stripW, height: rect.height),
                                 cornerSize: CGSize(width: cr, height: cr))
            context.fill(stripPath, with: .color(node.type.color.opacity(isDimmed ? 0.2 : 0.8)))

            // Label — concepts get bolder, larger text
            let fontSize = max(10, (isConcept ? 12 : 11) * viewScale)
            let fontWeight: Font.Weight = isConcept ? .bold : .semibold
            let labelX = rect.minX + stripW + 4 * viewScale
            let label = Text(node.label)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundColor(isDimmed ? .secondary.opacity(0.4) : .primary)
            context.draw(context.resolve(label), in: CGRect(x: labelX, y: rect.minY + 3 * viewScale, width: nodeW - stripW - 8 * viewScale, height: fontSize + 4))

            // Entity count badge for concept nodes
            if isConcept && viewScale >= 0.5 {
                let entityCount = entityCountByParent[node.id] ?? 0
                if entityCount > 0 {
                    let badge = Text("\(entityCount)")
                        .font(.system(size: max(7, 8 * viewScale), weight: .medium))
                        .foregroundColor(node.type.color)
                    let badgeSize: CGFloat = 14 * viewScale
                    let badgeRect = CGRect(x: rect.maxX - badgeSize - 3 * viewScale, y: rect.minY + 3 * viewScale, width: badgeSize, height: badgeSize)
                    let badgePath = Path(ellipseIn: badgeRect)
                    context.fill(badgePath, with: .color(node.type.color.opacity(0.15)))
                    context.draw(context.resolve(badge), in: badgeRect)
                }
            }

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

            // Bottom-right indicators
            if viewScale >= 0.6 {
                let iconSize: CGFloat = 10 * viewScale
                var iconX = rect.maxX - 3 * viewScale

                // Multi-document indicator
                if isMultiDoc {
                    iconX -= iconSize
                    let iconRect = CGRect(x: iconX, y: rect.maxY - iconSize - 3 * viewScale, width: iconSize, height: iconSize)
                    let docIcon = Text(Image(systemName: "doc.on.doc"))
                        .font(.system(size: max(7, 8 * viewScale)))
                        .foregroundColor(.orange.opacity(isDimmed ? 0.2 : 0.6))
                    context.draw(context.resolve(docIcon), in: iconRect)
                    iconX -= 2 * viewScale
                }

                // Source anchor indicator
                if !node.sourceAnchors.isEmpty {
                    iconX -= iconSize
                    let iconRect = CGRect(x: iconX, y: rect.maxY - iconSize - 3 * viewScale, width: iconSize, height: iconSize)
                    let linkIcon = Text(Image(systemName: "link"))
                        .font(.system(size: max(7, 8 * viewScale)))
                        .foregroundColor(.secondary.opacity(isDimmed ? 0.2 : 0.5))
                    context.draw(context.resolve(linkIcon), in: iconRect)
                }
            }
        }
    }
}
