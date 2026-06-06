//
//  EmbeddingMergeApplier.swift
//  Atlas
//
//  ETR stage 4 — apply a `MergePlan` to a `KnowledgeGraph`.
//
//  The plan is a list of pairwise merge decisions. Transitive closure is
//  taken here via union-find — three pairs (A,B), (B,C), (C,D) collapse to
//  a single group {A,B,C,D} with one canonical survivor.
//
//  Canonical pick rule (per PRD §"Approach 2"):
//   1. Higher `NodeLevel` wins (concept > entity). Document/chapter never
//      appear because the resolver filters them out, but the level enum
//      is ordered anyway.
//   2. Tie-break by oldest `lastModified` — preserve the original node
//      over later additions that got rolled into it.
//   3. Final tie-break by lowest UUID string for full determinism.
//
//  After picking canonical: union source anchors, rewrite all edge
//  endpoints, dedup edges by (source, target, type) keeping the
//  highest-confidence survivor, then remove the merged-away nodes.
//

import Foundation
import os.log

private let log = AtlasLogger.embedding

enum EmbeddingMergeApplier {

    struct ApplyResult: Equatable {
        let groupsApplied: Int
        let nodesRemoved: Int
        let edgesRewritten: Int
        let edgesDeduplicated: Int
        let relationsAdded: Int

        init(groupsApplied: Int, nodesRemoved: Int, edgesRewritten: Int,
             edgesDeduplicated: Int, relationsAdded: Int = 0) {
            self.groupsApplied = groupsApplied
            self.nodesRemoved = nodesRemoved
            self.edgesRewritten = edgesRewritten
            self.edgesDeduplicated = edgesDeduplicated
            self.relationsAdded = relationsAdded
        }
    }

