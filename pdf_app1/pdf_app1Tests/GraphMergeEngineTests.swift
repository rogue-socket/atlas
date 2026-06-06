import XCTest
@testable import pdf_app1

/// Tests for `Atlas/Persistence/GraphMergeEngine.swift`:
///   - Levenshtein-based proposal finder (`findMergeProposals`)
///   - `executeMerge` (anchor merge, edge re-pointing, entity re-parenting)
///   - `computeCorrelationStats` (cross-document edge tallying)
///   - `DocumentPairID` canonical ordering
final class GraphMergeEngineTests: XCTestCase {

    private let urlA = URL(fileURLWithPath: "/tmp/merge-A.pdf")
    private let urlB = URL(fileURLWithPath: "/tmp/merge-B.pdf")
    private let urlC = URL(fileURLWithPath: "/tmp/merge-C.pdf")

    private func anchor(_ url: URL, page: Int = 0) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: .zero, textSnippet: "")
    }

    // MARK: - DocumentPairID

    func test_documentPairID_isCanonicalRegardlessOfOrder() {
        let p1 = DocumentPairID(urlA, urlB)
        let p2 = DocumentPairID(urlB, urlA)
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(p1.hashValue, p2.hashValue)
    }

    func test_documentPairID_sortsByAbsoluteString() {
        let pair = DocumentPairID(urlB, urlA)
        XCTAssertLessThan(pair.urlA.absoluteString, pair.urlB.absoluteString)
    }

    // MARK: - findMergeProposals

    func test_findMergeProposals_exactMatchProposesPair() {
        let newG = KnowledgeGraph()
        newG.addNode(ConceptNode(label: "Helena Vargas", sourceAnchors: [anchor(urlB)]))
        let oldG = KnowledgeGraph()
        oldG.addNode(ConceptNode(label: "Helena Vargas", sourceAnchors: [anchor(urlA)]))

        let proposals = GraphMergeEngine().findMergeProposals(newDocumentGraph: newG, projectGraph: oldG)
        XCTAssertEqual(proposals.count, 1)
        let p = proposals.first!
        XCTAssertGreaterThan(p.similarity, 0.95)
        XCTAssertTrue(p.reason.contains("Exact"))
    }

    func test_findMergeProposals_similarLabels_proposeIfAboveThreshold() {
        let newG = KnowledgeGraph()
        newG.addNode(ConceptNode(label: "Neural Network", sourceAnchors: [anchor(urlB)]))
        let oldG = KnowledgeGraph()
        oldG.addNode(ConceptNode(label: "Neural Networks", sourceAnchors: [anchor(urlA)]))
        // 1 edit / 15 chars → ~93% similarity, above the 0.7 threshold.

        let proposals = GraphMergeEngine().findMergeProposals(newDocumentGraph: newG, projectGraph: oldG)
        XCTAssertEqual(proposals.count, 1)
        XCTAssertLessThan(proposals[0].similarity, 0.95)
        XCTAssertGreaterThan(proposals[0].similarity, 0.7)
    }

    func test_findMergeProposals_belowThreshold_yieldsNoProposal() {
        let newG = KnowledgeGraph()
        newG.addNode(ConceptNode(label: "Cats and Dogs", sourceAnchors: [anchor(urlB)]))
        let oldG = KnowledgeGraph()
        oldG.addNode(ConceptNode(label: "Linear Algebra", sourceAnchors: [anchor(urlA)]))

        let proposals = GraphMergeEngine().findMergeProposals(newDocumentGraph: newG, projectGraph: oldG)
        XCTAssertTrue(proposals.isEmpty)
    }

    func test_findMergeProposals_sameDocumentAnchors_areSkipped() {
        // Both nodes anchored in the same doc — must not propose a merge with itself.
        let newG = KnowledgeGraph()
        newG.addNode(ConceptNode(label: "Topic", sourceAnchors: [anchor(urlA)]))
        let oldG = KnowledgeGraph()
        oldG.addNode(ConceptNode(label: "Topic", sourceAnchors: [anchor(urlA)]))

        let proposals = GraphMergeEngine().findMergeProposals(newDocumentGraph: newG, projectGraph: oldG)
        XCTAssertTrue(proposals.isEmpty, "Skip when both nodes share a document anchor")
    }

    func test_findMergeProposals_sortsByDescendingSimilarity() {
        // One exact match + one near match should come back exact-first.
        let newG = KnowledgeGraph()
        newG.addNode(ConceptNode(label: "Quasar",       sourceAnchors: [anchor(urlB)]))
        newG.addNode(ConceptNode(label: "Neural Net",   sourceAnchors: [anchor(urlB)]))
        let oldG = KnowledgeGraph()
        oldG.addNode(ConceptNode(label: "Quasar",       sourceAnchors: [anchor(urlA)]))
        oldG.addNode(ConceptNode(label: "Neural Nets",  sourceAnchors: [anchor(urlA)]))

        let proposals = GraphMergeEngine().findMergeProposals(newDocumentGraph: newG, projectGraph: oldG)
        XCTAssertEqual(proposals.count, 2)
        XCTAssertGreaterThanOrEqual(proposals[0].similarity, proposals[1].similarity)
        XCTAssertEqual(proposals[0].sourceNode.label, "Quasar")
    }

    // MARK: - executeMerge

    func test_executeMerge_combinesAnchorsAndPicksHigherConfidence() {
        let g = KnowledgeGraph()
        let source = ConceptNode(
            label: "Source Label",
            summary: "Source summary.",
            sourceAnchors: [anchor(urlB, page: 9)],
            confidence: 0.95,
            level: .concept
        )
        let target = ConceptNode(
            label: "Target Label",
            summary: nil,
            sourceAnchors: [anchor(urlA, page: 1)],
            confidence: 0.6,
            level: .concept
        )
        g.addNode(source); g.addNode(target)

        GraphMergeEngine().executeMerge(sourceNodeID: source.id, targetNodeID: target.id, in: g)

        // Source removed, target survives.
        XCTAssertNil(g.node(for: source.id))
        let merged = g.node(for: target.id)
        XCTAssertNotNil(merged)
        // Anchors combined.
        XCTAssertEqual(merged?.sourceAnchors.count, 2)
        // Empty target summary was filled in from source.
        XCTAssertEqual(merged?.summary, "Source summary.")
        // Higher confidence wins.
        XCTAssertEqual(merged?.confidence ?? 0, 0.95, accuracy: 0.001)
    }

    func test_executeMerge_redirectsExternalEdgesAndSkipsSelfLoops() {
        let g = KnowledgeGraph()
        let source = ConceptNode(label: "S", level: .concept); g.addNode(source)
        let target = ConceptNode(label: "T", level: .concept); g.addNode(target)
        let other  = ConceptNode(label: "O", level: .concept); g.addNode(other)

        // Edge from external `other` → source should re-point to target.
        g.addEdge(GraphEdge(sourceNodeID: other.id, targetNodeID: source.id, type: .uses))
        // Edge source → target — would create a self-loop after merge; must be skipped.
        g.addEdge(GraphEdge(sourceNodeID: source.id, targetNodeID: target.id, type: .dependsOn))

        GraphMergeEngine().executeMerge(sourceNodeID: source.id, targetNodeID: target.id, in: g)

        let edges = g.allEdges
        // The pre-existing dependsOn edge (source → target) lives on directly,
        // since `graph.removeNode(source)` drops only edges that touched source.
        // The `uses` edge should now be rewritten to point at target.
        let usesEdges = edges.filter { $0.type == .uses }
        XCTAssertEqual(usesEdges.count, 1)
        XCTAssertEqual(usesEdges.first?.targetNodeID, target.id)
        // No self-loop.
        XCTAssertFalse(edges.contains { $0.sourceNodeID == target.id && $0.targetNodeID == target.id })
    }

    func test_executeMerge_reparentsChildEntitiesUnderTarget() {
        let g = KnowledgeGraph()
        let source = ConceptNode(label: "S", level: .concept); g.addNode(source)
        let target = ConceptNode(label: "T", level: .concept); g.addNode(target)
        let ent1 = ConceptNode(label: "E1", level: .entity); g.addNode(ent1)
        let ent2 = ConceptNode(label: "E2", level: .entity); g.addNode(ent2)

        g.addEdge(GraphEdge(sourceNodeID: source.id, targetNodeID: ent1.id, type: .containsEntity))
        g.addEdge(GraphEdge(sourceNodeID: source.id, targetNodeID: ent2.id, type: .containsEntity))
        // Target already contains ent2 — duplicate edge must be suppressed.
        g.addEdge(GraphEdge(sourceNodeID: target.id, targetNodeID: ent2.id, type: .containsEntity))

        GraphMergeEngine().executeMerge(sourceNodeID: source.id, targetNodeID: target.id, in: g)

        let targetEntities = Set(g.entities(for: target.id).map(\.id))
        XCTAssertEqual(targetEntities, Set([ent1.id, ent2.id]))
        // Exactly two containsEntity edges from target — no duplicates.
        let containmentFromTarget = g.allEdges.filter {
            $0.type == .containsEntity && $0.sourceNodeID == target.id
        }
        XCTAssertEqual(containmentFromTarget.count, 2)
    }

    func test_executeMerge_missingSourceOrTargetIsNoOp() {
        let g = KnowledgeGraph()
        let target = ConceptNode(label: "T"); g.addNode(target)
        let before = g.nodeCount
        GraphMergeEngine().executeMerge(sourceNodeID: UUID(), targetNodeID: target.id, in: g)
        XCTAssertEqual(g.nodeCount, before)
        GraphMergeEngine().executeMerge(sourceNodeID: target.id, targetNodeID: UUID(), in: g)
        XCTAssertEqual(g.nodeCount, before)
    }

    // MARK: - computeCorrelationStats

    func test_correlationStats_countsSharedNodesAndCrossDocEdges() {
        let g = KnowledgeGraph()
        let shared = ConceptNode(label: "Shared",
                                 sourceAnchors: [anchor(urlA), anchor(urlB)],
                                 level: .concept)
        let onlyA = ConceptNode(label: "OnlyA", sourceAnchors: [anchor(urlA)], level: .concept)
        let onlyB = ConceptNode(label: "OnlyB", sourceAnchors: [anchor(urlB)], level: .concept)
        let onlyC = ConceptNode(label: "OnlyC", sourceAnchors: [anchor(urlC)], level: .concept)
        g.addNode(shared); g.addNode(onlyA); g.addNode(onlyB); g.addNode(onlyC)

        // Cross-doc edge A→B (onlyA → onlyB).
        g.addEdge(GraphEdge(sourceNodeID: onlyA.id, targetNodeID: onlyB.id, type: .dependsOn))
        // Edge wholly inside doc A — shouldn't count for the A↔B pair.
        let onlyA2 = ConceptNode(label: "OnlyA2", sourceAnchors: [anchor(urlA)], level: .concept)
        g.addNode(onlyA2)
        g.addEdge(GraphEdge(sourceNodeID: onlyA.id, targetNodeID: onlyA2.id, type: .sameTopic))

        let stats = GraphMergeEngine().computeCorrelationStats(
            projectGraph: g,
            documentURLs: [urlA, urlB, urlC]
        )

        let abID = DocumentPairID(urlA, urlB)
        let acID = DocumentPairID(urlA, urlC)
        let bcID = DocumentPairID(urlB, urlC)

        XCTAssertEqual(stats[abID]?.sharedConceptCount, 1, "Shared multi-anchor node counts once for A↔B")
        XCTAssertEqual(stats[abID]?.edgeCountByType["dependsOn"], 1)
        XCTAssertEqual(stats[acID]?.sharedConceptCount, 0)
        XCTAssertNil(stats[acID]?.edgeCountByType["dependsOn"])
        XCTAssertEqual(stats[bcID]?.sharedConceptCount, 0)
    }
}
