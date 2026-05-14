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

    // Anchor-level identity for an in-PDF annotation: which document,
    // which node, which page, which bounds. Bounds are decomposed to
    // CGFloat components so the struct can synthesize Hashable
    // (CGRect itself isn't Hashable in stdlib).
    private struct AnchorKey: Hashable {
        let documentURL: URL
        let nodeID: UUID
        let pageIndex: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat

        init(documentURL: URL, nodeID: UUID, pageIndex: Int, bounds: CGRect) {
            self.documentURL = documentURL
            self.nodeID = nodeID
            self.pageIndex = pageIndex
            self.x = bounds.origin.x
            self.y = bounds.origin.y
            self.width = bounds.size.width
            self.height = bounds.size.height
        }

        var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// Active persistent annotations keyed by anchor identity
    private var activeAnnotationMap: [AnchorKey: PDFAnnotation] = [:]

    // MARK: - Persistent Source Highlights

    /// Apply persistent color-coded highlights for all graph nodes in a
    /// document. Diffs against `activeAnnotationMap` and applies only the
    /// delta — important during extraction where nodeCount changes on each
    /// batch and the wipe-then-readd pattern was O(N²) PDFKit operations.
    @MainActor
    func applyPersistentHighlights(
        document: PDFDocument,
        graph: KnowledgeGraph,
        documentURL: URL
    ) -> [UUID: [PDFAnnotation]] {
        // Build desired set + per-key color
        var desiredKeys: Set<AnchorKey> = []
        var desiredColors: [AnchorKey: NSColor] = [:]

        let nodesInDoc = graph.allNodes.filter { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }

        for node in nodesInDoc {
            let colorIndex = node.highlightColorIndex ?? 0
            let color = SourceHighlightPalette.color(for: colorIndex).withAlphaComponent(0.25)
            for anchor in node.sourceAnchors where anchor.documentURL == documentURL {
                guard anchor.pageIndex < document.pageCount else { continue }
                let key = AnchorKey(documentURL: documentURL, nodeID: node.id, pageIndex: anchor.pageIndex, bounds: anchor.boundingBox)
                desiredKeys.insert(key)
                desiredColors[key] = color
            }
        }

        // Restrict the diff to keys for THIS document — annotations for
        // other documents (if the bridge is ever shared) stay put.
        let existingKeys = Set(activeAnnotationMap.keys.filter { $0.documentURL == documentURL })
        let toRemove = existingKeys.subtracting(desiredKeys)
        let toAdd = desiredKeys.subtracting(existingKeys)
        let kept = existingKeys.intersection(desiredKeys)

        // Apply removals
        for key in toRemove {
            if let annotation = activeAnnotationMap.removeValue(forKey: key) {
                annotation.page?.removeAnnotation(annotation)
            }
        }

        // Apply additions
        for key in toAdd {
            guard let page = document.page(at: key.pageIndex),
                  let color = desiredColors[key] else { continue }
            let annotation = PDFAnnotation(bounds: key.bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.setValue(key.nodeID.uuidString, forAnnotationKey: PDFAnnotationKey(rawValue: Self.atlasNodeIDKey))
            annotation.contents = "\(Self.atlasContentsPrefix)\(key.nodeID.uuidString)"
            page.addAnnotation(annotation)
            activeAnnotationMap[key] = annotation
        }

        // Update color on kept keys if it drifted (e.g., cross-doc merge
        // reassigned `highlightColorIndex` for an existing node)
        for key in kept {
            if let annotation = activeAnnotationMap[key],
               let color = desiredColors[key],
               annotation.color != color {
                annotation.color = color
            }
        }

        // Build the legacy [UUID: [PDFAnnotation]] return shape
        var result: [UUID: [PDFAnnotation]] = [:]
        for key in desiredKeys {
            if let annotation = activeAnnotationMap[key] {
                result[key.nodeID, default: []].append(annotation)
            }
        }
        return result
    }

    /// Remove all Atlas-managed highlights from a document
    @MainActor
    func removeAllAtlasHighlights(from document: PDFDocument) {
        let trackedForDoc = activeAnnotationMap.filter { $0.key.documentURL.path == document.documentURL?.path }
        if !trackedForDoc.isEmpty {
            // Fast path: remove only tracked annotations for this document
            for (key, annotation) in trackedForDoc {
                annotation.page?.removeAnnotation(annotation)
                activeAnnotationMap.removeValue(forKey: key)
            }
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

    /// Refresh highlights against the current graph state. With the
    /// diff-based `applyPersistentHighlights`, this is now a thin alias —
    /// no more wipe-then-readd churn.
    @MainActor
    func refreshHighlights(
        document: PDFDocument,
        graph: KnowledgeGraph,
        documentURL: URL
    ) {
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
