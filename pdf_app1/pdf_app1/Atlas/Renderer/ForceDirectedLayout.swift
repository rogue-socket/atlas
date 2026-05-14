//
//  ForceDirectedLayout.swift
//  Atlas
//
//  Fruchterman-Reingold force-directed graph layout with
//  grouping by concept type and overlap prevention.
//

import Foundation
import CoreGraphics
import Observation

struct NodePosition {
    var x: Double
    var y: Double
    var velocityX: Double = 0
    var velocityY: Double = 0
    var isFixed: Bool = false
    var group: String = ""
}

@Observable
class ForceDirectedLayout {
    var positions: [UUID: NodePosition] = [:]
    var isConverged: Bool = false
    var iteration: Int = 0

    // Tuned for readability — nodes stay well-separated
    private let repulsionConstant: Double = 25000
    private let attractionConstant: Double = 0.005
    private let groupAttractionConstant: Double = 0.002
    private let parentAttractionConstant: Double = 0.006 // entities pulled toward parent concept (3x group)
    private let dampingFactor: Double = 0.8
    private let minMovement: Double = 0.3
    private let maxIterations: Int
    private let nodeSpacing: Double = 180 // minimum pixel distance between node centers

    init(maxIterations: Int = AppConstants.layoutMaxIterations) {
        self.maxIterations = maxIterations
    }

    // MARK: - Layout

