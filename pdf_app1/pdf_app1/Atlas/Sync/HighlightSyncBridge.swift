//
//  HighlightSyncBridge.swift
//  Atlas
//
//  Bridges PDF highlights/annotations with knowledge map nodes
//  Handles the source pulse animation when navigating from map to PDF
//

import Foundation
import PDFKit
import AppKit

// `nonisolated` to opt out of the project-wide MainActor default
// (SWIFT_DEFAULT_ACTOR_ISOLATION). Methods that genuinely need MainActor
// (e.g. applyPersistentHighlights) are annotated explicitly. See
// 2026-05-09 handoff for the macOS 26.3 isolated-deinit runtime bug.
nonisolated class HighlightSyncBridge {

    /// Key used to tag Atlas-managed annotations in PDF
    static let atlasNodeIDKey = "atlasNodeID"
    /// Prefix for annotation contents to identify Atlas-managed highlights
    static let atlasContentsPrefix = "atlas:"

    /// Active persistent annotations keyed by node ID
    private var activeAnnotations: [UUID: [PDFAnnotation]] = [:]

    // MARK: - Persistent Source Highlights

    /// Apply persistent color-coded highlights for all graph nodes in a document
    @MainActor
    func applyPersistentHighlights(
        document: PDFDocument,
        graph: KnowledgeGraph,
        documentURL: URL
    ) -> [UUID: [PDFAnnotation]] {
        var result: [UUID: [PDFAnnotation]] = [:]

        let nodesInDoc = graph.allNodes.filter { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }

        for node in nodesInDoc {
            let colorIndex = node.highlightColorIndex ?? 0
            let color = SourceHighlightPalette.color(for: colorIndex).withAlphaComponent(0.25)

            for anchor in node.sourceAnchors where anchor.documentURL == documentURL {
                guard anchor.pageIndex < document.pageCount,
                      let page = document.page(at: anchor.pageIndex) else { continue }

                let annotation = PDFAnnotation(bounds: anchor.boundingBox, forType: .highlight, withProperties: nil)
                annotation.color = color
                annotation.setValue(node.id.uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: Self.atlasNodeIDKey))
                // Also store in contents for easier retrieval
                annotation.contents = "\(Self.atlasContentsPrefix)\(node.id.uuidString)"

                page.addAnnotation(annotation)
                result[node.id, default: []].append(annotation)
            }
        }

        activeAnnotations = result
        return result
    }

    /// Remove all Atlas-managed highlights from a document
    @MainActor
    func removeAllAtlasHighlights(from document: PDFDocument) {
        if !activeAnnotations.isEmpty {
            // Fast path: remove only tracked annotations
            for annotations in activeAnnotations.values {
                for annotation in annotations {
                    annotation.page?.removeAnnotation(annotation)
                }
            }
            activeAnnotations.removeAll()
        } else {
            // Fallback: scan pages (e.g., first load with pre-existing annotations)
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let toRemove = page.annotations.filter { annotation in
                    annotation.contents?.hasPrefix(Self.atlasContentsPrefix) == true
                }
                for annotation in toRemove {
                    page.removeAnnotation(annotation)
                }
            }
        }
    }

    /// Refresh highlights: remove old ones and apply new ones
    @MainActor
    func refreshHighlights(
        document: PDFDocument,
        graph: KnowledgeGraph,
        documentURL: URL
    ) {
        removeAllAtlasHighlights(from: document)
        _ = applyPersistentHighlights(document: document, graph: graph, documentURL: documentURL)
    }

    // MARK: - Text-based passage finding

    func findPassageRects(snippet: String, on page: PDFPage) -> [CGRect]? {
        guard !snippet.isEmpty,
              let pageText = page.string,
              !pageText.isEmpty else { return nil }

        let nsRange: NSRange
        if let range = pageText.range(of: snippet, options: [.caseInsensitive, .diacriticInsensitive]) {
            nsRange = NSRange(range, in: pageText)
        } else if let regexRange = whitespaceFlexibleMatch(snippet: snippet, in: pageText) {
            // PDF text has hard line breaks at wraps; the snippet uses spaces.
            nsRange = regexRange
        } else {
            return nil
        }

        guard let selection = page.selection(for: nsRange) else { return nil }

        let lineSelections = selection.selectionsByLine()
        let rects = lineSelections.compactMap { lineSel -> CGRect? in
            let rect = lineSel.bounds(for: page)
            return rect.isEmpty ? nil : rect
        }

        return rects.isEmpty ? nil : rects
    }

    private func whitespaceFlexibleMatch(snippet: String, in pageText: String) -> NSRange? {
        let words = snippet.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let pattern = words
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = pageText as NSString
        let match = regex.firstMatch(in: pageText, range: NSRange(location: 0, length: nsText.length))
        return match?.range
    }

    // MARK: - Source Pulse (temporary emphasis)

    /// Pulse an existing persistent highlight or create a temporary one
    @MainActor
    func showSourcePulse(
        on pdfView: PDFView,
        page: PDFPage,
        boundingBox: CGRect,
        color: NSColor,
        duration: TimeInterval = AppConstants.sourcePulseDuration
    ) {
        // Check if there's already a persistent Atlas annotation at this location
        let existingAtlas = page.annotations.first { annotation in
            annotation.contents?.hasPrefix(Self.atlasContentsPrefix) == true &&
            annotation.bounds.intersects(boundingBox)
        }

        if let existing = existingAtlas {
            // Temporarily boost the existing annotation's visibility
            let originalColor = existing.color
            existing.color = color.withAlphaComponent(0.6)
            pdfView.setNeedsDisplay(pdfView.bounds)

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                existing.color = originalColor
                pdfView.setNeedsDisplay(pdfView.bounds)
            }
        } else {
            // Create a temporary highlight
            let annotation = PDFAnnotation(bounds: boundingBox, forType: .highlight, withProperties: nil)
            annotation.color = color.withAlphaComponent(0.4)
            page.addAnnotation(annotation)

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                page.removeAnnotation(annotation)
                pdfView.setNeedsDisplay(pdfView.bounds)
            }
        }

        // Navigate to the annotation
        let destination = PDFDestination(page: page, at: CGPoint(x: boundingBox.midX, y: boundingBox.midY))
        pdfView.go(to: destination)
    }

    /// Navigate the PDF view to a source anchor and pulse with the node's color
    @MainActor
    func navigateAndPulse(
        pdfView: PDFView,
        anchor: SourceAnchor,
        nodeColor: NSColor = .systemBlue
    ) {
        guard let document = pdfView.document,
              anchor.pageIndex < document.pageCount,
              let page = document.page(at: anchor.pageIndex) else { return }

        showSourcePulse(
            on: pdfView,
            page: page,
            boundingBox: anchor.boundingBox,
            color: nodeColor
        )
    }

    // MARK: - Node ID from Annotation

    /// Extract Atlas node ID from a clicked annotation, if it's an Atlas highlight
    static func nodeID(from annotation: PDFAnnotation) -> UUID? {
        guard let contents = annotation.contents,
              contents.hasPrefix(atlasContentsPrefix) else { return nil }
        let uuidString = String(contents.dropFirst(atlasContentsPrefix.count))
        return UUID(uuidString: uuidString)
    }

    // MARK: - User Highlight → Map Sync

    /// When a PDF highlight is created, find and mark the corresponding map node
    func syncHighlightToMap(
        annotation: PDFAnnotation,
        page: PDFPage,
        document: PDFDocument,
        documentURL: URL,
        syncManager: BidirectionalSyncManager
    ) {
        let pageIndex = document.index(for: page)
        let bounds = annotation.bounds
        let text = annotation.contents ?? ""

        syncManager.onHighlightCreated(
            pageIndex: pageIndex,
            boundingBox: bounds,
            text: text
        )
    }
}
