//
//  ChapterEdgeAggregation.swift
//  Atlas
//
//  Synthesises Chapter↔Chapter relational edges by aggregating
//  concept-level edges across chapter boundaries. Without this pass the
//  Chapter tab shows only isolated chapter nodes, which user testing
//  flagged as a usability gap (L2 in 2026-05-15 post-α bug report).
//

import Foundation

enum ChapterEdgeAggregation {

    /// Walk every non-containment edge between two concepts and emit an
    /// aggregated edge of the same type between every pair of chapters
    /// that contain them. Concepts may belong to multiple chapters (the
    /// 4-level model allows multi-parent), so a single concept edge can
    /// project to multiple chapter edges.
    ///
    /// Idempotent: dedupes against existing edges by
    /// `(source, target, type)` tuple, so calling multiple times during
    /// re-extraction is safe. Returns the number of new edges added.
    @discardableResult
    static func synthesize(in graph: KnowledgeGraph) -> Int {
        var pending: Set<EdgeTuple> = []
        for edge in graph.allEdges where !edge.type.isContainment {
            guard let source = graph.node(for: edge.sourceNodeID),
                  let target = graph.node(for: edge.targetNodeID),
                  source.level == .concept,
                  target.level == .concept
            else { continue }

            let sourceChapters = graph.parents(of: source.id, edgeType: .containsConcept)
            let targetChapters = graph.parents(of: target.id, edgeType: .containsConcept)
            for sCh in sourceChapters {
                for tCh in targetChapters where sCh.id != tCh.id {
                    pending.insert(EdgeTuple(source: sCh.id, target: tCh.id, type: edge.type))
                }
            }
        }

        let existing: Set<EdgeTuple> = Set(graph.allEdges.map { edge in
            EdgeTuple(source: edge.sourceNodeID, target: edge.targetNodeID, type: edge.type)
        })

        var added = 0
        for tuple in pending where !existing.contains(tuple) {
            let synthesized = GraphEdge(
                sourceNodeID: tuple.source,
                targetNodeID: tuple.target,
                type: tuple.type,
                confidence: 0.7,
                label: "aggregated"
            )
            graph.addEdge(synthesized)
            added += 1
        }
        return added
    }

    private struct EdgeTuple: Hashable {
        let source: UUID
        let target: UUID
        let type: EdgeType
    }
}
