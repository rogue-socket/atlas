//
//  MapCanvasRenderer.swift
//  Atlas
//
//  SwiftUI Canvas-based renderer for the knowledge graph.
//  Nodes sized by content, grouped by type, with summaries visible.
//

import SwiftUI

struct MapCanvasRenderer: View {
    @Bindable var layout: ForceDirectedLayout
    @Binding var zoomLevel: SemanticZoomLevel
    @Binding var selectedNodeID: UUID?
    var activeNodeID: UUID?
    var highlightedNodeIDs: Set<UUID>
    var viewScale: CGFloat
    var viewOffset: CGPoint
    let renderCache: RenderCache

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
        guard !renderCache.conceptEntityGroups.isEmpty else { return }

        for (conceptNode, entityNodes) in renderCache.conceptEntityGroups {
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

    struct RenderCache {
        let sortedNodes: [ConceptNode]
        let semanticEdges: [GraphEdge]
        let entityCountByParent: [UUID: Int]
        let conceptEntityGroups: [(concept: ConceptNode, entities: [ConceptNode])]
        let nodeIDsWithChildren: Set<UUID>

        static let empty = RenderCache(
            sortedNodes: [],
            semanticEdges: [],
            entityCountByParent: [:],
            conceptEntityGroups: [],
            nodeIDsWithChildren: []
        )
    }

    static func makeRenderCache(for graph: KnowledgeGraph) -> RenderCache {
        let levelOrder: [NodeLevel: Int] = [.entity: 0, .concept: 1, .chapter: 2, .document: 3]
        let sortedNodes = graph.allNodes.sorted { a, b in
            (levelOrder[a.level] ?? 0) < (levelOrder[b.level] ?? 0)
        }

        let allEdges = graph.allEdges
        let semanticEdges = allEdges.filter { !$0.type.isContainment }
        let conceptEntityGroups = Self.conceptEntityGroups(in: graph, edges: allEdges)
        let entityCountByParent = Dictionary(
            uniqueKeysWithValues: conceptEntityGroups.map { ($0.concept.id, $0.entities.count) }
        )
        let nodeIDsWithChildren = Set(allEdges.filter(\.type.isContainment).map(\.sourceNodeID))

        return RenderCache(
            sortedNodes: sortedNodes,
            semanticEdges: semanticEdges,
            entityCountByParent: entityCountByParent,
            conceptEntityGroups: conceptEntityGroups,
            nodeIDsWithChildren: nodeIDsWithChildren
        )
    }

    static func conceptEntityGroups(
        in graph: KnowledgeGraph,
        edges: [GraphEdge]? = nil
    ) -> [(concept: ConceptNode, entities: [ConceptNode])] {
        var entityIDsByConcept: [UUID: [UUID]] = [:]
        for edge in edges ?? graph.allEdges where edge.type == .containsEntity {
            entityIDsByConcept[edge.sourceNodeID, default: []].append(edge.targetNodeID)
        }
        guard !entityIDsByConcept.isEmpty else { return [] }

        return entityIDsByConcept.compactMap { conceptID, entityIDs in
            guard let conceptNode = graph.node(for: conceptID),
                  conceptNode.level == .concept else { return nil }
            let entityNodes = entityIDs.compactMap { graph.node(for: $0) }.filter { $0.level == .entity }
            guard !entityNodes.isEmpty else { return nil }
            return (conceptNode, entityNodes)
        }
        .sorted { $0.concept.label.localizedStandardCompare($1.concept.label) == .orderedAscending }
    }

    // MARK: - Edges

    private func drawEdges(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        for edge in renderCache.semanticEdges {
            guard let srcPos = layout.point(for: edge.sourceNodeID),
                  let tgtPos = layout.point(for: edge.targetNodeID) else { continue }
            let src = srcPos.applying(transform)
            let tgt = tgtPos.applying(transform)

            guard max(src.x, tgt.x) >= 0, min(src.x, tgt.x) <= size.width,
                  max(src.y, tgt.y) >= 0, min(src.y, tgt.y) <= size.height else { continue }

            // Curved edge
            var path = Path()
            let ctrl = Self.edgeControlPoint(from: src, to: tgt)
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

            let shouldDrawLabel = viewScale >= 0.85 || edge.sourceNodeID == selectedNodeID || edge.targetNodeID == selectedNodeID
            if shouldDrawLabel {
                drawEdgeLabel(
                    edge,
                    at: Self.edgeLabelPoint(from: src, control: ctrl, to: tgt, viewScale: viewScale),
                    directionAngle: Self.edgeTangentAngle(control: ctrl, target: tgt),
                    context: context,
                    viewScale: viewScale
                )
            }
        }
    }

    static func edgeControlPoint(from source: CGPoint, to target: CGPoint) -> CGPoint {
        let dx = target.x - source.x
        let dy = target.y - source.y
        return CGPoint(
            x: (source.x + target.x) / 2 - dy * 0.08,
            y: (source.y + target.y) / 2 + dx * 0.08
        )
    }

    static func quadraticPoint(from source: CGPoint, control: CGPoint, to target: CGPoint, t: CGFloat) -> CGPoint {
        let inverseT = 1 - t
        return CGPoint(
            x: inverseT * inverseT * source.x + 2 * inverseT * t * control.x + t * t * target.x,
            y: inverseT * inverseT * source.y + 2 * inverseT * t * control.y + t * t * target.y
        )
    }

    static func edgeLabelPoint(from source: CGPoint, control: CGPoint, to target: CGPoint, viewScale: CGFloat) -> CGPoint {
        let midpoint = quadraticPoint(from: source, control: control, to: target, t: 0.5)
        let chordMidpoint = CGPoint(x: (source.x + target.x) / 2, y: (source.y + target.y) / 2)
        let bow = CGPoint(x: midpoint.x - chordMidpoint.x, y: midpoint.y - chordMidpoint.y)
        let length = hypot(bow.x, bow.y)
        guard length > 0 else { return midpoint }

        let offset = max(4, 4 * viewScale)
        return CGPoint(
            x: midpoint.x + bow.x / length * offset,
            y: midpoint.y + bow.y / length * offset
        )
    }

    static func edgeTangentAngle(control: CGPoint, target: CGPoint) -> CGFloat {
        atan2(target.y - control.y, target.x - control.x)
    }

    private func drawEdgeLabel(
        _ edge: GraphEdge,
        at point: CGPoint,
        directionAngle: CGFloat,
        context: GraphicsContext,
        viewScale: CGFloat
    ) {
        let text = edgeDisplayText(edge)
        let fontSize = max(8, min(11, 10 * viewScale))
        let horizontalPadding = 6 * viewScale
        let verticalPadding = 3 * viewScale
        let width = min(150 * viewScale, max(44 * viewScale, CGFloat(text.count) * fontSize * 0.52 + horizontalPadding * 2))
        let height = fontSize + verticalPadding * 2
        let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)

        let path = Path(roundedRect: rect, cornerRadius: 5 * viewScale)
        context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.86)))
        context.stroke(path, with: .color(edge.type.color.opacity(0.45)), lineWidth: 0.8)

        let label = Text(text)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(edge.type.color)
        context.draw(context.resolve(label), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)

        let markerLength = max(7, 7 * viewScale)
        let markerPoint = CGPoint(x: rect.maxX + 4 * viewScale, y: rect.midY)
        var marker = Path()
        marker.move(to: markerPoint)
        marker.addLine(to: CGPoint(
            x: markerPoint.x - markerLength * cos(directionAngle - .pi / 6),
            y: markerPoint.y - markerLength * sin(directionAngle - .pi / 6)
        ))
        marker.move(to: markerPoint)
        marker.addLine(to: CGPoint(
            x: markerPoint.x - markerLength * cos(directionAngle + .pi / 6),
            y: markerPoint.y - markerLength * sin(directionAngle + .pi / 6)
        ))
        context.stroke(marker, with: .color(edge.type.color.opacity(0.7)), lineWidth: 1)
    }

    private func edgeDisplayText(_ edge: GraphEdge) -> String {
        edge.displayText(maxLength: 28)
    }

    // MARK: - Nodes

    private func drawNodes(context: GraphicsContext, transform: CGAffineTransform, size: CGSize) {
        for node in renderCache.sortedNodes {
            guard let pos = layout.point(for: node.id) else { continue }
            let tp = pos.applying(transform)

            let isSelected = node.id == selectedNodeID
            let isActive = node.id == activeNodeID
            let isHighlighted = highlightedNodeIDs.contains(node.id)
            let isDimmed = !highlightedNodeIDs.isEmpty && !isHighlighted && !isSelected
            let isConcept = node.level == .concept
            let isMultiDoc = node.sourceAnchors.contains { $0.documentURL != node.sourceAnchors.first?.documentURL }

            let hasSummary = node.summary != nil && viewScale >= 0.7
            let sizing = NodeSizing.forNodeLevel(node.level, hasSummary: hasSummary)
            let nodeW = sizing.baseWidth * viewScale
            let nodeH = sizing.baseHeight * viewScale
            let cr: CGFloat = 8 * viewScale

            let rect = CGRect(x: tp.x - nodeW / 2, y: tp.y - nodeH / 2, width: nodeW, height: nodeH)
            guard rect.maxX >= 0, rect.minX <= size.width, rect.maxY >= 0, rect.minY <= size.height else { continue }

            // Far zoom: dots only
            if viewScale < 0.35 {
                let ds: CGFloat = isDimmed ? 4 : sizing.dotSize
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
            else { bg = Color(nsColor: .controlBackgroundColor).opacity(sizing.bgOpacity) }

            let nodePath = Path(roundedRect: rect, cornerSize: CGSize(width: cr, height: cr))
            context.fill(nodePath, with: .color(bg.opacity(bgAlpha)))

            // Border
            let borderColor: Color
            if isSelected { borderColor = .accentColor }
            else if isHighlighted { borderColor = node.type.color }
            else if isMultiDoc { borderColor = .orange.opacity(0.6) }
            else { borderColor = isConcept ? node.type.color.opacity(0.4) : .gray.opacity(0.3) }

            let bw: CGFloat = isSelected || isHighlighted ? 2 : sizing.borderWidth
            if node.confidence < 0.6 {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), style: StrokeStyle(lineWidth: bw, dash: [4, 3]))
            } else if isMultiDoc {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), style: StrokeStyle(lineWidth: bw, dash: [6, 2]))
            } else {
                context.stroke(nodePath, with: .color(borderColor.opacity(bgAlpha)), lineWidth: bw)
            }

            guard viewScale >= 0.45 else { continue }

            // Type color strip on left
            let stripW: CGFloat = sizing.colorStripWidth * viewScale
            let stripPath = Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: stripW, height: rect.height),
                                 cornerSize: CGSize(width: cr, height: cr))
            context.fill(stripPath, with: .color(node.type.color.opacity(isDimmed ? 0.2 : 0.8)))

            // Label
            let fontSize = max(10, sizing.fontSize * viewScale)
            let fontWeight = sizing.fontWeight
            let labelX = rect.minX + stripW + 4 * viewScale
            let label = Text(node.label)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundColor(isDimmed ? .secondary.opacity(0.4) : .primary)
            context.draw(context.resolve(label), in: CGRect(x: labelX, y: rect.minY + 3 * viewScale, width: nodeW - stripW - 8 * viewScale, height: fontSize + 4))

            // Entity count badge for concept nodes
            if isConcept && viewScale >= 0.5 {
                let entityCount = renderCache.entityCountByParent[node.id] ?? 0
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

            // Expand/collapse chevron for nodes with children
            if isConcept && viewScale >= 0.5 && renderCache.nodeIDsWithChildren.contains(node.id) {
                let chevronName = node.expansionState == .expanded ? "chevron.down" : "chevron.right"
                let chevron = Text(Image(systemName: chevronName))
                    .font(.system(size: max(8, 10 * viewScale), weight: .semibold))
                    .foregroundColor(node.type.color.opacity(isDimmed ? 0.3 : 0.7))
                let chevronSize: CGFloat = 12 * viewScale
                let chevronRect = CGRect(x: rect.maxX - chevronSize - 3 * viewScale, y: rect.maxY - chevronSize - 3 * viewScale, width: chevronSize, height: chevronSize)
                context.draw(context.resolve(chevron), in: chevronRect)
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