    func computeLayout(
        nodes: [ConceptNode],
        edges: [GraphEdge],
        canvasSize: CGSize,
        anchorNodes: [UUID: CGPoint] = [:]
    ) {
        guard !nodes.isEmpty else { return }

        // Use a large virtual canvas so nodes aren't cramped
        let virtualSize = CGSize(
            width: max(canvasSize.width, Double(nodes.count) * 120),
            height: max(canvasSize.height, Double(nodes.count) * 90)
        )

        // Build the canonical-parent forest from concept nodes + subtopicOf
        // edges. If the data has hierarchy (any subtopicOf), seed positions
        // as horizontal bands by `hierarchyLevel`. Otherwise the seeder is
        // skipped and we fall back to the grid-of-singletons placement.
        let conceptNodes = nodes.filter { $0.level == .concept }
        let forest = HierarchyForest.build(conceptNodes: conceptNodes, edges: edges)
        let useTreeSeeding = !forest.isDegenerate

        let hierarchyLevelByID: [UUID: Int] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.hierarchyLevel) })
        let seedPositions: [UUID: CGPoint] = useTreeSeeding
            ? TreeLayoutSeeder(canvasSize: virtualSize).seed(forest: forest) { hierarchyLevelByID[$0] ?? 0 }
            : [:]

        // Concept nodes share a group with their subtree root (so FDL's
        // group attraction pulls a subtree together as a cluster).
        // Entities group under their parent concept (unchanged behavior).
        func groupKey(for node: ConceptNode) -> String {
            if node.level == .entity, let parentID = node.parentConceptID {
                return parentID.uuidString
            }
            if useTreeSeeding {
                return forest.root(of: node.id).uuidString
            }
            return node.id.uuidString
        }

        let groups = Dictionary(grouping: nodes, by: { groupKey(for: $0) })
        let groupNames = groups.keys.sorted()
        var groupCenters: [String: CGPoint] = [:]

        // Tree-seeded groups: center on the seeded subtree-root position.
        // Entity groups + ungrouped concepts: fall through to grid below.
        if useTreeSeeding {
            for (key, members) in groups {
                if let rootUUID = UUID(uuidString: key), let rootPos = seedPositions[rootUUID] {
                    groupCenters[key] = rootPos
                } else {
                    // Entity group: average of any seeded member positions
                    let seeded = members.compactMap { seedPositions[$0.id] }
                    if !seeded.isEmpty {
                        let avgX = seeded.map(\.x).reduce(0, +) / Double(seeded.count)
                        let avgY = seeded.map(\.y).reduce(0, +) / Double(seeded.count)
                        groupCenters[key] = CGPoint(x: avgX, y: avgY)
                    }
                }
            }
        }

        // Grid fallback for any group still missing a center (degenerate
        // forest, entity-only groups whose parent wasn't seeded, etc.)
        if groupCenters.count < groupNames.count {
            let cols = max(Int(ceil(sqrt(Double(groupNames.count)))), 2)
            let cellW = virtualSize.width / Double(cols + 1)
            let cellH = virtualSize.height / Double(max(groupNames.count / cols + 1, 2))
            for (i, name) in groupNames.enumerated() where groupCenters[name] == nil {
                let col = i % cols
                let row = i / cols
                groupCenters[name] = CGPoint(
                    x: cellW * (Double(col) + 1),
                    y: cellH * (Double(row) + 1)
                )
            }
        }

        // Initialize positions
        for node in nodes {
            let gk = groupKey(for: node)
            if positions[node.id] == nil {
                if let anchor = anchorNodes[node.id] {
                    positions[node.id] = NodePosition(x: anchor.x, y: anchor.y, isFixed: true, group: gk)
                } else if let existing = node.position {
                    positions[node.id] = NodePosition(x: existing.x, y: existing.y, group: gk)
                } else if let seed = seedPositions[node.id] {
                    // Tree-seeded concept: small jitter so FDL has a gradient
                    let jitterX = Double.random(in: -20...20)
                    let jitterY = Double.random(in: -20...20)
                    positions[node.id] = NodePosition(x: seed.x + jitterX, y: seed.y + jitterY, group: gk)
                } else {
                    // Group-center placement (entities, or no-hierarchy fallback)
                    let center = groupCenters[gk] ?? CGPoint(x: virtualSize.width / 2, y: virtualSize.height / 2)
                    let jitterX = Double.random(in: -80...80)
                    let jitterY = Double.random(in: -80...80)
                    positions[node.id] = NodePosition(x: center.x + jitterX, y: center.y + jitterY, group: gk)
                }
            } else {
                positions[node.id]?.group = gk
            }
        }

        let nodeIDs = Set(nodes.map { $0.id })
        positions = positions.filter { nodeIDs.contains($0.key) }

        isConverged = false
        iteration = 0
        let k = max(nodeSpacing, sqrt(virtualSize.width * virtualSize.height / Double(nodes.count)))

        for _ in 0..<maxIterations {
            iteration += 1
            let totalMovement = runIteration(nodes: nodes, edges: edges, k: k, virtualSize: virtualSize, groupCenters: groupCenters)
            if totalMovement < minMovement * Double(nodes.count) {
                isConverged = true
                break
            }
        }

        // Post-process: resolve remaining overlaps. First per-node (no two
        // nodes too close); then per-cluster (no two concept-plus-entities
        // bounding boxes overlap, since the renderer draws each cluster as
        // a labeled rectangle and overlap there is the most visible mess).
        resolveOverlaps(nodes: nodes)
        resolveClusterOverlaps(nodes: nodes)
    }

    private func runIteration(
        nodes: [ConceptNode],
        edges: [GraphEdge],
        k: Double,
        virtualSize: CGSize,
        groupCenters: [String: CGPoint]
    ) -> Double {
        let temperature = Double(maxIterations - iteration) / Double(maxIterations) * k * 2

        var forces: [UUID: (dx: Double, dy: Double)] = [:]
        for node in nodes { forces[node.id] = (0, 0) }

        // Repulsive forces — exact pairwise for small graphs, Barnes-Hut otherwise
        let repulsion = repulsionForces(nodes: nodes)
        for node in nodes {
            forces[node.id]?.dx += repulsion[node.id]?.dx ?? 0
            forces[node.id]?.dy += repulsion[node.id]?.dy ?? 0
        }

        // Attractive forces along edges
        for edge in edges {
            guard let posS = positions[edge.sourceNodeID], let posT = positions[edge.targetNodeID] else { continue }
            let dx = posT.x - posS.x
            let dy = posT.y - posS.y
            let dist = max(sqrt(dx * dx + dy * dy), 1)
            let force = attractionConstant * dist * dist / k
            let fx = (dx / dist) * force
            let fy = (dy / dist) * force
            forces[edge.sourceNodeID]?.dx += fx
            forces[edge.sourceNodeID]?.dy += fy
            forces[edge.targetNodeID]?.dx -= fx
            forces[edge.targetNodeID]?.dy -= fy
        }

        // Group attraction — pull nodes toward their group center
        for node in nodes {
            guard let pos = positions[node.id],
                  let center = groupCenters[pos.group] else { continue }
            let dx = center.x - pos.x
            let dy = center.y - pos.y

            // Entities get stronger pull toward their parent concept
            let strength = (node.level == .entity && node.parentConceptID != nil)
                ? parentAttractionConstant
                : groupAttractionConstant
            forces[node.id]?.dx += dx * strength
            forces[node.id]?.dy += dy * strength
        }

        // Direct parent-entity attraction: pull entities toward their parent's position
        for node in nodes where node.level == .entity {
            guard let parentID = node.parentConceptID,
                  let entityPos = positions[node.id],
                  let parentPos = positions[parentID] else { continue }
            let dx = parentPos.x - entityPos.x
            let dy = parentPos.y - entityPos.y
            forces[node.id]?.dx += dx * parentAttractionConstant
            forces[node.id]?.dy += dy * parentAttractionConstant
        }

        // Apply
        var totalMovement: Double = 0
        for node in nodes {
            guard var pos = positions[node.id], !pos.isFixed, let force = forces[node.id] else { continue }
            let mag = max(sqrt(force.dx * force.dx + force.dy * force.dy), 1)
            let ldx = (force.dx / mag) * min(mag, temperature)
            let ldy = (force.dy / mag) * min(mag, temperature)
            pos.velocityX = (pos.velocityX + ldx) * dampingFactor
            pos.velocityY = (pos.velocityY + ldy) * dampingFactor
            pos.x += pos.velocityX
            pos.y += pos.velocityY
            totalMovement += abs(pos.velocityX) + abs(pos.velocityY)
            positions[node.id] = pos
        }
        return totalMovement
    }

    /// Pick exact O(n²) pairwise repulsion for small graphs, or Barnes-Hut quadtree above
    /// `AppConstants.barnesHutThreshold`.
    private func repulsionForces(nodes: [ConceptNode]) -> [UUID: (dx: Double, dy: Double)] {
        if nodes.count < AppConstants.barnesHutThreshold {
            return exactRepulsion(nodes: nodes)
        }
        let bodies = nodes.compactMap { node -> (id: UUID, position: CGPoint)? in
            guard let p = positions[node.id] else { return nil }
            return (node.id, CGPoint(x: p.x, y: p.y))
        }
        let tree = BarnesHutQuadTree(bodies: bodies)
        var out: [UUID: (dx: Double, dy: Double)] = [:]
        out.reserveCapacity(bodies.count)
        for body in bodies {
            let f = tree.force(
                on: body.id,
                at: body.position,
                theta: AppConstants.barnesHutTheta,
                repulsionConstant: repulsionConstant
            )
            out[body.id] = (Double(f.dx), Double(f.dy))
        }
        return out
    }

    private func exactRepulsion(nodes: [ConceptNode]) -> [UUID: (dx: Double, dy: Double)] {
        var out: [UUID: (dx: Double, dy: Double)] = [:]
        for node in nodes { out[node.id] = (0, 0) }
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                guard let posA = positions[nodes[i].id], let posB = positions[nodes[j].id] else { continue }
                let dx = posA.x - posB.x
                let dy = posA.y - posB.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let force = repulsionConstant / (dist * dist)
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                out[nodes[i].id]?.dx += fx
                out[nodes[i].id]?.dy += fy
                out[nodes[j].id]?.dx -= fx
                out[nodes[j].id]?.dy -= fy
            }
        }
        return out
    }

    /// Push apart any concept clusters (concept + its entities, the
    /// rectangle drawn by `MapCanvasRenderer.drawGroupBackgrounds`)
    /// whose bounding boxes overlap. Each cluster moves as a rigid
    /// unit — concept node and entities translate together — so
    /// intra-cluster structure from FDL is preserved.
    ///
    /// Padding matches the renderer's draw padding (40 horizontal,
    /// 30 top, 50 bottom) so the resolved bboxes correspond to what
    /// the user actually sees.
    func resolveClusterOverlaps(nodes: [ConceptNode]) {
        let conceptNodes = nodes.filter { $0.level == .concept }
        guard conceptNodes.count >= 2 else { return }

        // entityIDsByParent: for each concept, the IDs of its entities
        var entityIDsByParent: [UUID: [UUID]] = [:]
        for node in nodes where node.level == .entity {
            if let parentID = node.parentConceptID {
                entityIDsByParent[parentID, default: []].append(node.id)
            }
        }

        func memberIDs(of conceptID: UUID) -> [UUID] {
            [conceptID] + (entityIDsByParent[conceptID] ?? [])
        }

        func clusterBBox(of conceptID: UUID) -> CGRect? {
            let members = memberIDs(of: conceptID)
            let pts = members.compactMap { positions[$0] }
            guard !pts.isEmpty else { return nil }
            let xs = pts.map(\.x)
            let ys = pts.map(\.y)
            // Padding matches MapCanvasRenderer.drawGroupBackgrounds
            // before viewScale is applied (we work in virtual coords).
            let minX = xs.min()! - 40
            let maxX = xs.max()! + 40
            let minY = ys.min()! - 30
            let maxY = ys.max()! + 50
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        func shiftCluster(_ conceptID: UUID, by delta: CGPoint) {
            for id in memberIDs(of: conceptID) {
                guard var pos = positions[id], !pos.isFixed else { continue }
                pos.x += delta.x
                pos.y += delta.y
                positions[id] = pos
            }
        }

        let conceptIDs = conceptNodes.map(\.id)

        for _ in 0..<30 {
            var anyOverlap = false

            // Recompute bboxes each iteration since clusters shift
            var bboxes: [UUID: CGRect] = [:]
            for id in conceptIDs {
                if let bbox = clusterBBox(of: id) {
                    bboxes[id] = bbox
                }
            }

            for i in 0..<conceptIDs.count {
                for j in (i + 1)..<conceptIDs.count {
                    let idA = conceptIDs[i]
                    let idB = conceptIDs[j]
                    guard let bboxA = bboxes[idA], let bboxB = bboxes[idB] else { continue }
                    guard bboxA.intersects(bboxB) else { continue }
                    anyOverlap = true

                    // Push along axis from B's center to A's center.
                    // Magnitude = half the overlap on the dominant axis,
                    // plus a small gap. Each cluster moves half the distance.
                    let aCenter = CGPoint(x: bboxA.midX, y: bboxA.midY)
                    let bCenter = CGPoint(x: bboxB.midX, y: bboxB.midY)
                    var dx = aCenter.x - bCenter.x
                    var dy = aCenter.y - bCenter.y
                    let mag = sqrt(dx * dx + dy * dy)
                    if mag < 1 {
                        // Centers coincide — push along an arbitrary axis
                        dx = 1; dy = 0
                    } else {
                        dx /= mag
                        dy /= mag
                    }

                    let overlap = bboxA.intersection(bboxB)
                    let pushAmount = max(overlap.width, overlap.height) / 2 + 10
                    let pushA = CGPoint(x: dx * pushAmount, y: dy * pushAmount)
                    let pushB = CGPoint(x: -dx * pushAmount, y: -dy * pushAmount)

                    shiftCluster(idA, by: pushA)
                    shiftCluster(idB, by: pushB)

                    // Refresh affected bboxes so subsequent comparisons in
                    // this iteration use up-to-date positions.
                    if let newA = clusterBBox(of: idA) { bboxes[idA] = newA }
                    if let newB = clusterBBox(of: idB) { bboxes[idB] = newB }
                }
            }

            if !anyOverlap { break }
        }
    }

    /// Push apart any nodes that are still overlapping after layout
    private func resolveOverlaps(nodes: [ConceptNode]) {
        let minDist = nodeSpacing * 0.8
        for _ in 0..<20 {
            var anyOverlap = false
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    guard var posA = positions[nodes[i].id], var posB = positions[nodes[j].id] else { continue }
                    let dx = posA.x - posB.x
                    let dy = posA.y - posB.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < minDist && dist > 0 {
                        anyOverlap = true
                        let push = (minDist - dist) / 2
                        let nx = dx / dist
                        let ny = dy / dist
                        if !posA.isFixed { posA.x += nx * push; posA.y += ny * push; positions[nodes[i].id] = posA }
                        if !posB.isFixed { posB.x -= nx * push; posB.y -= ny * push; positions[nodes[j].id] = posB }
                    }
                }
            }
            if !anyOverlap { break }
        }
    }

    // MARK: - Accessors

    func point(for nodeID: UUID) -> CGPoint? {
        guard let pos = positions[nodeID] else { return nil }
        return CGPoint(x: pos.x, y: pos.y)
    }

    func setPosition(_ point: CGPoint, for nodeID: UUID) {
        positions[nodeID]?.x = point.x
        positions[nodeID]?.y = point.y
    }

    func setFixed(_ fixed: Bool, for nodeID: UUID) {
        positions[nodeID]?.isFixed = fixed
    }

    func addNodeIncrementally(_ node: ConceptNode, near neighborID: UUID?, canvasSize: CGSize) {
        if let neighborID, let neighborPos = positions[neighborID] {
            let offset = Double.random(in: -80...80)
            positions[node.id] = NodePosition(x: neighborPos.x + offset, y: neighborPos.y + offset, group: node.type.rawValue)
        } else {
            let x = Double.random(in: 100...(canvasSize.width - 100))
            let y = Double.random(in: 100...(canvasSize.height - 100))
            positions[node.id] = NodePosition(x: x, y: y, group: node.type.rawValue)
        }
    }
}
