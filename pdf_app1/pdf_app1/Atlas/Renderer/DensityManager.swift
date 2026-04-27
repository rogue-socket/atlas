//
//  DensityManager.swift
//  Atlas
//
//  Filters visible nodes based on semantic zoom level.
//

import Foundation

class DensityManager {

    private func subtopicParents(of nodeID: UUID, in graph: KnowledgeGraph) -> [ConceptNode] {
        graph.edges(for: nodeID).compactMap { edge in
            guard edge.type == .subtopicOf, edge.sourceNodeID == nodeID else { return nil }
            return graph.node(for: edge.targetNodeID)
        }
    }

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
            // Level-0 nodes always visible; sub-concepts visible if any parent is expanded
            return allNodes.filter { node in
                if node.isPinned || node.id == activeNodeID { return true }
                if node.hierarchyLevel == 0 { return true }
                // Sub-concept: visible if any subtopicOf parent is expanded
                if node.hierarchyLevel > 0 {
                    let parents = subtopicParents(of: node.id, in: graph)
                    if parents.contains(where: { $0.expansionState == .expanded }) { return true }
                }
                // Entity: visible if its parentConceptID is expanded
                if node.level == .entity {
                    guard let parentID = node.parentConceptID,
                          let parent = graph.node(for: parentID) else { return false }
                    return parent.expansionState == .expanded
                }
                return false
            }

        case .entity:
            // Everything — auto-expand all
            return allNodes
        }
    }
}
