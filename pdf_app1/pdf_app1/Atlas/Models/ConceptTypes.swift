//
//  ConceptTypes.swift
//  Atlas
//
//  Enums and type definitions for the knowledge graph
//

import SwiftUI
import AppKit

// MARK: - Node Level (Hierarchy)
enum NodeLevel: String, Codable, Hashable {
    case concept   // top-level organizational unit (theme/topic)
    case entity    // specific thing within a concept (term, technique, person, formula)
}

// MARK: - Concept Types
enum ConceptType: String, Codable, CaseIterable, Hashable {
    case concept
    case definition
    case theorem
    case example
    case claim
    case person
    case dataset
    case method
    case result
    case equation

    var displayName: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .concept: return "lightbulb"
        case .definition: return "book.closed"
        case .theorem: return "function"
        case .example: return "doc.text"
        case .claim: return "quote.opening"
        case .person: return "person"
        case .dataset: return "tablecells"
        case .method: return "gearshape.2"
        case .result: return "checkmark.seal"
        case .equation: return "x.squareroot"
        }
    }

    var color: Color {
        switch self {
        case .concept: return .blue
        case .definition: return .purple
        case .theorem: return .orange
        case .example: return .green
        case .claim: return .red
        case .person: return .cyan
        case .dataset: return .mint
        case .method: return .indigo
        case .result: return .yellow
        case .equation: return .pink
        }
    }

    /// Heuristic default hierarchy level when the LLM doesn't specify one
    var defaultLevel: NodeLevel {
        switch self {
        case .concept, .theorem, .method, .claim:
            return .concept
        case .definition, .example, .person, .dataset, .result, .equation:
            return .entity
        }
    }
}

// MARK: - Edge Types
enum EdgeType: String, Codable, CaseIterable, Hashable {
    case dependsOn
    case contradicts
    case exampleOf
    case defines
    case extends
    case cites
    case sameTopic
    case partOf
    case uses
    case containsEntity

    var displayName: String {
        switch self {
        case .dependsOn: return "Depends On"
        case .contradicts: return "Contradicts"
        case .exampleOf: return "Example Of"
        case .defines: return "Defines"
        case .extends: return "Extends"
        case .cites: return "Cites"
        case .sameTopic: return "Same Topic"
        case .partOf: return "Part Of"
        case .uses: return "Uses"
        case .containsEntity: return "Contains"
        }
    }

    var color: Color {
        switch self {
        case .dependsOn: return .gray
        case .contradicts: return .red
        case .exampleOf: return .green
        case .defines: return .purple
        case .extends: return .blue
        case .cites: return .orange
        case .sameTopic: return .cyan
        case .partOf: return .indigo
        case .uses: return .mint
        case .containsEntity: return .secondary
        }
    }
}

// MARK: - Reading State
enum ReadingState: String, Codable, Hashable {
    case unseen
    case visited
    case highlighted
    case annotated
}

// MARK: - Expansion State
enum ExpansionState: String, Codable, Hashable {
    case collapsed
    case expanded
    case autoCollapsed
}

// MARK: - Semantic Zoom Level
enum SemanticZoomLevel: Int, Codable, CaseIterable, Comparable {
    case document = 0
    case chapter = 1
    case concept = 2
    case entity = 3

    var displayName: String {
        switch self {
        case .document: return "Document"
        case .chapter: return "Chapter"
        case .concept: return "Concept"
        case .entity: return "Entity"
        }
    }

    static func < (lhs: SemanticZoomLevel, rhs: SemanticZoomLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Pane Mode
enum PaneMode: String, Equatable {
    case pdfOnly
    case mapOnly
    case split
}

// MARK: - Processing State
enum ProcessingState: String, Codable {
    case unprocessed
    case processing
    case partial
    case complete
    case failed
}

// MARK: - Source Highlight Palette
enum SourceHighlightPalette {
    static let colors: [NSColor] = [
        .systemBlue, .systemPurple, .systemTeal, .systemOrange,
        .systemPink, .systemGreen, .systemIndigo, .systemBrown,
        .systemCyan, .systemMint, .systemRed, .systemYellow
    ]

    static func color(for index: Int) -> NSColor {
        colors[index % colors.count]
    }
}
