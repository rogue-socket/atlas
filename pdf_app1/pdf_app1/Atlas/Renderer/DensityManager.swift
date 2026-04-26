//
//  DensityManager.swift
//  Atlas
//
//  Filters visible nodes based on semantic zoom level.
//

import Foundation

class DensityManager {

    func visibleNodes(
        from graph: KnowledgeGraph,
        zoomLevel: SemanticZoomLevel,
        activeNodeID: UUID? = nil
    ) -> [ConceptNode] {
        let allNodes = graph.allNodes
        guard !allNodes.isEmpty else { return [] }

        switch zoomLevel {
        case .document:
            // One node per source document
            var seen = Set<String>()
            return allNodes.filter { node in
                guard let doc = node.sourceAnchors.first?.documentURL.lastPathComponent else { return false }
                if seen.contains(doc) { return false }
                seen.insert(doc)
                return true
            }

        case .chapter:
            // Only definitions, high-confidence concepts, and pinned nodes
            return allNodes.filter { node in
                node.type == .definition || node.type == .theorem ||
                node.isPinned || node.id == activeNodeID ||
                node.confidence >= 0.9 ||
                graph.degree(of: node.id) >= 3
            }

        case .concept:
            // All nodes (default view)
            return allNodes

        case .passage:
            // All nodes — at passage level we show everything including low confidence
            return allNodes
        }
    }
}
