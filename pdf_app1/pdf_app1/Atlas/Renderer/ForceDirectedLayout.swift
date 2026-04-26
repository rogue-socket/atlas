//
//  ForceDirectedLayout.swift
//  Atlas
//
//  Fruchterman-Reingold force-directed graph layout with
//  grouping by concept type and overlap prevention.
//

import Foundation
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

        // Group by hierarchy: concept nodes are their own group, entities group under parent
        func groupKey(for node: ConceptNode) -> String {
            if node.level == .entity, let parentID = node.parentConceptID {
                return parentID.uuidString
            }
            return node.id.uuidString
        }

        let groups = Dictionary(grouping: nodes, by: { groupKey(for: $0) })
        let groupNames = groups.keys.sorted()
        var groupCenters: [String: CGPoint] = [:]
        let cols = max(Int(ceil(sqrt(Double(groupNames.count)))), 2)
        let cellW = virtualSize.width / Double(cols + 1)
        let cellH = virtualSize.height / Double(max(groupNames.count / cols + 1, 2))
        for (i, name) in groupNames.enumerated() {
            let col = i % cols
            let row = i / cols
            groupCenters[name] = CGPoint(
                x: cellW * (Double(col) + 1),
                y: cellH * (Double(row) + 1)
            )
        }

        // Initialize positions
        for node in nodes {
            let gk = groupKey(for: node)
            if positions[node.id] == nil {
                if let anchor = anchorNodes[node.id] {
                    positions[node.id] = NodePosition(x: anchor.x, y: anchor.y, isFixed: true, group: gk)
                } else if let existing = node.position {
                    positions[node.id] = NodePosition(x: existing.x, y: existing.y, group: gk)
                } else {
                    // Place near group center with jitter
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

        // Post-process: resolve remaining overlaps
        resolveOverlaps(nodes: nodes)
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

        // Repulsive forces
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                guard let posA = positions[nodes[i].id], let posB = positions[nodes[j].id] else { continue }
                let dx = posA.x - posB.x
                let dy = posA.y - posB.y
                let dist = max(sqrt(dx * dx + dy * dy), 1)
                let force = repulsionConstant / (dist * dist)
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[nodes[i].id]?.dx += fx
                forces[nodes[i].id]?.dy += fy
                forces[nodes[j].id]?.dx -= fx
                forces[nodes[j].id]?.dy -= fy
            }
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
