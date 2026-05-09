import Foundation
import XCTest

@testable import pdf_app1

final class NovakExtractionTests: XCTestCase {

    // MARK: - RawConcept: hierarchyLevel decoding

    func test_rawConcept_decodesHierarchyLevel() throws {
        let json = """
        {
            "label": "Cellular respiration",
            "type": "concept",
            "summary": "The process by which cells convert glucose to energy",
            "textSpan": "Cellular respiration is the process...",
            "confidence": 0.95,
            "hierarchyLevel": 0
        }
        """.data(using: .utf8)!

        let concept = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(concept.hierarchyLevel, 0)
        XCTAssertNil(concept.subtopicOf)
    }

    func test_rawConcept_decodesSubtopicOf() throws {
        let json = """
        {
            "label": "Glycolysis",
            "type": "concept",
            "summary": "First stage of cellular respiration",
            "textSpan": "Glycolysis occurs in the cytoplasm...",
            "confidence": 0.9,
            "hierarchyLevel": 1,
            "subtopicOf": "Cellular respiration"
        }
        """.data(using: .utf8)!

        let concept = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(concept.hierarchyLevel, 1)
        XCTAssertEqual(concept.subtopicOf, "Cellular respiration")
    }

    func test_rawConcept_backwardCompat_noNewFields() throws {
        let json = """
        {
            "label": "Old-style concept",
            "type": "concept",
            "summary": null,
            "textSpan": "some text",
            "confidence": 0.9
        }
        """.data(using: .utf8)!

        let concept = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(concept.label, "Old-style concept")
        XCTAssertNil(concept.hierarchyLevel)
        XCTAssertNil(concept.subtopicOf)
    }

    // MARK: - RawEdge: linkingPhrase decoding

    func test_rawEdge_decodesLinkingPhrase() throws {
        let json = """
        {
            "sourceLabel": "Glycolysis",
            "targetLabel": "Pyruvate",
            "type": "produces",
            "confidence": 0.9,
            "linkingPhrase": "produces"
        }
        """.data(using: .utf8)!

        let edge = try JSONDecoder().decode(RawEdge.self, from: json)
        XCTAssertEqual(edge.linkingPhrase, "produces")
        XCTAssertEqual(edge.sourceLabel, "Glycolysis")
        XCTAssertEqual(edge.targetLabel, "Pyruvate")
    }

    func test_rawEdge_backwardCompat_noLinkingPhrase() throws {
        let json = """
        {
            "sourceLabel": "A",
            "targetLabel": "B",
            "type": "dependsOn",
            "confidence": 0.8
        }
        """.data(using: .utf8)!

        let edge = try JSONDecoder().decode(RawEdge.self, from: json)
        XCTAssertNil(edge.linkingPhrase)
    }

    // MARK: - Full ExtractionResponse with Novak-style output

