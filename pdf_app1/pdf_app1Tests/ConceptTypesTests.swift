import XCTest
import AppKit
@testable import pdf_app1

/// Pure tests for `Atlas/Models/ConceptTypes.swift`:
/// `ConceptType`, `EdgeType`, `SemanticZoomLevel`, `SourceHighlightPalette`, etc.
final class ConceptTypesTests: XCTestCase {

    // MARK: - ConceptType

    func test_conceptType_displayName_capitalizesRawValue() {
        XCTAssertEqual(ConceptType.concept.displayName, "Concept")
        XCTAssertEqual(ConceptType.definition.displayName, "Definition")
        XCTAssertEqual(ConceptType.equation.displayName, "Equation")
    }

    func test_conceptType_iconMappingIsTotal() {
        // Every case must yield a non-empty icon string (so the renderer never crashes).
        for c in ConceptType.allCases {
            XCTAssertFalse(c.icon.isEmpty, "icon for \(c) should be non-empty")
        }
    }

    func test_conceptType_defaultLevel_partitionsConceptsAndEntities() {
        // Concept-shaped types
        XCTAssertEqual(ConceptType.concept.defaultLevel,  .concept)
        XCTAssertEqual(ConceptType.theorem.defaultLevel,  .concept)
        XCTAssertEqual(ConceptType.method.defaultLevel,   .concept)
        XCTAssertEqual(ConceptType.claim.defaultLevel,    .concept)
        // Entity-shaped types
        XCTAssertEqual(ConceptType.definition.defaultLevel, .entity)
        XCTAssertEqual(ConceptType.example.defaultLevel,    .entity)
        XCTAssertEqual(ConceptType.person.defaultLevel,     .entity)
        XCTAssertEqual(ConceptType.dataset.defaultLevel,    .entity)
        XCTAssertEqual(ConceptType.result.defaultLevel,     .entity)
        XCTAssertEqual(ConceptType.equation.defaultLevel,   .entity)
    }

    func test_conceptType_codableRoundTrip() throws {
        for c in ConceptType.allCases {
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(ConceptType.self, from: data)
            XCTAssertEqual(decoded, c)
        }
    }

    // MARK: - EdgeType

    func test_edgeType_displayName_isNonEmptyForAllCases() {
        for e in EdgeType.allCases {
            XCTAssertFalse(e.displayName.isEmpty, "displayName for \(e) must be set")
        }
    }

    func test_edgeType_displayName_containmentVariantsShareLabel() {
        // The three structural fold edges all read as "Contains" in the UI.
        XCTAssertEqual(EdgeType.containsChapter.displayName, "Contains")
        XCTAssertEqual(EdgeType.containsConcept.displayName, "Contains")
        XCTAssertEqual(EdgeType.containsEntity.displayName,  "Contains")
    }

    func test_edgeType_isContainment_partition() {
        let containment: [EdgeType] = [.containsChapter, .containsConcept, .containsEntity]
        for c in containment {
            XCTAssertTrue(c.isContainment, "\(c) should be a containment edge")
        }
        for e in EdgeType.allCases where !containment.contains(e) {
            XCTAssertFalse(e.isContainment, "\(e) must NOT be flagged as containment")
        }
    }

    func test_edgeType_sceTypedEdgesAreNonContainment() {
        // The SCE match-kind edges must NOT bleed into the containment partition;
        // they're cross-document relationship edges, not fold edges.
        for e: EdgeType in [.instanceOf, .attributeOf, .processFor] {
            XCTAssertFalse(e.isContainment)
        }
    }

    func test_edgeType_codableRoundTrip() throws {
        for e in EdgeType.allCases {
            let data = try JSONEncoder().encode(e)
            let decoded = try JSONDecoder().decode(EdgeType.self, from: data)
            XCTAssertEqual(decoded, e)
        }
    }

    // MARK: - SemanticZoomLevel

    func test_semanticZoomLevel_ordering() {
        // Defined Comparable by rawValue.
        XCTAssertLessThan(SemanticZoomLevel.document, .chapter)
        XCTAssertLessThan(SemanticZoomLevel.chapter,  .concept)
        XCTAssertLessThan(SemanticZoomLevel.concept,  .entity)
    }

    func test_semanticZoomLevel_displayName_isNonEmpty() {
        for z in SemanticZoomLevel.allCases {
            XCTAssertFalse(z.displayName.isEmpty)
        }
    }

    func test_semanticZoomLevel_rawValuesAreStableAndMonotonic() {
        XCTAssertEqual(SemanticZoomLevel.document.rawValue, 0)
        XCTAssertEqual(SemanticZoomLevel.chapter.rawValue,  1)
        XCTAssertEqual(SemanticZoomLevel.concept.rawValue,  2)
        XCTAssertEqual(SemanticZoomLevel.entity.rawValue,   3)
    }

    // MARK: - NodeLevel / ReadingState / ExpansionState / ProcessingState round-trip

    func test_nodeLevel_codableRoundTrip() throws {
        for l in [NodeLevel.document, .chapter, .concept, .entity] {
            let data = try JSONEncoder().encode(l)
            let decoded = try JSONDecoder().decode(NodeLevel.self, from: data)
            XCTAssertEqual(decoded, l)
        }
    }

    func test_readingState_codableRoundTrip() throws {
        for r in [ReadingState.unseen, .visited, .highlighted, .annotated] {
            let data = try JSONEncoder().encode(r)
            let decoded = try JSONDecoder().decode(ReadingState.self, from: data)
            XCTAssertEqual(decoded, r)
        }
    }

    func test_expansionState_codableRoundTrip() throws {
        for e in [ExpansionState.collapsed, .expanded, .autoCollapsed] {
            let data = try JSONEncoder().encode(e)
            let decoded = try JSONDecoder().decode(ExpansionState.self, from: data)
            XCTAssertEqual(decoded, e)
        }
    }

    func test_processingState_codableRoundTrip() throws {
        for p in [ProcessingState.unprocessed, .processing, .partial, .complete, .failed] {
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(ProcessingState.self, from: data)
            XCTAssertEqual(decoded, p)
        }
    }

    // MARK: - SourceHighlightPalette

    func test_palette_isNonEmpty() {
        XCTAssertGreaterThan(SourceHighlightPalette.colors.count, 0)
    }

    func test_palette_colorForIndex_wrapsAroundByModulo() {
        let n = SourceHighlightPalette.colors.count
        let first = SourceHighlightPalette.color(for: 0)
        let oneCycleLater = SourceHighlightPalette.color(for: n)
        XCTAssertEqual(first, oneCycleLater, "Palette wraps at length \(n)")
    }

    func test_palette_colorForIndex_handlesLargeIndices() {
        // Should not crash for very large indices.
        _ = SourceHighlightPalette.color(for: 9999)
        _ = SourceHighlightPalette.color(for: Int.max - 1)
    }

    // MARK: - PaneMode equality

    func test_paneMode_equality() {
        XCTAssertEqual(PaneMode.split, .split)
        XCTAssertNotEqual(PaneMode.split, .pdfOnly)
    }
}
