//
//  ConceptTypes.swift
//  Atlas
//
//  Enums and type definitions for the knowledge graph
//

import SwiftUI
import AppKit

// MARK: - Node Level (Hierarchy)
/// Four-level abstraction ladder for knowledge-graph nodes. Each level is
/// a fold of the level below: a Document contains Chapters; a Chapter
/// contains Concepts; a Concept contains Entities. Mirrors
/// `SemanticZoomLevel` 1:1 — the renderer's tab UI is just a level filter.
enum NodeLevel: String, Codable, Hashable {
    case document  // representative node for an entire PDF
    case chapter   // representative node for a chapter / section
    case concept   // theme or topic within a chapter
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

    /// Heuristic default node level when the LLM doesn't specify one.
    /// Document and Chapter levels come from dedicated extraction passes,
    /// never inferred from `ConceptType`, so this only maps to
    /// `.concept` / `.entity`.
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
    // Containment edges express the 4-level fold. Each adjacent pair of
    // levels uses its own edge type so renderer filters can hide them or
    // style them consistently (e.g. drawn faintly, no linkingPhrase label).
    case containsChapter   // Document → Chapter
    case containsConcept   // Chapter → Concept
    case containsEntity    // Concept → Entity

    // Hybrid cross-document typed relations. Emitted by the ETR-style
    // adjudicator (see EmbeddingResolver) when two near-duplicate nodes are
    // NOT the same thing but hold a SCE-style typed relationship.
    case instanceOf        // specific item → general category / catalog
    case attributeOf       // property → the object it describes
    case processFor        // process / managing function → thing it serves

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
        case .containsChapter, .containsConcept, .containsEntity: return "Contains"
        case .instanceOf: return "Instance Of"
        case .attributeOf: return "Attribute Of"
        case .processFor: return "Process For"
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
        case .containsChapter, .containsConcept, .containsEntity: return .secondary
        case .instanceOf: return .teal
        case .attributeOf: return .brown
        case .processFor: return .pink
        }
    }

    /// True for the three structural fold edges. UI may render these
    /// differently (faded, hidden when not expanded, no linking-phrase label).
    var isContainment: Bool {
        switch self {
        case .containsChapter, .containsConcept, .containsEntity: return true
        default: return false
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