    func test_fullNovakResponse_decodesCorrectly() throws {
        let json = """
        {
          "concepts": [
            {
              "label": "Cellular respiration",
              "type": "concept",
              "summary": "Process of converting glucose to ATP",
              "textSpan": "Cellular respiration is a set of metabolic reactions",
              "confidence": 0.95,
              "hierarchyLevel": 0,
              "subtopicOf": null
            },
            {
              "label": "Glycolysis",
              "type": "concept",
              "summary": "First stage breaking glucose into pyruvate",
              "textSpan": "Glycolysis occurs in the cytoplasm",
              "confidence": 0.9,
              "hierarchyLevel": 1,
              "subtopicOf": "Cellular respiration"
            },
            {
              "label": "Krebs cycle",
              "type": "concept",
              "summary": "Second stage in the mitochondrial matrix",
              "textSpan": "The Krebs cycle takes place in the matrix",
              "confidence": 0.9,
              "hierarchyLevel": 1,
              "subtopicOf": "Cellular respiration"
            }
          ],
          "edges": [
            {
              "sourceLabel": "Glycolysis",
              "targetLabel": "Krebs cycle",
              "type": "dependsOn",
              "confidence": 0.85,
              "linkingPhrase": "feeds pyruvate into"
            }
          ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ExtractionResponse.self, from: json)

        XCTAssertEqual(response.concepts.count, 3)
        XCTAssertEqual(response.edges.count, 1)

        let topThemes = response.concepts.filter { $0.hierarchyLevel == 0 }
        XCTAssertEqual(topThemes.count, 1)
        XCTAssertEqual(topThemes.first?.label, "Cellular respiration")

        let subConcepts = response.concepts.filter { ($0.hierarchyLevel ?? 99) > 0 }
        XCTAssertEqual(subConcepts.count, 2)
        XCTAssertTrue(subConcepts.allSatisfy { $0.subtopicOf == "Cellular respiration" })

        XCTAssertEqual(response.edges.first?.linkingPhrase, "feeds pyruvate into")
    }

    // MARK: - ConceptNode: hierarchyLevel storage

    func test_conceptNode_hierarchyLevel_setFromInit() {
        let node = ConceptNode(label: "Top theme", hierarchyLevel: 0)
        XCTAssertEqual(node.hierarchyLevel, 0)
    }

    func test_conceptNode_hierarchyLevel_defaultsTo1() {
        let node = ConceptNode(label: "Sub-concept")
        XCTAssertEqual(node.hierarchyLevel, 1)
    }

    func test_conceptNode_hierarchyLevel_roundTripsThroughCodable() throws {
        let original = ConceptNode(
            label: "Cellular respiration",
            type: .concept,
            summary: "Top theme",
            confidence: 0.95,
            hierarchyLevel: 0
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)

        XCTAssertEqual(decoded.hierarchyLevel, 0)
        XCTAssertEqual(decoded.label, "Cellular respiration")
    }

    func test_conceptNode_hierarchyLevel_legacyJSON_defaultsByLevel() throws {
        // Simulate a graph file saved before hierarchyLevel existed.
        // Default is level-aware: concept → 0 (root), entity → 1 (sub).
        // Full coverage lives in NodeSizingTests.testDecodingWithoutHierarchyLevelDefaultsFromNodeLevel.
        let legacyJSON = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "label": "Old concept",
            "type": "concept",
            "sourceAnchors": [],
            "readingState": "unseen",
            "expansionState": "collapsed",
            "confidence": 0.8,
            "isPinned": false,
            "level": "concept"
        }
        """.data(using: .utf8)!

        let node = try JSONDecoder().decode(ConceptNode.self, from: legacyJSON)
        XCTAssertEqual(node.hierarchyLevel, 0, "Legacy concept-level nodes should default to hierarchyLevel 0")
    }

    // MARK: - GraphEdge: subtopicOf type + label

    func test_graphEdge_subtopicOf_type() {
        let edge = GraphEdge(
            sourceNodeID: UUID(),
            targetNodeID: UUID(),
            type: .subtopicOf,
            confidence: 1.0,
            label: "is a subtopic of"
        )
        XCTAssertEqual(edge.type, .subtopicOf)
        XCTAssertEqual(edge.label, "is a subtopic of")
        XCTAssertEqual(edge.type.displayName, "Subtopic Of")
    }

    func test_graphEdge_linkingPhrase_stored_in_label() {
        let edge = GraphEdge(
            sourceNodeID: UUID(),
            targetNodeID: UUID(),
            type: .dependsOn,
            confidence: 0.85,
            label: "feeds pyruvate into"
        )
        XCTAssertEqual(edge.label, "feeds pyruvate into")
    }

    func test_graphEdge_subtopicOf_roundTripsThroughCodable() throws {
        let original = GraphEdge(
            sourceNodeID: UUID(),
            targetNodeID: UUID(),
            type: .subtopicOf,
            confidence: 1.0,
            label: "is a subtopic of"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GraphEdge.self, from: data)

        XCTAssertEqual(decoded.type, .subtopicOf)
        XCTAssertEqual(decoded.label, "is a subtopic of")
    }

    // MARK: - KnowledgeGraph: subtopicOf edge integration

    func test_graph_subtopicOfEdges_queryable() {
        let graph = KnowledgeGraph()

        let parent = ConceptNode(label: "Cellular respiration", hierarchyLevel: 0)
        let child1 = ConceptNode(label: "Glycolysis", hierarchyLevel: 1)
        let child2 = ConceptNode(label: "Krebs cycle", hierarchyLevel: 1)
        graph.addNode(parent)
        graph.addNode(child1)
        graph.addNode(child2)

        graph.addEdge(GraphEdge(
            sourceNodeID: child1.id, targetNodeID: parent.id,
            type: .subtopicOf, confidence: 1.0, label: "is a subtopic of"
        ))
        graph.addEdge(GraphEdge(
            sourceNodeID: child2.id, targetNodeID: parent.id,
            type: .subtopicOf, confidence: 1.0, label: "is a subtopic of"
        ))
        graph.addEdge(GraphEdge(
            sourceNodeID: child1.id, targetNodeID: child2.id,
            type: .dependsOn, confidence: 0.85, label: "feeds pyruvate into"
        ))

        let subtopicEdges = graph.allEdges.filter { $0.type == .subtopicOf }
        XCTAssertEqual(subtopicEdges.count, 2)

        let parentEdges = graph.edges(for: parent.id)
        XCTAssertEqual(parentEdges.count, 2)
        XCTAssertTrue(parentEdges.allSatisfy { $0.type == .subtopicOf })
    }

