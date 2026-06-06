import XCTest
@testable import pdf_app1

/// Tests for `BidirectionalSyncManager` — the PDF↔Map bridge.
/// Covers the synchronous public surface: setGraph/setDocumentURL,
/// onPageChanged → activeNodeID resolution, navigateToNode → pending
/// anchor + callback invocation, onHighlightCreated state mutations.
final class BidirectionalSyncManagerTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/sync-test.pdf")

    private func anchor(page: Int, bounds: CGRect = .zero) -> SourceAnchor {
        SourceAnchor(documentURL: url, pageIndex: page, boundingBox: bounds, textSnippet: "")
    }

    private func setup(_ graph: KnowledgeGraph) -> BidirectionalSyncManager {
        let mgr = BidirectionalSyncManager()
        mgr.setGraph(graph)
        mgr.setDocumentURL(url)
        return mgr
    }

    // MARK: - PDF → Map sync

    func test_onPageChanged_setsActiveNodeWhenPageHasMatchingAnchor() {
        let graph = KnowledgeGraph()
        let node = ConceptNode(label: "X", sourceAnchors: [anchor(page: 3)], level: .concept)
        graph.addNode(node)
        let mgr = setup(graph)

        mgr.onPageChanged(pageIndex: 3)
        XCTAssertEqual(mgr.activeNodeID, node.id)
        XCTAssertEqual(mgr.currentPageIndex, 3)
    }

    func test_onPageChanged_fallsBackToAdjacentPageWhenNoExactMatch() {
        let graph = KnowledgeGraph()
        let node = ConceptNode(label: "X", sourceAnchors: [anchor(page: 4)], level: .concept)
        graph.addNode(node)
        let mgr = setup(graph)

        mgr.onPageChanged(pageIndex: 3)
        XCTAssertEqual(mgr.activeNodeID, node.id, "Adjacency window of ±1 should match")
    }

    func test_onPageChanged_clearsActiveWhenNoNodeOnOrNearPage() {
        let graph = KnowledgeGraph()
        graph.addNode(ConceptNode(label: "Far", sourceAnchors: [anchor(page: 99)], level: .concept))
        let mgr = setup(graph)
        mgr.activeNodeID = UUID()  // stale

        mgr.onPageChanged(pageIndex: 0)
        XCTAssertNil(mgr.activeNodeID)
    }

    func test_onPageChanged_noGraphOrURL_clearsActive() {
        let mgr = BidirectionalSyncManager()
        mgr.activeNodeID = UUID()
        mgr.onPageChanged(pageIndex: 0)
        XCTAssertNil(mgr.activeNodeID, "No graph or doc URL → no active node")
    }

    // MARK: - Map → PDF sync

    func test_navigateToNode_invokesCallbackWithAnchorPageAndBox() {
        let graph = KnowledgeGraph()
        let bounds = CGRect(x: 10, y: 20, width: 30, height: 40)
        let node = ConceptNode(label: "Target",
                               sourceAnchors: [anchor(page: 5, bounds: bounds)],
                               level: .concept)
        graph.addNode(node)
        let mgr = setup(graph)

        var seenPage: Int?
        var seenBox: CGRect?
        mgr.navigateToPDFPage = { page, box in
            seenPage = page
            seenBox = box
        }

        mgr.navigateToNode(node.id)
        XCTAssertEqual(seenPage, 5)
        XCTAssertEqual(seenBox, bounds)
        XCTAssertEqual(mgr.pendingNavigationAnchor?.pageIndex, 5)
    }

    func test_navigateToNode_missingNode_isNoOp() {
        let mgr = setup(KnowledgeGraph())
        var called = false
        mgr.navigateToPDFPage = { _, _ in called = true }
        mgr.navigateToNode(UUID())
        XCTAssertFalse(called)
        XCTAssertNil(mgr.pendingNavigationAnchor)
    }

    func test_navigateToNode_picksFirstAnchorForOtherDocWhenNoneMatchCurrent() {
        // Document URL is `url`, but node's only anchor is in `otherURL`.
        // Manager should still pick the first available anchor and navigate.
        let otherURL = URL(fileURLWithPath: "/tmp/other.pdf")
        let otherAnchor = SourceAnchor(documentURL: otherURL, pageIndex: 7,
                                       boundingBox: .zero, textSnippet: "")
        let graph = KnowledgeGraph()
        let node = ConceptNode(label: "Cross-doc", sourceAnchors: [otherAnchor], level: .concept)
        graph.addNode(node)
        let mgr = setup(graph)

        var seenPage: Int?
        mgr.navigateToPDFPage = { page, _ in seenPage = page }
        mgr.navigateToNode(node.id)
        XCTAssertEqual(seenPage, 7)
    }

    // MARK: - Highlight / annotation events

    func test_onHighlightCreated_marksOverlappingNodesHighlightedAndPinned() {
        let bounds = CGRect(x: 100, y: 100, width: 200, height: 50)
        let overlapping = CGRect(x: 120, y: 110, width: 50, height: 20)  // intersects
        let nonOverlap = CGRect(x: 1, y: 1, width: 5, height: 5)

        let graph = KnowledgeGraph()
        let nodeA = ConceptNode(
            label: "A",
            sourceAnchors: [SourceAnchor(documentURL: url, pageIndex: 1,
                                         boundingBox: bounds, textSnippet: "")],
            level: .concept
        )
        let nodeB = ConceptNode(
            label: "B",
            sourceAnchors: [SourceAnchor(documentURL: url, pageIndex: 1,
                                         boundingBox: nonOverlap, textSnippet: "")],
            level: .concept
        )
        graph.addNode(nodeA)
        graph.addNode(nodeB)
        let mgr = setup(graph)

        mgr.onHighlightCreated(pageIndex: 1, boundingBox: overlapping, text: "selected")

        XCTAssertEqual(graph.node(for: nodeA.id)?.readingState, .highlighted)
        XCTAssertEqual(graph.node(for: nodeA.id)?.isPinned, true)
        XCTAssertNotEqual(graph.node(for: nodeB.id)?.readingState, .highlighted,
                          "Non-overlapping node must not be promoted")
    }

    func test_onAnnotationCreated_marksAllPageNodesAnnotated() {
        let graph = KnowledgeGraph()
        let a = ConceptNode(label: "A", sourceAnchors: [anchor(page: 2)], level: .concept)
        let b = ConceptNode(label: "B", sourceAnchors: [anchor(page: 2)], level: .concept)
        let other = ConceptNode(label: "Other", sourceAnchors: [anchor(page: 99)], level: .concept)
        graph.addNode(a); graph.addNode(b); graph.addNode(other)
        let mgr = setup(graph)

        mgr.onAnnotationCreated(pageIndex: 2, text: "note")

        XCTAssertEqual(graph.node(for: a.id)?.readingState, .annotated)
        XCTAssertEqual(graph.node(for: b.id)?.readingState, .annotated)
        XCTAssertNotEqual(graph.node(for: other.id)?.readingState, .annotated,
                          "Different page → no change")
    }
}
