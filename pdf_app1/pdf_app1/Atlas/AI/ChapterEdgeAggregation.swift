//
//  ChapterEdgeAggregation.swift
//  Atlas
//
//  Synthesises Chapter↔Chapter and Document↔Document relational edges by
//  aggregating concept- and entity-level edges across hierarchy boundaries.
//  Without this pass the higher-level tabs show isolated nodes, which user
//  testing flagged as a usability gap (L2 in 2026-05-15 post-α bug report).
//

import Foundation

enum ChapterEdgeAggregation {

    /// Walk every non-containment edge between concepts and/or entities
    /// and emit an aggregated edge of the same type between every pair of
    /// chapters and documents that contain them. Concepts may belong to
    /// multiple chapters (the 4-level model allows multi-parent), so a single
    /// semantic edge can project to multiple higher-level edges.
    ///
    /// Idempotent: dedupes against existing edges by
    /// `(source, target, type)` tuple, so calling multiple times during
    /// re-extraction is safe. Returns the number of new edges added.
    @discardableResult
    static func synthesize(in graph: KnowledgeGraph) -> Int {
        var pending: [EdgeTuple: [GraphEdge]] = [:]
        for edge in graph.allEdges where !edge.type.isContainment {
            guard let source = graph.node(for: edge.sourceNodeID),
                  let target = graph.node(for: edge.targetNodeID),
                  source.level == .concept || source.level == .entity,
                  target.level == .concept || target.level == .entity
            else { continue }

            let sourceChapters = parentChapters(for: source, in: graph)
            let targetChapters = parentChapters(for: target, in: graph)
            for sCh in sourceChapters {
                for tCh in targetChapters where sCh.id != tCh.id {
                    let tuple = EdgeTuple(source: sCh.id, target: tCh.id, type: edge.type)
                    pending[tuple, default: []].append(edge)
                }
            }

            let sourceDocuments = parentDocuments(for: sourceChapters, in: graph)
            let targetDocuments = parentDocuments(for: targetChapters, in: graph)
            for sDoc in sourceDocuments {
                for tDoc in targetDocuments where sDoc.id != tDoc.id {
                    let tuple = EdgeTuple(source: sDoc.id, target: tDoc.id, type: edge.type)
                    pending[tuple, default: []].append(edge)
                }
            }
        }

        let existingByTuple = Dictionary(
            graph.allEdges.map { edge in
                (EdgeTuple(source: edge.sourceNodeID, target: edge.targetNodeID, type: edge.type), edge)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var added = 0
        for (tuple, childEdges) in pending {
            let label = rollupLabel(for: childEdges)
            if let existing = existingByTuple[tuple] {
                if isRefreshableRollupEdge(existing), existing.label != label {
                    var updated = existing
                    updated.label = label
                    graph.removeEdge(existing.id)
                    graph.addEdge(updated)
                }
                continue
            }

            let synthesized = GraphEdge(
                sourceNodeID: tuple.source,
                targetNodeID: tuple.target,
                type: tuple.type,
                confidence: 0.7,
                label: label
            )
            graph.addEdge(synthesized)
            added += 1
        }
        return added
    }

    private static func parentChapters(for node: ConceptNode, in graph: KnowledgeGraph) -> [ConceptNode] {
        switch node.level {
        case .concept:
            return graph.parents(of: node.id, edgeType: .containsConcept)
        case .entity:
            let parentConcepts = graph.parents(of: node.id, edgeType: .containsEntity)
            var seen: Set<UUID> = []
            return parentConcepts.flatMap { concept in
                graph.parents(of: concept.id, edgeType: .containsConcept)
            }
            .filter { seen.insert($0.id).inserted }
        default:
            return []
        }
    }

    private static func parentDocuments(for chapters: [ConceptNode], in graph: KnowledgeGraph) -> [ConceptNode] {
        var seen: Set<UUID> = []
        return chapters.flatMap { chapter in
            graph.parents(of: chapter.id, edgeType: .containsChapter)
        }
        .filter { seen.insert($0.id).inserted }
    }

    private struct EdgeTuple: Hashable {
        let source: UUID
        let target: UUID
        let type: EdgeType
    }

    private static func rollupLabel(for childEdges: [GraphEdge]) -> String {
        guard let first = childEdges.first else { return "rollup" }

        if childEdges.count == 1 {
            return "rolls up: \(relationText(for: first, maxLength: 42))"
        }

        let labels = Set(childEdges.map { relationText(for: $0, maxLength: nil) })
        if labels.count == 1, let label = labels.first {
            return "aggregates \(childEdges.count): \(truncated(label, maxLength: 34))"
        }

        return "aggregates \(childEdges.count) \(first.type.displayName.lowercased()) links"
    }

    private static func isRefreshableRollupEdge(_ edge: GraphEdge) -> Bool {
        let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label == "aggregated" || label.hasPrefix("rolls up:") || label.hasPrefix("aggregates ")
    }

    private static func relationText(for edge: GraphEdge, maxLength: Int?) -> String {
        let trimmed = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed?.isEmpty == false ? trimmed! : edge.type.displayName.lowercased()
        return truncated(text, maxLength: maxLength)
    }

    private static func truncated(_ text: String, maxLength: Int?) -> String {
        guard let maxLength, text.count > maxLength, maxLength > 3 else { return text }
        return String(text.prefix(maxLength - 3)) + "..."
    }
}
