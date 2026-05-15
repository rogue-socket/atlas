//
//  DensityManager.swift
//  Atlas
//
//  Filters visible nodes based on semantic zoom level.
//

import Foundation

class DensityManager {

    /// Under the 4-level model the tab selector and the `NodeLevel` are
    /// the same axis. Each tab strictly shows nodes at its level; the
    /// renderer's selection/active overlay still calls attention to the
    /// active node when it happens to be at the visible level.
    func visibleNodes(
        from graph: KnowledgeGraph,
        zoomLevel: SemanticZoomLevel
    ) -> [ConceptNode] {
        let target: NodeLevel = nodeLevel(for: zoomLevel)
        return graph.allNodes.filter { $0.level == target }
    }

    private func nodeLevel(for zoomLevel: SemanticZoomLevel) -> NodeLevel {
        switch zoomLevel {
        case .document: return .document
        case .chapter:  return .chapter
        case .concept:  return .concept
        case .entity:   return .entity
        }
    }
}
