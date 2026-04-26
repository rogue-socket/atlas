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
            // Concept-level nodes only (all collapsed)
            return allNodes.filter { node in
                node.level == .concept ||
                node.isPinned || node.id == activeNodeID
            }

        case .concept:
            // Concepts + entities of expanded concepts
            return allNodes.filter { node in
                if node.level == .concept { return true }
                if node.isPinned || node.id == activeNodeID { return true }
                // Show entity only if its parent concept is expanded
                guard let parentID = node.parentConceptID,
                      let parent = graph.node(for: parentID) else { return false }
                return parent.expansionState == .expanded
            }

        case .entity:
            // Everything — auto-expand all
            return allNodes
        }
    }
}
