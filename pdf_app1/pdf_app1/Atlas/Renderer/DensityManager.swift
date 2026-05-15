//
//  DensityManager.swift
//  Atlas
//
//  Filters visible nodes based on semantic zoom level.
//

import Foundation

class DensityManager {

    /// Under the 4-level model the tab selector and the `NodeLevel` are
    /// the same axis. Filtering reduces to "show nodes at this level,"
    /// plus pinned and active-node carve-outs so navigation works across
    /// levels.
    func visibleNodes(
        from graph: KnowledgeGraph,
        zoomLevel: SemanticZoomLevel,
        activeNodeID: UUID? = nil
    ) -> [ConceptNode] {
        let target: NodeLevel = nodeLevel(for: zoomLevel)
        return graph.allNodes.filter { node in
            if node.isPinned || node.id == activeNodeID { return true }
            return node.level == target
        }
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
