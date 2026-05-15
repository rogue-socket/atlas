//
//  LevelBandSeeder.swift
//  Atlas
//
//  Initial-position seeder that places each node in a horizontal band
//  corresponding to its `NodeLevel`. Replaces the grid fallback used
//  after `HierarchyForest` / `TreeLayoutSeeder` were removed in the
//  4-level migration. Sub-clusters within a band by parent so related
//  nodes start near each other (entities under their parent concept,
//  concepts under their parent chapter).
//

import Foundation
import CoreGraphics

enum LevelBandSeeder {

    /// Y-fraction of the virtual canvas per band. Document on top, entity
    /// at the bottom — matches the user's mental model of folds.
    private static func bandFraction(for level: NodeLevel) -> Double {
        switch level {
        case .document: return 0.15
        case .chapter:  return 0.40
        case .concept:  return 0.65
        case .entity:   return 0.85
        }
    }

    static func bandY(for level: NodeLevel, canvasHeight: Double) -> Double {
        canvasHeight * bandFraction(for: level)
    }

    /// Seed initial positions: each node lands at its level's band Y, X
    /// spread evenly across the canvas with parent-based sub-clustering.
    /// Entities cluster under their parent concept; concepts cluster under
    /// their parent chapter; chapters and documents share a single group
    /// per level (few enough that simple X spread is fine).
    static func seed(
        nodes: [ConceptNode],
        canvasSize: CGSize,
        parentByEntity: [UUID: UUID],
        parentByConcept: [UUID: UUID]
    ) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        let nodesByLevel = Dictionary(grouping: nodes, by: \.level)

        for (level, levelNodes) in nodesByLevel {
            let bandCenterY = bandY(for: level, canvasHeight: canvasSize.height)
            let groups = subgroup(levelNodes, level: level,
                                  parentByEntity: parentByEntity,
                                  parentByConcept: parentByConcept)
            let groupKeys = groups.keys.sorted()
            let groupSpacing = canvasSize.width / Double(max(groupKeys.count, 1) + 1)
            for (gi, key) in groupKeys.enumerated() {
                let centerX = Double(gi + 1) * groupSpacing
                let groupNodes = groups[key] ?? []
                placeGroup(groupNodes, centerX: centerX, centerY: bandCenterY, into: &result)
            }
        }
        return result
    }

    private static func subgroup(
        _ nodes: [ConceptNode],
        level: NodeLevel,
        parentByEntity: [UUID: UUID],
        parentByConcept: [UUID: UUID]
    ) -> [String: [ConceptNode]] {
        Dictionary(grouping: nodes) { node -> String in
            switch level {
            case .entity:
                return parentByEntity[node.id]?.uuidString ?? "orphan"
            case .concept:
                return parentByConcept[node.id]?.uuidString ?? "orphan"
            case .chapter, .document:
                return "all"
            }
        }
    }

    /// Tile group members in a small grid around `(centerX, centerY)`.
    /// Three columns wide so the cluster stays roughly square at typical
    /// sizes; vertical spread stays within the band's tolerance.
    private static func placeGroup(
        _ nodes: [ConceptNode],
        centerX: Double,
        centerY: Double,
        into result: inout [UUID: CGPoint]
    ) {
        let cols = 3
        let cellW: Double = 70
        let cellH: Double = 70
        for (i, node) in nodes.enumerated() {
            let col = i % cols
            let row = i / cols
            let xOffset = (Double(col) - Double(cols - 1) / 2) * cellW
            let yOffset = (Double(row) - Double(nodes.count / cols) / 2) * cellH
            result[node.id] = CGPoint(x: centerX + xOffset, y: centerY + yOffset)
        }
    }
}