    /// Apply `plan` to `graph` in place. Returns counts for the audit log.
    @discardableResult
    static func apply(_ plan: MergePlan, to graph: KnowledgeGraph) -> ApplyResult {
        guard !plan.decisions.isEmpty || !plan.relations.isEmpty else {
            return ApplyResult(groupsApplied: 0, nodesRemoved: 0, edgesRewritten: 0, edgesDeduplicated: 0)
        }

        // 1. Union-find over all merged node IDs.
        var parent: [UUID: UUID] = [:]
        func find(_ x: UUID) -> UUID {
            var root = x
            while let p = parent[root], p != root { root = p }
            // Path compression.
            var cur = x
            while let p = parent[cur], p != root {
                parent[cur] = root
                cur = p
            }
            return root
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a); let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for d in plan.decisions {
            if parent[d.aID] == nil { parent[d.aID] = d.aID }
            if parent[d.bID] == nil { parent[d.bID] = d.bID }
            union(d.aID, d.bID)
        }

        // 2. Bucket member IDs by group root.
        var groups: [UUID: [UUID]] = [:]
        for nodeID in parent.keys {
            groups[find(nodeID), default: []].append(nodeID)
        }

        // 3. Pick canonical per group + build idRemap. No graph mutation yet —
        //    we need the edges intact for the rewrite pass below.
        var idRemap: [UUID: UUID] = [:]
        var canonicalUpdates: [ConceptNode] = []
        for (_, members) in groups {
            guard members.count >= 2 else { continue }
            let memberNodes = members.compactMap { graph.nodes[$0] }
            guard let canonical = pickCanonical(from: memberNodes) else { continue }

            // Combine source anchors from all members into the canonical.
            var merged = canonical
            var allAnchors = canonical.sourceAnchors
            var anchorKeys = Set(allAnchors.map(anchorDedupKey))
            for node in memberNodes where node.id != canonical.id {
                for anchor in node.sourceAnchors {
                    let key = anchorDedupKey(anchor)
                    if !anchorKeys.contains(key) {
                        allAnchors.append(anchor)
                        anchorKeys.insert(key)
                    }
                }
                idRemap[node.id] = canonical.id
            }
            merged.sourceAnchors = allAnchors
            merged.lastModified = Date()
            canonicalUpdates.append(merged)
        }

        // 4. Snapshot edges + clear them from the graph. `removeNode` cascades
        //    to delete connected edges, so we must take the snapshot BEFORE
        //    any node removal (otherwise the loser-node edges vanish before
        //    we get a chance to rewrite their endpoints to the canonical).
        let edgesSnapshot = graph.allEdges
        for edge in edgesSnapshot {
            graph.removeEdge(edge.id)
        }

        // 5. Apply canonical updates + drop loser nodes.
        var nodesRemoved = 0
        for canonical in canonicalUpdates {
            graph.updateNode(canonical)
        }
        for loserID in idRemap.keys {
            graph.removeNode(loserID)
            nodesRemoved += 1
        }

        // 6. Re-add edges with rewritten endpoints, deduping by
        //    (source, target, type) — keep the highest-confidence survivor.
        struct EdgeKey: Hashable { let s: UUID; let t: UUID; let type: EdgeType }
        var byKey: [EdgeKey: GraphEdge] = [:]
        var rewritten = 0
        var dedupedRemovals = 0
        for edge in edgesSnapshot {
            let newSource = idRemap[edge.sourceNodeID] ?? edge.sourceNodeID
            let newTarget = idRemap[edge.targetNodeID] ?? edge.targetNodeID
            if newSource == newTarget { continue } // self-edge after merge — drop
            if newSource != edge.sourceNodeID || newTarget != edge.targetNodeID {
                rewritten += 1
            }
            var rewrittenEdge = edge
            rewrittenEdge.sourceNodeID = newSource
            rewrittenEdge.targetNodeID = newTarget

            let key = EdgeKey(s: newSource, t: newTarget, type: edge.type)
            if let existing = byKey[key] {
                if rewrittenEdge.confidence > existing.confidence {
                    byKey[key] = rewrittenEdge
                }
                dedupedRemovals += 1
            } else {
                byKey[key] = rewrittenEdge
            }
        }
        // 7. Materialize hybrid typed relations as new directed edges. Remap
        //    endpoints through idRemap (a relation node may have merged away),
        //    drop self-relations and endpoints that no longer exist, and dedup
        //    against the rewritten edges by (source, target, type).
        var relationsAdded = 0
        for rel in plan.relations {
            let s = idRemap[rel.sourceID] ?? rel.sourceID
            let t = idRemap[rel.targetID] ?? rel.targetID
            if s == t { continue }
            guard graph.nodes[s] != nil, graph.nodes[t] != nil else { continue }
            let key = EdgeKey(s: s, t: t, type: rel.edgeType)
            if byKey[key] == nil {
                byKey[key] = GraphEdge(sourceNodeID: s, targetNodeID: t, type: rel.edgeType,
                                       confidence: Double(rel.similarity), label: "etr-relation")
                relationsAdded += 1
            }
        }

        for edge in byKey.values {
            graph.addEdge(edge)
        }

        let result = ApplyResult(
            groupsApplied: groups.values.filter { $0.count >= 2 }.count,
            nodesRemoved: nodesRemoved,
            edgesRewritten: rewritten,
            edgesDeduplicated: dedupedRemovals,
            relationsAdded: relationsAdded
        )
        log.info("[ETR] applied: \(result.groupsApplied) groups, removed \(result.nodesRemoved) nodes, rewrote \(result.edgesRewritten) edges, deduplicated \(result.edgesDeduplicated), added \(result.relationsAdded) typed relations")
        return result
    }

    // MARK: - Helpers (internal for unit testing)

    /// Canonical pick: highest level → oldest lastModified → lowest UUID.
    static func pickCanonical(from nodes: [ConceptNode]) -> ConceptNode? {
        nodes.min { a, b in
            // Higher level wins, so reverse the comparison: lower in min means "better."
            let la = levelRank(a.level)
            let lb = levelRank(b.level)
            if la != lb { return la > lb }   // higher rank ⇒ should be canonical
            if a.lastModified != b.lastModified { return a.lastModified < b.lastModified }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Rank with `concept` > `entity` > `chapter` > `document`. Document and
    /// chapter shouldn't appear in plans (resolver filters them out), but the
    /// ordering exists for safety.
    private static func levelRank(_ level: NodeLevel) -> Int {
        switch level {
        case .concept: return 4
        case .entity:  return 3
        case .chapter: return 2
        case .document: return 1
        }
    }

    /// Stable dedup key for source anchors. Page + document URL + bounding-box
    /// origin is granular enough to avoid collapsing distinct hits, coarse
    /// enough to dedup the common case where the same node is re-emitted
    /// across batches with the same anchor.
    private static func anchorDedupKey(_ anchor: SourceAnchor) -> String {
        "\(anchor.documentURL.absoluteString)#\(anchor.pageIndex)@\(Int(anchor.boundingBox.origin.x)),\(Int(anchor.boundingBox.origin.y))"
    }
}
