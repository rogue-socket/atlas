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
            // One representative node per source document. Prefer the LLM-generated
            // document-summary node; fall back to the highest-degree root concept
            // (legacy graphs without a summary node still get a sensible pick).
            var byDoc: [String: [ConceptNode]] = [:]
            for node in allNodes {
                guard let doc = node.sourceAnchors.first?.documentURL.lastPathComponent else { continue }
                byDoc[doc, default: []].append(node)
            }
            return byDoc.values.compactMap { candidates in
                if let summary = candidates.first(where: { $0.isDocumentSummary }) {
                    return summary
                }
                let roots = candidates.filter { $0.hierarchyLevel == 0 && $0.level == .concept }
                if let best = roots.max(by: { graph.edges(for: $0.id).count < graph.edges(for: $1.id).count }) {
                    return best
                }
                return candidates.first
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
