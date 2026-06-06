import XCTest
import PDFKit

@testable import pdf_app1

final class HighlightSyncBridgeTests: XCTestCase {

    private func makePageWithText(_ text: String) -> PDFPage? {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 612, height: 792)
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.textStorage?.setAttributedString(attributed)

        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = false
        printOp.showsProgressPanel = false

        // Use PDF representation from the view directly
        guard let pdfData = textView.dataWithPDF(inside: textView.bounds) as Data?,
              let doc = PDFDocument(data: pdfData),
              let page = doc.page(at: 0) else {
            return nil
        }
        return page
    }

    func testFindPassageRects_snippetNotFound_returnsNil() {
        let text = "Photosynthesis is the process by which plants convert sunlight into energy."
        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: "mitochondria powerhouse", on: page)

        XCTAssertNil(rects, "Should return nil when snippet is not on the page")
    }

    func testFindPassageRects_emptySnippet_returnsNil() {
        let text = "Some content on the page."
        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: "", on: page)

        XCTAssertNil(rects, "Should return nil for empty snippet")
    }

    func testFindPassageRects_snippetFound_returnsNonNilRects() {
        let text = "Photosynthesis is the process by which plants convert sunlight into energy."
        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: "plants convert sunlight", on: page)

        XCTAssertNotNil(rects, "Should find the snippet on the page")
        XCTAssertFalse(rects!.isEmpty, "Should return at least one rect")
        for rect in rects! {
            XCTAssertFalse(rect.isEmpty, "Each rect should be non-empty")
        }
    }

    func testFindPassageRects_multiLineSnippet_returnsMultipleRects() {
        let lines = (1...20).map { "Line \($0): This is filler text that extends the content across multiple lines in the PDF document." }
        let text = lines.joined(separator: " ")
        let snippet = "Line 5: This is filler text that extends the content across multiple lines in the PDF document. Line 6: This is filler text that extends the content across multiple lines in the PDF document."

        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: snippet, on: page)

        XCTAssertNotNil(rects, "Should find multi-line snippet")
        XCTAssertGreaterThan(rects!.count, 1, "Multi-line text should produce multiple rects")
    }

    func testFindPassageRects_caseInsensitive() {
        let text = "Photosynthesis is the process by which plants convert sunlight into energy."
        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: "PLANTS CONVERT SUNLIGHT", on: page)

        XCTAssertNotNil(rects, "Case-insensitive search should find the snippet")
    }

    func testFindPassageRects_fallbackBoundsAreLineSizedNotPageSized() {
        let text = "Meridian Biofab converts pilot manufacturing notes into validated release criteria."
        guard let page = makePageWithText(text) else {
            XCTFail("Could not create test PDF page")
            return
        }

        let rects = HighlightSyncBridge.findPassageRects(snippet: "pilot manufacturing notes", on: page)

        XCTAssertNotNil(rects, "Text fallback should find line-level selection rects")
        let combined = rects!.reduce(CGRect.null) { $0.union($1) }
        let pageBounds = page.bounds(for: .mediaBox)
        XCTAssertLessThan(combined.width * combined.height, pageBounds.width * pageBounds.height * 0.25)
    }

    // MARK: - Apply highlights against fresh document instance

    private func makePDFDocument(text: String = "Sample test content for highlights.") -> PDFDocument? {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.string = text
        guard let pdfData = textView.dataWithPDF(inside: textView.bounds) as Data? else { return nil }
        return PDFDocument(data: pdfData)
    }

    private func makeGraphWithNodes(url: URL, count: Int) -> KnowledgeGraph {
        let graph = KnowledgeGraph()
        for i in 0..<count {
            let anchor = SourceAnchor(
                documentURL: url,
                pageIndex: 0,
                boundingBox: CGRect(x: 10 + CGFloat(i) * 50, y: 10, width: 40, height: 20),
                textSnippet: "snippet \(i)"
            )
            let node = ConceptNode(
                label: "concept \(i)",
                sourceAnchors: [anchor],
                highlightColorIndex: 0
            )
            graph.addNode(node)
        }
        return graph
    }

    private func makeGraphWithAnchor(url: URL, bounds: CGRect) -> KnowledgeGraph {
        let graph = KnowledgeGraph()
        let anchor = SourceAnchor(
            documentURL: url,
            pageIndex: 0,
            boundingBox: bounds,
            textSnippet: "snippet"
        )
        let node = ConceptNode(
            label: "concept",
            sourceAnchors: [anchor],
            highlightColorIndex: 0
        )
        graph.addNode(node)
        return graph
    }

    @MainActor
    func testApplyPersistentHighlights_skipsFullPageSourceAnchors() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let graph = makeGraphWithAnchor(url: url, bounds: page.bounds(for: .mediaBox))

        let result = bridge.applyPersistentHighlights(document: doc, graph: graph, documentURL: url)

        XCTAssertTrue(result.annotationsByNode.isEmpty, "Full-page fallback anchors should not become persistent highlights")
        XCTAssertEqual(result.anchorsSeen, 1)
        XCTAssertEqual(result.anchorsSkipped, 1)
        XCTAssertFalse(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
    }

    @MainActor
    func testApplyPersistentHighlights_skipsPageOnlyZeroBoundsSourceAnchors() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let graph = makeGraphWithAnchor(url: url, bounds: .zero)

        let result = bridge.applyPersistentHighlights(document: doc, graph: graph, documentURL: url)

        XCTAssertTrue(result.annotationsByNode.isEmpty, "Page-only anchors should navigate/export by page without persistent highlights")
        XCTAssertEqual(result.anchorsSeen, 1)
        XCTAssertEqual(result.anchorsSkipped, 1)
        XCTAssertFalse(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
    }

    @MainActor
    func testApplyPersistentHighlights_keepsLineSizedSourceAnchors() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let graph = makeGraphWithAnchor(url: url, bounds: CGRect(x: 24, y: 24, width: 120, height: 18))

        let result = bridge.applyPersistentHighlights(document: doc, graph: graph, documentURL: url)

        XCTAssertEqual(result.annotationsByNode.values.flatMap { $0 }.count, 1)
        XCTAssertEqual(result.anchorsSeen, 1)
        XCTAssertEqual(result.anchorsSkipped, 0)
        XCTAssertEqual(result.annotationsAdded, 1)
        XCTAssertTrue(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
    }

    @MainActor
    func testApplyPersistentHighlights_removesSavedFullPageAtlasAnnotations() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let stale = PDFAnnotation(bounds: page.bounds(for: .mediaBox), forType: .highlight, withProperties: nil)
        stale.contents = "\(HighlightSyncBridge.atlasContentsPrefix)\(UUID().uuidString)"
        page.addAnnotation(stale)
        let graph = makeGraphWithAnchor(url: url, bounds: CGRect(x: 24, y: 24, width: 120, height: 18))

        let result = bridge.applyPersistentHighlights(document: doc, graph: graph, documentURL: url)

        XCTAssertEqual(result.annotationsRemoved, 1)
        XCTAssertEqual(result.annotationsAdded, 1)
        XCTAssertFalse(page.annotations.contains { annotation in
            annotation.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true &&
                annotation.bounds == page.bounds(for: .mediaBox)
        })
        XCTAssertEqual(page.annotations.filter { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true }.count, 1)
    }

    @MainActor
    func testApplyPersistentHighlights_adoptsSavedValidAtlasAnnotationsWithoutDuplicating() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        let bounds = CGRect(x: 24, y: 24, width: 120, height: 18)
        let graph = makeGraphWithAnchor(url: url, bounds: bounds)
        guard let node = graph.allNodes.first,
              let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create graph and PDFDocument")
            return
        }
        let saved = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        saved.contents = "\(HighlightSyncBridge.atlasContentsPrefix)\(node.id.uuidString)"
        page.addAnnotation(saved)

        let result = bridge.applyPersistentHighlights(document: doc, graph: graph, documentURL: url)

        XCTAssertEqual(result.annotationsRemoved, 0)
        XCTAssertEqual(result.annotationsAdded, 0)
        XCTAssertEqual(page.annotations.filter { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true }.count, 1)
    }

    func testDetachAtlasAnnotations_removesAndRestoresOnlyAtlasAnnotations() {
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let atlas = PDFAnnotation(bounds: CGRect(x: 24, y: 24, width: 120, height: 18), forType: .highlight, withProperties: nil)
        atlas.contents = "\(HighlightSyncBridge.atlasContentsPrefix)\(UUID().uuidString)"
        let user = PDFAnnotation(bounds: CGRect(x: 48, y: 48, width: 80, height: 18), forType: .highlight, withProperties: nil)
        user.contents = "user annotation"
        page.addAnnotation(atlas)
        page.addAnnotation(user)

        let detached = HighlightSyncBridge.detachAtlasAnnotations(from: doc)

        XCTAssertEqual(detached.count, 1)
        XCTAssertFalse(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
        XCTAssertTrue(page.annotations.contains { $0.contents == "user annotation" })

        HighlightSyncBridge.restoreAtlasAnnotations(detached)

        XCTAssertTrue(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
        XCTAssertTrue(page.annotations.contains { $0.contents == "user annotation" })
    }

    func testDetachAtlasAnnotations_preventsAtlasAnnotationsFromPersistingOnWrite() {
        guard let doc = makePDFDocument(),
              let page = doc.page(at: 0) else {
            XCTFail("Could not create PDFDocument")
            return
        }
        let atlas = PDFAnnotation(bounds: CGRect(x: 24, y: 24, width: 120, height: 18), forType: .highlight, withProperties: nil)
        atlas.contents = "\(HighlightSyncBridge.atlasContentsPrefix)\(UUID().uuidString)"
        let user = PDFAnnotation(bounds: CGRect(x: 48, y: 48, width: 80, height: 18), forType: .highlight, withProperties: nil)
        user.contents = "user annotation"
        page.addAnnotation(atlas)
        page.addAnnotation(user)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-highlight-save-\(UUID().uuidString).pdf")
        let detached = HighlightSyncBridge.detachAtlasAnnotations(from: doc)
        let success = doc.write(to: tempURL)
        HighlightSyncBridge.restoreAtlasAnnotations(detached)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        XCTAssertTrue(success)
        guard let savedDoc = PDFDocument(url: tempURL),
              let savedPage = savedDoc.page(at: 0) else {
            XCTFail("Could not reopen saved PDF")
            return
        }
        XCTAssertFalse(savedPage.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
        XCTAssertTrue(savedPage.annotations.contains { $0.contents == "user annotation" })
        XCTAssertTrue(page.annotations.contains { $0.contents?.hasPrefix(HighlightSyncBridge.atlasContentsPrefix) == true })
    }

    // Reopen silent-failure repro: when the user closes a doc and reopens
    // it (or any flow that yields a fresh PDFDocument instance for the
    // same URL), the bridge's `activeAnnotationMap` still holds entries
    // whose annotations are attached to the prior (released) document.
    // The diff puts all desired keys in `kept`, no new annotations are
    // added, and highlights silently fail to appear on the new document.
    @MainActor
    func testApplyPersistentHighlights_freshDocumentInstance_attachesAnnotationsToNewDocument() {
        let bridge = HighlightSyncBridge()
        let url = URL(fileURLWithPath: "/test/doc-\(UUID().uuidString).pdf")
        let graph = makeGraphWithNodes(url: url, count: 3)

        guard let doc1 = makePDFDocument() else {
            XCTFail("Could not create first PDFDocument")
            return
        }
        let result1 = bridge.applyPersistentHighlights(document: doc1, graph: graph, documentURL: url)
        XCTAssertEqual(result1.annotationsByNode.values.flatMap { $0 }.count, 3, "Initial apply should attach 3 annotations")

        guard let doc2 = makePDFDocument() else {
            XCTFail("Could not create second PDFDocument")
            return
        }
        let result2 = bridge.applyPersistentHighlights(document: doc2, graph: graph, documentURL: url)
        let annotationsOnDoc2 = result2.annotationsByNode.values.flatMap { $0 }

        XCTAssertEqual(annotationsOnDoc2.count, 3, "Re-apply on fresh document should attach 3 annotations")
        for annotation in annotationsOnDoc2 {
            XCTAssertNotNil(annotation.page, "Annotation should have an attached page")
            XCTAssertTrue(annotation.page?.document === doc2,
                          "Annotation should be attached to the new document, not the stale one")
        }
    }
}
