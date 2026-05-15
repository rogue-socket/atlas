//
//  KnowledgeGraph.swift
//  Atlas
//
//  Core knowledge graph model containing concepts, edges, and source anchors
//

import SwiftUI
import PDFKit
import Observation
import os.log

private let log = Logger(subsystem: "com.atlas.pdf", category: "graph")

// MARK: - Source Anchor
struct SourceAnchor: Identifiable, Codable, Hashable {
    let id: UUID
    let documentURL: URL
    let pageIndex: Int
    let boundingBox: CGRect
    let textSnippet: String

    init(id: UUID = UUID(), documentURL: URL, pageIndex: Int, boundingBox: CGRect, textSnippet: String) {
        self.id = id
        self.documentURL = documentURL
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
        self.textSnippet = textSnippet
    }
}

// MARK: - Concept Node
struct ConceptNode: Identifiable, Hashable {
    let id: UUID
    var label: String
    var type: ConceptType
    var summary: String?
    var sourceAnchors: [SourceAnchor]
    var readingState: ReadingState
    var expansionState: ExpansionState
    var confidence: Double
    var isPinned: Bool
    var position: CGPoint?
    var level: NodeLevel
    var highlightColorIndex: Int?
    /// Wall-clock timestamp of the last mutation. Used by `GraphStore` on load
    /// to reconcile divergence when the same node appears in multiple
    /// per-document graph files (multi-anchor entities) — latest write wins.
    var lastModified: Date

    init(
        id: UUID = UUID(),
        label: String,
        type: ConceptType = .concept,
        summary: String? = nil,
        sourceAnchors: [SourceAnchor] = [],
        readingState: ReadingState = .unseen,
        expansionState: ExpansionState = .collapsed,
        confidence: Double = 1.0,
        isPinned: Bool = false,
        position: CGPoint? = nil,
        level: NodeLevel = .concept,
        highlightColorIndex: Int? = nil,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.summary = summary
        self.sourceAnchors = sourceAnchors
        self.readingState = readingState
        self.expansionState = expansionState
        self.confidence = confidence
        self.isPinned = isPinned
        self.position = position
        self.level = level
        self.highlightColorIndex = highlightColorIndex
        self.lastModified = lastModified
    }
}

// MARK: - ConceptNode Codable
// No backwards compatibility with pre-4-level-migration graphs.
// Old fields (hierarchyLevel, isDocumentSummary, parentConceptID,
// parentChapterID) are dropped; their roles are now expressed via the
// `level` field (4 cases) and containment edges
// (containsChapter / containsConcept / containsEntity).
extension ConceptNode: Codable {
    enum CodingKeys: String, CodingKey {
        case id, label, type, summary, sourceAnchors, readingState, expansionState
        case confidence, isPinned, position
        case level, highlightColorIndex, lastModified
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        type = try c.decode(ConceptType.self, forKey: .type)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        sourceAnchors = try c.decode([SourceAnchor].self, forKey: .sourceAnchors)
        readingState = try c.decode(ReadingState.self, forKey: .readingState)
        expansionState = try c.decode(ExpansionState.self, forKey: .expansionState)
        confidence = try c.decode(Double.self, forKey: .confidence)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position)
        level = try c.decode(NodeLevel.self, forKey: .level)
        highlightColorIndex = try c.decodeIfPresent(Int.self, forKey: .highlightColorIndex)
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
    }
}

// MARK: - Graph Edge
struct GraphEdge: Identifiable, Codable, Hashable {
    let id: UUID
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var type: EdgeType
    var confidence: Double
    var label: String?

    init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        targetNodeID: UUID,
        type: EdgeType,
        confidence: Double = 1.0,
        label: String? = nil
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.type = type
        self.confidence = confidence
        self.label = label
    }
}

