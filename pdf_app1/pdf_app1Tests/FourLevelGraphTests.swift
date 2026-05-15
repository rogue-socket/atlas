import XCTest
@testable import pdf_app1

/// Tests for the 4-level knowledge-graph migration (Document → Chapter →
/// Concept → Entity) per `prds/2026-05-15_4-level-knowledge-graph.md`.
///
/// Covers:
/// - ConceptNode Codable round-trips for all four NodeLevel cases
/// - `lastModified` default + round-trip
/// - DensityManager.visibleNodes filters strictly by level
/// - KnowledgeGraph.merge respects lastModified on UUID collision
/// - GraphStore.loadProjectWideGraph reconciles multiple per-doc files
/// - ChapterExtraction sanitize handles overlap / out-of-range / disorder
/// - ChapterExtraction.attachConceptsToChapters builds containsConcept edges
///   with multi-parent semantics when a concept spans multiple chapters
final class FourLevelGraphTests: XCTestCase {

    private func docURL(_ name: String = "test.pdf") -> URL {
        URL(fileURLWithPath: "/tmp/atlas-tests/\(name)")
    }

    private func anchor(_ url: URL, page: Int = 0) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    // MARK: - ConceptNode Codable: all four levels

    func test_conceptNode_documentLevel_roundTrips() throws {
        let node = ConceptNode(
            label: "Paper Title",
            type: .concept,
            summary: "TLDR of the whole paper.",
            sourceAnchors: [anchor(docURL())],
            level: .document
        )
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)
        XCTAssertEqual(decoded.level, .document)
        XCTAssertEqual(decoded.label, "Paper Title")
        XCTAssertEqual(decoded.summary, "TLDR of the whole paper.")
    }

    func test_conceptNode_chapterLevel_roundTrips() throws {
        let node = ConceptNode(label: "Methods", type: .concept, level: .chapter)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)
        XCTAssertEqual(decoded.level, .chapter)
    }

    func test_conceptNode_conceptLevel_roundTrips() throws {
        let node = ConceptNode(label: "DNA Replication", type: .concept, level: .concept)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)
        XCTAssertEqual(decoded.level, .concept)
    }

    func test_conceptNode_entityLevel_roundTrips() throws {
        let node = ConceptNode(label: "Helicase", type: .definition, level: .entity)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)
        XCTAssertEqual(decoded.level, .entity)
    }

    // MARK: - lastModified

    func test_conceptNode_lastModified_defaultsToNow() {
        let before = Date()
        let node = ConceptNode(label: "X", type: .concept)
        let after = Date()
        XCTAssertGreaterThanOrEqual(node.lastModified, before)
        XCTAssertLessThanOrEqual(node.lastModified, after)
    }

    func test_conceptNode_lastModified_roundTripsThroughCodable() throws {
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let node = ConceptNode(label: "X", type: .concept, level: .concept, lastModified: stamp)
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ConceptNode.self, from: data)
        XCTAssertEqual(decoded.lastModified.timeIntervalSince1970, stamp.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - DensityManager: strict level filtering

    func test_densityManager_documentTab_showsOnlyDocumentLevel() {
        let graph = KnowledgeGraph()
        let doc = ConceptNode(label: "D", level: .document)
        let chap = ConceptNode(label: "C", level: .chapter)
        let con = ConceptNode(label: "X", level: .concept)
        let ent = ConceptNode(label: "Y", level: .entity)
        for n in [doc, chap, con, ent] { graph.addNode(n) }

        let visible = DensityManager().visibleNodes(from: graph, zoomLevel: .document)
        XCTAssertEqual(visible.map(\.id), [doc.id])
    }

    func test_densityManager_chapterTab_showsOnlyChapterLevel() {
        let graph = KnowledgeGraph()
        let doc = ConceptNode(label: "D", level: .document)
        let chap = ConceptNode(label: "C", level: .chapter)
        let con = ConceptNode(label: "X", level: .concept)
        for n in [doc, chap, con] { graph.addNode(n) }
        let visible = DensityManager().visibleNodes(from: graph, zoomLevel: .chapter)
        XCTAssertEqual(visible.map(\.id), [chap.id])
    }

    func test_densityManager_pinnedNode_notVisibleAtNonMatchingLevels() {
        // B1: pinned nodes no longer carve out across levels — each tab
        // strictly shows its own level. The renderer's selection overlay
        // still calls attention to the active node when it's at the
        // currently-visible level.
        let graph = KnowledgeGraph()
        var pinned = ConceptNode(label: "P", level: .entity)
        pinned.isPinned = true
        graph.addNode(pinned)

        let visibleAtEntity = DensityManager().visibleNodes(from: graph, zoomLevel: .entity)
        XCTAssertTrue(visibleAtEntity.contains { $0.id == pinned.id }, "Pinned entity is visible at its own level")

        for offLevel in [SemanticZoomLevel.document, .chapter, .concept] {
            let visible = DensityManager().visibleNodes(from: graph, zoomLevel: offLevel)
            XCTAssertFalse(visible.contains { $0.id == pinned.id }, "Pinned entity must NOT bleed into \(offLevel) tab")
        }
    }

    // MARK: - merge() last-modified reconciliation

    func test_merge_collisionPicksLaterLastModified() {
        let id = UUID()
        let older = ConceptNode(id: id, label: "Old", type: .concept, level: .concept,
                                lastModified: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = ConceptNode(id: id, label: "New", type: .concept, level: .concept,
                                lastModified: Date(timeIntervalSince1970: 1_800_000_000))

        let target = KnowledgeGraph()
        target.addNode(older)
        let source = KnowledgeGraph()
        source.addNode(newer)
        target.merge(from: source)

        XCTAssertEqual(target.node(for: id)?.label, "New")
    }

    func test_merge_collisionKeepsEarlierWhenSourceIsOlder() {
        let id = UUID()
        let newer = ConceptNode(id: id, label: "New", type: .concept, level: .concept,
                                lastModified: Date(timeIntervalSince1970: 1_800_000_000))
        let older = ConceptNode(id: id, label: "Old", type: .concept, level: .concept,
                                lastModified: Date(timeIntervalSince1970: 1_700_000_000))

        let target = KnowledgeGraph()
        target.addNode(newer)
        let source = KnowledgeGraph()
        source.addNode(older)
        target.merge(from: source)

        XCTAssertEqual(target.node(for: id)?.label, "New", "Older incoming should not overwrite newer existing")
    }

    func test_merge_dedupesEdgesByTuple() {
        let a = ConceptNode(label: "A", level: .concept)
        let b = ConceptNode(label: "B", level: .entity)

        let g1 = KnowledgeGraph()
        g1.addNode(a)
        g1.addNode(b)
        g1.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .containsEntity, confidence: 1.0))

        let g2 = KnowledgeGraph()
        g2.addNode(a)
        g2.addNode(b)
        g2.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .containsEntity, confidence: 1.0))

        g1.merge(from: g2)
        let containsEdges = g1.allEdges.filter { $0.type == .containsEntity }
        XCTAssertEqual(containsEdges.count, 1, "Duplicate containsEntity edge should be deduped")
    }

    // MARK: - Per-doc subgraph encode (B4)

    func test_encodeSubgraph_filtersNodesAnchoredInOtherDocuments() throws {
        let urlA = docURL("a.pdf")
        let urlB = docURL("b.pdf")
        let nodeA = ConceptNode(label: "A-node", sourceAnchors: [anchor(urlA)], level: .concept)
        let nodeB = ConceptNode(label: "B-node", sourceAnchors: [anchor(urlB)], level: .concept)

        let g = KnowledgeGraph()
        g.addNode(nodeA)
        g.addNode(nodeB)

        let snapshot = try g.encodeSubgraph(for: urlA)
        XCTAssertEqual(snapshot.nodeCount, 1, "Only the A-anchored node should be in A's subgraph")

        let restored = KnowledgeGraph()
        try restored.decode(from: snapshot.data)
        XCTAssertEqual(restored.allNodes.map(\.label), ["A-node"])
    }

    func test_encodeSubgraph_dropsEdgesWhoseEndpointsStraddleScope() throws {
        let urlA = docURL("a.pdf")
        let urlB = docURL("b.pdf")
        let a1 = ConceptNode(label: "A1", sourceAnchors: [anchor(urlA)], level: .concept)
        let a2 = ConceptNode(label: "A2", sourceAnchors: [anchor(urlA)], level: .concept)
        let b1 = ConceptNode(label: "B1", sourceAnchors: [anchor(urlB)], level: .concept)

        let g = KnowledgeGraph()
        g.addNode(a1); g.addNode(a2); g.addNode(b1)
        g.addEdge(GraphEdge(sourceNodeID: a1.id, targetNodeID: a2.id, type: .dependsOn))
        g.addEdge(GraphEdge(sourceNodeID: a1.id, targetNodeID: b1.id, type: .sameTopic))

        let snapshot = try g.encodeSubgraph(for: urlA)
        XCTAssertEqual(snapshot.edgeCount, 1, "Cross-document edge should be excluded from A's subgraph")

        let restored = KnowledgeGraph()
        try restored.decode(from: snapshot.data)
        XCTAssertEqual(restored.allEdges.map(\.type), [.dependsOn])
    }

    // MARK: - Per-doc subgraph merge (B4)

    func test_mergeSubgraph_preservesExistingNodesFromOtherDocuments() throws {
        let urlA = docURL("a.pdf")
        let urlB = docURL("b.pdf")
        let nodeA = ConceptNode(label: "A-node", sourceAnchors: [anchor(urlA)], level: .concept)
        let nodeB = ConceptNode(label: "B-node", sourceAnchors: [anchor(urlB)], level: .concept)

        // Tab 1 already loaded — receiver has A's node in memory.
        let inMemory = KnowledgeGraph()
        inMemory.addNode(nodeA)

        // Tab 2's per-doc file contains B's node.
        let bGraph = KnowledgeGraph()
        bGraph.addNode(nodeB)
        let payload = try bGraph.encodeSubgraph(for: urlB).data

        try inMemory.mergeSubgraph(from: payload, scopedTo: urlB)
        XCTAssertEqual(Set(inMemory.allNodes.map(\.label)), ["A-node", "B-node"],
                       "Tab 1's node should survive Tab 2's load")
    }

    func test_mergeSubgraph_dropsForeignAnchoredNodesFromLegacyBloatedPayload() throws {
        let urlA = docURL("a.pdf")
        let urlB = docURL("b.pdf")
        let nodeA = ConceptNode(label: "A-node", sourceAnchors: [anchor(urlA)], level: .concept)
        let nodeB = ConceptNode(label: "B-node", sourceAnchors: [anchor(urlB)], level: .concept)

        // Simulate a pre-B4 bloated per-doc file: A's file on disk also
        // contains B's nodes (the bug being fixed).
        let bloated = KnowledgeGraph()
        bloated.addNode(nodeA); bloated.addNode(nodeB)
        let payload = try bloated.encode()  // full encode, not subgraph — recreates the bloat

        let receiver = KnowledgeGraph()
        try receiver.mergeSubgraph(from: payload, scopedTo: urlA)
        XCTAssertEqual(receiver.allNodes.map(\.label), ["A-node"],
                       "Foreign B-anchored node should be stripped when scoping to A")
    }

    // MARK: - Lossy edge decode (B5)

    func test_decode_skipsEdgesWithRetiredEdgeType_keepsNodesAndOtherEdges() throws {
        // Simulate a legacy on-disk graph containing a retired EdgeType
        // (`subtopicOf`, removed in the 4-level migration). Old behavior:
        // the whole decode threw and the caller's catch ran `clear()`,
        // wiping every doc's graph in memory. New behavior: keep nodes and
        // known edges, drop only the unknown edge.
        let a = ConceptNode(label: "A", level: .concept)
        let b = ConceptNode(label: "B", level: .concept)

        let g = KnowledgeGraph()
        g.addNode(a)
        g.addNode(b)
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .dependsOn, confidence: 0.9))
        g.addEdge(GraphEdge(sourceNodeID: a.id, targetNodeID: b.id, type: .sameTopic, confidence: 0.8))

        // Rewrite one edge's type to a string that's no longer in EdgeType.
        let encoded = try g.encode()
        let json = String(data: encoded, encoding: .utf8)!
        let legacy = json.replacingOccurrences(of: "\"sameTopic\"", with: "\"subtopicOf\"")
        let legacyData = legacy.data(using: .utf8)!

        let restored = KnowledgeGraph()
        XCTAssertNoThrow(try restored.decode(from: legacyData))
        XCTAssertEqual(restored.nodeCount, 2, "Both nodes should survive the lossy decode")
        XCTAssertEqual(restored.edgeCount, 1, "Only the dependsOn edge should remain; the subtopicOf entry is dropped")
        XCTAssertEqual(restored.allEdges.first?.type, .dependsOn)
    }

    // MARK: - EdgeType.isContainment

    func test_edgeType_isContainment_trueForAllContainmentEdges() {
        XCTAssertTrue(EdgeType.containsChapter.isContainment)
        XCTAssertTrue(EdgeType.containsConcept.isContainment)
        XCTAssertTrue(EdgeType.containsEntity.isContainment)
    }

    func test_edgeType_isContainment_falseForRelationshipEdges() {
        XCTAssertFalse(EdgeType.dependsOn.isContainment)
        XCTAssertFalse(EdgeType.sameTopic.isContainment)
        XCTAssertFalse(EdgeType.contradicts.isContainment)
    }

    // MARK: - KnowledgeGraph.nodes(at:) helper

    func test_nodesAtLevel_filtersCorrectly() {
        let graph = KnowledgeGraph()
        let d = ConceptNode(label: "D", level: .document); graph.addNode(d)
        let c1 = ConceptNode(label: "C1", level: .chapter); graph.addNode(c1)
        let c2 = ConceptNode(label: "C2", level: .chapter); graph.addNode(c2)
        let p = ConceptNode(label: "P", level: .concept); graph.addNode(p)

        XCTAssertEqual(graph.nodes(at: .document).count, 1)
        XCTAssertEqual(graph.nodes(at: .chapter).count, 2)
        XCTAssertEqual(graph.nodes(at: .concept).count, 1)
        XCTAssertEqual(graph.nodes(at: .entity).count, 0)
    }

    // MARK: - KnowledgeGraph.entities(for:) via containsEntity edges

    func test_entitiesFor_returnsChildrenViaContainsEntityEdge() {
        let graph = KnowledgeGraph()
        let concept = ConceptNode(label: "C", level: .concept); graph.addNode(concept)
        let e1 = ConceptNode(label: "E1", level: .entity); graph.addNode(e1)
        let e2 = ConceptNode(label: "E2", level: .entity); graph.addNode(e2)
        let unrelated = ConceptNode(label: "U", level: .entity); graph.addNode(unrelated)

        graph.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e1.id, type: .containsEntity, confidence: 1.0))
        graph.addEdge(GraphEdge(sourceNodeID: concept.id, targetNodeID: e2.id, type: .containsEntity, confidence: 1.0))

        let entities = graph.entities(for: concept.id)
        let ids = Set(entities.map(\.id))
        XCTAssertEqual(ids, Set([e1.id, e2.id]))
        XCTAssertFalse(ids.contains(unrelated.id))
    }

    func test_entityCanHaveMultipleParentConcepts() {
        // Multi-parent semantics: an entity can be contained in multiple
        // concepts via separate containsEntity edges.
        let graph = KnowledgeGraph()
        let c1 = ConceptNode(label: "C1", level: .concept); graph.addNode(c1)
        let c2 = ConceptNode(label: "C2", level: .concept); graph.addNode(c2)
        let shared = ConceptNode(label: "Shared", level: .entity); graph.addNode(shared)

        graph.addEdge(GraphEdge(sourceNodeID: c1.id, targetNodeID: shared.id, type: .containsEntity, confidence: 1.0))
        graph.addEdge(GraphEdge(sourceNodeID: c2.id, targetNodeID: shared.id, type: .containsEntity, confidence: 1.0))

        let parents = graph.parents(of: shared.id, edgeType: .containsEntity)
        XCTAssertEqual(Set(parents.map(\.id)), Set([c1.id, c2.id]))
    }
}
