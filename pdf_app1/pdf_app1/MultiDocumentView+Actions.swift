//
//  MultiDocumentView+Actions.swift
//  PDFViewer
//
//  Extraction, graph persistence, and chat actions for MultiDocumentView.
//

import Foundation
import PDFKit
import os.log

extension MultiDocumentView {
    var hasUnprocessedFiles: Bool {
        cachedProjectFiles.contains { url in
            let state = knowledgeGraph.documentProcessingState[url] ?? .unprocessed
            return state == .unprocessed || state == .failed
        }
    }

    func analyzeDocument(at url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        projectPipeline.processFullDocument(
            document: document, documentURL: url,
            graph: knowledgeGraph, aiService: aiService,
            mode: selectedMode
        )
    }

    func analyzeAllUnprocessed() {
        let unprocessed = cachedProjectFiles.filter { url in
            let state = knowledgeGraph.documentProcessingState[url] ?? .unprocessed
            return state == .unprocessed || state == .failed
        }
        guard !unprocessed.isEmpty else { return }

        Task {
            for url in unprocessed {
                guard let document = PDFDocument(url: url) else { continue }
                projectPipeline.processFullDocument(
                    document: document, documentURL: url,
                    graph: knowledgeGraph, aiService: aiService,
                    mode: selectedMode
                )
                while projectPipeline.isProcessing {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    func prepareSelectedDocument(_ document: PDFDocumentItem) {
        syncManager.setDocumentURL(document.url)
        syncManager.setGraph(knowledgeGraph)
        loadGraphIfNeeded(for: document.url)
    }

    func refreshPersistentHighlights(for documentURL: URL, reason: String) {
        guard let document = documentManager.documents.first(where: { $0.url == documentURL }) else {
            AtlasLogger.graph.info("[MultiDocView] refreshHighlights(\(reason)): \(documentURL.lastPathComponent) is not open")
            return
        }
        refreshPersistentHighlights(for: document, reason: reason)
    }

    @discardableResult
    func refreshPersistentHighlights(
        for document: PDFDocumentItem,
        reason: String
    ) -> PersistentHighlightRefreshResult {
        let result = highlightBridge.applyPersistentHighlights(
            document: document.document,
            graph: knowledgeGraph,
            documentURL: document.url
        )
        let liveAnnotations = result.annotationsByNode.values.reduce(0) { $0 + $1.count }
        AtlasLogger.graph.info("[MultiDocView] refreshHighlights(\(reason)): \(document.url.lastPathComponent) nodes=\(result.nodesInDocument) anchors=\(result.anchorsSeen) skipped=\(result.anchorsSkipped) added=\(result.annotationsAdded) removed=\(result.annotationsRemoved) live=\(liveAnnotations)")
        return result
    }

    func refreshPersistentHighlightsForOpenDocuments(reason: String) {
        for document in documentManager.documents {
            refreshPersistentHighlights(for: document, reason: reason)
        }
    }

    /// Load the persisted graph for `documentURL` and merge it into the
    /// in-memory project graph (preserving nodes loaded for other open
    /// tabs). Uses `mergeSubgraph` to defensively scope each per-doc file
    /// to its own anchored nodes — legacy bloated files written before B4
    /// get cleaned on load.
    func loadGraphIfNeeded(for documentURL: URL) {
        let alreadyHasNodes = knowledgeGraph.allNodes.contains { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        if alreadyHasNodes {
            AtlasLogger.graph.info("[MultiDocView] loadGraphIfNeeded: \(documentURL.lastPathComponent) already in-memory (\(knowledgeGraph.nodeCount) nodes), no-op")
            refreshPersistentHighlights(for: documentURL, reason: "selected-tab-already-loaded")
            return
        }

        guard let payload = GraphStore.shared.loadPayload(for: documentURL) else {
            AtlasLogger.graph.info("[MultiDocView] loadGraphIfNeeded: no saved graph for \(documentURL.lastPathComponent) — leaving in-memory graph unchanged")
            refreshPersistentHighlights(for: documentURL, reason: "selected-tab-no-graph")
            return
        }

        do {
            let merged = try knowledgeGraph.mergeSubgraph(from: payload, scopedTo: documentURL)
            AtlasLogger.graph.info("[MultiDocView] loadGraphIfNeeded: merged \(merged.nodeCount) nodes / \(merged.edgeCount) edges for \(documentURL.lastPathComponent) → \(knowledgeGraph.nodeCount) nodes, \(knowledgeGraph.edgeCount) edges total")
            refreshPersistentHighlights(for: documentURL, reason: "selected-tab-graph-loaded")
        } catch {
            AtlasLogger.graph.error("[MultiDocView] loadGraphIfNeeded: decode failed for \(documentURL.lastPathComponent): \(error)")
            refreshPersistentHighlights(for: documentURL, reason: "selected-tab-graph-load-failed")
        }
    }

    func toggleChat() {
        if chatViewModel == nil, let backend = aiService.createBackend() {
            let vm = ChatViewModel(
                backend: backend,
                graph: knowledgeGraph,
                documentURL: documentManager.selectedDocument?.url
            )
            if let doc = documentManager.selectedDocument {
                let extractor = TextExtractor()
                let pages = extractor.extractPages(from: doc.document, pageRange: 0..<doc.document.pageCount)
                vm.setPageText(pages.map { (pageIndex: $0.pageIndex, text: $0.fullText) })
            }
            chatViewModel = vm
        }
        isChatVisible.toggle()
        if isChatVisible && paneMode == .pdfOnly {
            paneMode = .split
        }
    }
}