    // MARK: - KnowledgeGraph: full Codable round-trip with Novak data

    func test_graph_novakData_roundTripsThroughCodable() throws {
        let graph = KnowledgeGraph()

        let theme = ConceptNode(label: "Cellular respiration", type: .concept, hierarchyLevel: 0)
        let sub = ConceptNode(label: "Glycolysis", type: .concept, hierarchyLevel: 1)
        graph.addNode(theme)
        graph.addNode(sub)

        graph.addEdge(GraphEdge(
            sourceNodeID: sub.id, targetNodeID: theme.id,
            type: .subtopicOf, confidence: 1.0, label: "is a subtopic of"
        ))

        let data = try graph.encode()

        let restored = KnowledgeGraph()
        try restored.decode(from: data)

        XCTAssertEqual(restored.nodeCount, 2)
        XCTAssertEqual(restored.edgeCount, 1)

        let restoredTheme = restored.allNodes.first { $0.label == "Cellular respiration" }
        XCTAssertNotNil(restoredTheme)
        XCTAssertEqual(restoredTheme?.hierarchyLevel, 0)

        let restoredSub = restored.allNodes.first { $0.label == "Glycolysis" }
        XCTAssertEqual(restoredSub?.hierarchyLevel, 1)

        let restoredEdge = restored.allEdges.first
        XCTAssertEqual(restoredEdge?.type, .subtopicOf)
        XCTAssertEqual(restoredEdge?.label, "is a subtopic of")
    }

    // MARK: - JSONRepair: truncated Novak-style response recovery

    func test_jsonRepair_closesUnclosedNovakResponse() {
        let truncated = """
        {"concepts": [{"label": "Cellular respiration", "type": "concept", "summary": "Top theme", "textSpan": "text here", "confidence": 0.9, "hierarchyLevel": 0, "subtopicOf": null}], "edges": [{"sourceLabel": "A", "targetLabel": "B", "type": "dependsOn", "confidence": 0.8, "linkingPhrase": "requires"
        """

        let repaired = JSONRepair.cleanAndRepair(truncated)

        // Should be parseable JSON after repair
        let data = repaired.data(using: .utf8)!
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data), "Repaired JSON should be parseable")
    }

    func test_jsonRepair_recoversPartialConceptsArray() {
        // Simulate truncation mid-way through second concept
        let truncated = """
        {"concepts": [{"label": "Theme A", "type": "concept", "summary": "s", "textSpan": "t", "confidence": 0.9, "hierarchyLevel": 0}, {"label": "Broken
        """

        let repaired = JSONRepair.cleanAndRepair(truncated)
        let data = repaired.data(using: .utf8)!
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data), "Should recover from mid-concept truncation")
    }

    func test_jsonRepair_validNovakJSON_passesThrough() {
        let valid = """
        {"concepts": [{"label": "X", "type": "concept", "summary": "s", "textSpan": "t", "confidence": 0.9, "hierarchyLevel": 0, "subtopicOf": null}], "edges": [{"sourceLabel": "X", "targetLabel": "Y", "type": "dependsOn", "confidence": 0.8, "linkingPhrase": "requires"}]}
        """

        let result = JSONRepair.cleanAndRepair(valid)
        XCTAssertEqual(result, valid, "Valid JSON should pass through unchanged")
    }

    func test_jsonRepair_stripsMarkdownFences() {
        let fenced = """
        ```json
        {"concepts": [], "edges": []}
        ```
        """

        let result = JSONRepair.cleanAndRepair(fenced)
        let data = result.data(using: .utf8)!
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
        XCTAssertNotNil(obj?["concepts"])
        XCTAssertNotNil(obj?["edges"])
    }

    // MARK: - Mixed old + new edge types don't collide

    func test_edgeType_allCases_containsSubtopicOf() {
        XCTAssertTrue(EdgeType.allCases.contains(.subtopicOf))
    }

    func test_edgeType_subtopicOf_rawValue() {
        XCTAssertEqual(EdgeType.subtopicOf.rawValue, "subtopicOf")
    }
}