// MARK: - Knowledge Graph
// `nonisolated` to opt out of the project-wide MainActor default
// (SWIFT_DEFAULT_ACTOR_ISOLATION). KnowledgeGraph is a pure data
// model (no AppKit, no @Published, consumed via @Observable / @State);
// without this, MainActor-isolated deinit double-frees task-local
// storage on macOS 26.3. Same pattern as QuadTreeNode (commit c8cad91).
@Observable
nonisolated class KnowledgeGraph {
    private(set) var nodes: [UUID: ConceptNode] = [:]
    private(set) var edges: [UUID: GraphEdge] = [:]
    var documentProcessingState: [URL: ProcessingState] = [:]

    // Adjacency list: nodeID -> set of edgeIDs
    private(set) var adjacency: [UUID: Set<UUID>] = [:]

    // Lowercased-label → node ID. Kept in sync by insert/removeNode/updateNode/clear/merge.
    private var labelIndex: [String: UUID] = [:]

    var nodeCount: Int { nodes.count }
    var edgeCount: Int { edges.count }
    var expansionGeneration: Int = 0

    var allNodes: [ConceptNode] {
        Array(nodes.values)
    }

    var allEdges: [GraphEdge] {
        Array(edges.values)
    }

    // MARK: - Node Operations

    func addNode(_ node: ConceptNode) {
        insert(node)
        log.info("[Graph] addNode: \"\(node.label)\" (total: \(self.nodes.count))")
    }

    private func insert(_ node: ConceptNode) {
        nodes[node.id] = node
        if adjacency[node.id] == nil {
            adjacency[node.id] = []
        }
        labelIndex[node.label.lowercased()] = node.id
    }

    func removeNode(_ nodeID: UUID) {
        if let removed = nodes.removeValue(forKey: nodeID) {
            labelIndex.removeValue(forKey: removed.label.lowercased())
        }
        // Remove all connected edges
        if let edgeIDs = adjacency[nodeID] {
            for edgeID in edgeIDs {
                if let edge = edges[edgeID] {
                    let otherNodeID = edge.sourceNodeID == nodeID ? edge.targetNodeID : edge.sourceNodeID
                    adjacency[otherNodeID]?.remove(edgeID)
                }
                edges.removeValue(forKey: edgeID)
            }
        }
        adjacency.removeValue(forKey: nodeID)
    }

    func updateNode(_ node: ConceptNode) {
        if let old = nodes[node.id], old.label != node.label {
            labelIndex.removeValue(forKey: old.label.lowercased())
            labelIndex[node.label.lowercased()] = node.id
        }
        nodes[node.id] = node
    }

    func node(for id: UUID) -> ConceptNode? {
        nodes[id]
    }

    func node(matching label: String) -> ConceptNode? {
        guard let id = labelIndex[label.lowercased()] else { return nil }
        return nodes[id]
    }

    // MARK: - Edge Operations

    func addEdge(_ edge: GraphEdge) {
        edges[edge.id] = edge
        adjacency[edge.sourceNodeID, default: []].insert(edge.id)
        adjacency[edge.targetNodeID, default: []].insert(edge.id)
    }

    func removeEdge(_ edgeID: UUID) {
        if let edge = edges[edgeID] {
            adjacency[edge.sourceNodeID]?.remove(edgeID)
            adjacency[edge.targetNodeID]?.remove(edgeID)
        }
        edges.removeValue(forKey: edgeID)
    }

    // MARK: - Query Operations

    func edges(for nodeID: UUID) -> [GraphEdge] {
        guard let edgeIDs = adjacency[nodeID] else { return [] }
        return edgeIDs.compactMap { edges[$0] }
    }

    func neighbors(of nodeID: UUID) -> [ConceptNode] {
        let connectedEdges = edges(for: nodeID)
        let neighborIDs = connectedEdges.map { edge in
            edge.sourceNodeID == nodeID ? edge.targetNodeID : edge.sourceNodeID
        }
        return neighborIDs.compactMap { nodes[$0] }
    }

    func degree(of nodeID: UUID) -> Int {
        adjacency[nodeID]?.count ?? 0
    }

    func nodes(forDocument url: URL) -> [ConceptNode] {
        allNodes.filter { node in
            node.sourceAnchors.contains { $0.documentURL == url }
        }
    }

    func nodes(forPage pageIndex: Int, in documentURL: URL) -> [ConceptNode] {
        allNodes.filter { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL && $0.pageIndex == pageIndex }
        }
    }

    // MARK: - Hierarchy Queries

    func conceptNodes() -> [ConceptNode] {
        allNodes.filter { $0.level == .concept }
    }

    func nodes(at level: NodeLevel) -> [ConceptNode] {
        allNodes.filter { $0.level == level }
    }

    /// Children of `nodeID` via the structural containment edge appropriate
    /// for the parent's level (Document → Chapter, Chapter → Concept,
    /// Concept → Entity). Returns nodes that this node *contains* (i.e.
    /// outgoing containment edges where `sourceNodeID == nodeID`).
    func entities(for conceptID: UUID) -> [ConceptNode] {
        containedChildren(of: conceptID, edgeType: .containsEntity)
    }

    func parentConcept(of entityID: UUID) -> ConceptNode? {
        // Entities may have multiple parent concepts under the 4-level model
        // (a concept can be contained in multiple chapters; an entity can
        // belong to multiple concepts). This helper returns the *first* such
        // parent for compatibility — callers that need the full set should
        // use `parents(of:edgeType:)` directly.
        parents(of: entityID, edgeType: .containsEntity).first
    }

    /// Outgoing containment children: nodes where an edge of `edgeType`
    /// exists from `nodeID` (as source) to the child.
    func containedChildren(of nodeID: UUID, edgeType: EdgeType) -> [ConceptNode] {
        guard let edgeIDs = adjacency[nodeID] else { return [] }
        return edgeIDs.compactMap { edgeID -> ConceptNode? in
            guard let edge = edges[edgeID],
                  edge.type == edgeType,
                  edge.sourceNodeID == nodeID else { return nil }
            return nodes[edge.targetNodeID]
        }
    }

    /// Incoming containment parents: nodes that contain `nodeID` via
    /// `edgeType` edges (i.e. `targetNodeID == nodeID`).
    func parents(of nodeID: UUID, edgeType: EdgeType) -> [ConceptNode] {
        guard let edgeIDs = adjacency[nodeID] else { return [] }
        return edgeIDs.compactMap { edgeID -> ConceptNode? in
            guard let edge = edges[edgeID],
                  edge.type == edgeType,
                  edge.targetNodeID == nodeID else { return nil }
            return nodes[edge.sourceNodeID]
        }
    }

    func childNodes(of nodeID: UUID) -> [ConceptNode] {
        // Returns children via *any* containment edge — used by renderer
        // hit-testing where the specific edge type doesn't matter.
        guard let edgeIDs = adjacency[nodeID] else { return [] }
        return edgeIDs.compactMap { edgeID -> ConceptNode? in
            guard let edge = edges[edgeID],
                  edge.type.isContainment,
                  edge.sourceNodeID == nodeID else { return nil }
            return nodes[edge.targetNodeID]
        }
    }

    func toggleExpansion(_ nodeID: UUID) {
        guard var node = nodes[nodeID] else { return }
        node.expansionState = (node.expansionState == .expanded) ? .collapsed : .expanded
        nodes[nodeID] = node
        expansionGeneration += 1
    }

    func expandAll() {
        for id in nodes.keys {
            nodes[id]?.expansionState = .expanded
        }
        expansionGeneration += 1
    }

    func collapseAll() {
        for id in nodes.keys {
            nodes[id]?.expansionState = .collapsed
        }
        expansionGeneration += 1
    }

    func hasChildren(_ nodeID: UUID) -> Bool {
        guard let edgeIDs = adjacency[nodeID] else { return false }
        return edgeIDs.contains { edgeID in
            guard let edge = edges[edgeID] else { return false }
            return edge.type.isContainment && edge.sourceNodeID == nodeID
        }
    }

    // MARK: - Highlight Color Assignment

    var highlightColorCounter: Int = 0

    func nextHighlightColorIndex() -> Int {
        let index = highlightColorCounter
        highlightColorCounter = (highlightColorCounter + 1) % SourceHighlightPalette.colors.count
        return index
    }

    // MARK: - Bulk Operations

    func clear() {
        nodes.removeAll()
        edges.removeAll()
        adjacency.removeAll()
        labelIndex.removeAll()
        documentProcessingState.removeAll()
        highlightColorCounter = 0
    }

    func merge(from other: KnowledgeGraph) {
        for node in other.nodes.values {
            insert(node)
        }
        for edge in other.edges.values {
            addEdge(edge)
        }
        for (url, state) in other.documentProcessingState {
            documentProcessingState[url] = state
        }
    }
}

// MARK: - Codable Support
extension KnowledgeGraph {
    struct CodableRepresentation: Codable {
        let nodes: [ConceptNode]
        let edges: [GraphEdge]
        let documentProcessingState: [String: ProcessingState]
    }

    func encode() throws -> Data {
        let rep = CodableRepresentation(
            nodes: allNodes,
            edges: allEdges,
            documentProcessingState: documentProcessingState.reduce(into: [:]) { result, pair in
                result[pair.key.absoluteString] = pair.value
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rep)
    }

    func decode(from data: Data) throws {
        let decoder = JSONDecoder()
        let rep = try decoder.decode(CodableRepresentation.self, from: data)

        clear()
        for node in rep.nodes {
            addNode(node)
        }
        for edge in rep.edges {
            addEdge(edge)
        }
        for (urlString, state) in rep.documentProcessingState {
            if let url = URL(string: urlString) {
                documentProcessingState[url] = state
            }
        }
    }
}
