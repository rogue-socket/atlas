//
//  ChapterExtraction.swift
//  Atlas
//
//  Produces `.chapter`-level nodes for a document.
//
//  Priority of sources (decided in atlas/prds/2026-05-15_4-level-knowledge-graph.md):
//    1. PDF outline (`LayoutAnalyzer.extractOutline`) — author-embedded TOC.
//       When present, used directly. The PDF outline is treated as
//       authoritative; the LLM is not consulted.
//    2. LLM chapter pass — when the PDF has no outline, send the full
//       document text (with page markers) to the LLM and ask for chapter
//       boundaries. Returns a list of `RawChapter` with page ranges.
//
//  Output: `.chapter`-level `ConceptNode`s with `sourceAnchors` covering
//  the chapter's page range. The Document → Chapter linkage (containsChapter
//  edges) is created downstream in `appendDocumentSummary`.
//

import Foundation
import PDFKit
import os.log

private let log = AtlasLogger.pipeline

enum ChapterExtraction {

    // MARK: - Orchestration

    /// Identify chapters for `document` and insert `.chapter` nodes into
    /// `graph`. Returns the inserted node IDs in document order.
    @discardableResult
    static func extract(
        document: PDFDocument,
        documentURL: URL,
        graph: KnowledgeGraph,
        backend: any AtlasModel,
        textExtractor: TextExtractor,
        layoutAnalyzer: LayoutAnalyzer
    ) async -> [UUID] {
        // Skip if chapters already exist for this URL (re-extraction safety).
        let existing = graph.allNodes.filter { node in
            node.level == .chapter &&
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        if !existing.isEmpty {
            log.info("[Chapter] \(existing.count) chapter(s) already present for \(documentURL.lastPathComponent), skipping extraction")
            return existing.map(\.id)
        }

        let chapters = await identifyChapters(
            document: document,
            documentURL: documentURL,
            backend: backend,
            textExtractor: textExtractor,
            layoutAnalyzer: layoutAnalyzer
        )
        guard !chapters.isEmpty else {
            log.info("[Chapter] no chapters identified for \(documentURL.lastPathComponent)")
            return []
        }

        var nodeIDs: [UUID] = []
        for raw in chapters {
            let node = makeChapterNode(raw: raw, documentURL: documentURL, document: document)
            graph.addNode(node)
            nodeIDs.append(node.id)
        }
        log.info("[Chapter] inserted \(nodeIDs.count) chapter node(s) for \(documentURL.lastPathComponent)")
        return nodeIDs
    }

    // MARK: - Source selection

    private static func identifyChapters(
        document: PDFDocument,
        documentURL: URL,
        backend: any AtlasModel,
        textExtractor: TextExtractor,
        layoutAnalyzer: LayoutAnalyzer
    ) async -> [RawChapter] {
        let totalPages = document.pageCount
        guard totalPages > 0 else { return [] }

        // Source 1: PDF outline (decision: outline wins when present).
        let outline = layoutAnalyzer.extractOutline(from: document)
        if !outline.isEmpty {
            let chapters = chaptersFromOutline(outline, totalPages: totalPages)
            log.info("[Chapter] using PDF outline (\(chapters.count) chapter(s)) for \(documentURL.lastPathComponent)")
            return chapters
        }

        // Source 2: LLM pass.
        let text = textWithPageMarkers(document: document)
        let prompt = PromptTemplates.chapterExtraction(
            documentTitle: documentURL.lastPathComponent,
            totalPages: totalPages,
            text: text
        )
        do {
            log.info("[Chapter] no outline; calling LLM for \(documentURL.lastPathComponent)")
            let raw = try await backend.generateRawResponse(prompt: prompt)
            let cleaned = JSONRepair.cleanAndRepair(raw)
            guard let data = cleaned.data(using: .utf8) else {
                log.error("[Chapter] LLM response not utf8-encodable for \(documentURL.lastPathComponent)")
                return fallbackPageRangeChapters(totalPages: totalPages)
            }
            let parsed = try JSONDecoder().decode(ChapterExtractionResponse.self, from: data)
            let sanitized = sanitize(chapters: parsed.chapters, totalPages: totalPages)
            log.info("[Chapter] LLM returned \(parsed.chapters.count) chapters; \(sanitized.count) after sanitization")
            return sanitized
        } catch {
            log.error("[Chapter] LLM chapter pass failed for \(documentURL.lastPathComponent): \(error.localizedDescription) — falling back to page-range chunking")
            return fallbackPageRangeChapters(totalPages: totalPages)
        }
    }

    // MARK: - Source 1: PDF outline

    private static func chaptersFromOutline(
        _ entries: [(title: String, pageIndex: Int)],
        totalPages: Int
    ) -> [RawChapter] {
        // Sort by pageIndex defensively (some PDF outlines come out of order).
        let sorted = entries
            .filter { $0.pageIndex >= 0 && $0.pageIndex < totalPages }
            .sorted { $0.pageIndex < $1.pageIndex }
        guard !sorted.isEmpty else { return [] }

        // Each chapter spans from its start page to (next chapter start - 1)
        // or to (totalPages - 1) for the final chapter.
        var chapters: [RawChapter] = []
        for (idx, entry) in sorted.enumerated() {
            let nextStart = (idx + 1 < sorted.count) ? sorted[idx + 1].pageIndex : totalPages
            let end = max(entry.pageIndex, nextStart - 1)
            chapters.append(RawChapter(
                title: entry.title,
                pageStart: entry.pageIndex,
                pageEnd: end,
                summary: nil  // outline doesn't carry descriptions
            ))
        }
        return chapters
    }

    // MARK: - Source 2 fallback: simple page-range chunking

    /// Last-resort fallback when the LLM call fails entirely. Splits the
    /// document into ~5-10 pseudo-chapters by page range so the Chapter tab
    /// isn't empty.
    private static func fallbackPageRangeChapters(totalPages: Int) -> [RawChapter] {
        guard totalPages > 0 else { return [] }
        let targetChapters = min(10, max(3, totalPages / 10))
        let pagesPerChapter = max(1, totalPages / targetChapters)
        var chapters: [RawChapter] = []
        var start = 0
        var n = 1
        while start < totalPages {
            let end = min(start + pagesPerChapter - 1, totalPages - 1)
            chapters.append(RawChapter(
                title: "Section \(n)",
                pageStart: start,
                pageEnd: end,
                summary: nil
            ))
            start = end + 1
            n += 1
        }
        return chapters
    }

    // MARK: - LLM input

    private static func textWithPageMarkers(document: PDFDocument) -> String {
        var parts: [String] = []
        for idx in 0..<document.pageCount {
            let pageText = document.page(at: idx)?.string ?? ""
            parts.append("=== Page \(idx) ===\n\(pageText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - LLM output sanitization

    /// LLM-returned chapters can have overlapping ranges, out-of-order
    /// entries, or pages outside the document. Sort, clamp, and de-overlap.
    private static func sanitize(chapters raw: [RawChapter], totalPages: Int) -> [RawChapter] {
        var clamped = raw.compactMap { ch -> RawChapter? in
            let start = max(0, min(ch.pageStart, totalPages - 1))
            let end = max(start, min(ch.pageEnd, totalPages - 1))
            guard !ch.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return RawChapter(title: ch.title, pageStart: start, pageEnd: end, summary: ch.summary)
        }
        clamped.sort { $0.pageStart < $1.pageStart }

        // Drop overlap: if chapter N+1 starts at or before chapter N ends, push N+1's start past N's end.
        var deduped: [RawChapter] = []
        for ch in clamped {
            if let last = deduped.last, ch.pageStart <= last.pageEnd {
                let newStart = last.pageEnd + 1
                if newStart > ch.pageEnd { continue } // chapter fully absorbed by predecessor
                deduped.append(RawChapter(
                    title: ch.title,
                    pageStart: newStart,
                    pageEnd: ch.pageEnd,
                    summary: ch.summary
                ))
            } else {
                deduped.append(ch)
            }
        }
        return deduped
    }

    // MARK: - Node construction

    private static func makeChapterNode(
        raw: RawChapter,
        documentURL: URL,
        document: PDFDocument
    ) -> ConceptNode {
        // Anchor on the first page of the chapter; bounding box and snippet
        // intentionally empty — chapters are page-range structural nodes,
        // not text-span citations.
        let anchor = SourceAnchor(
            documentURL: documentURL,
            pageIndex: raw.pageStart,
            boundingBox: .zero,
            textSnippet: ""
        )
        return ConceptNode(
            label: raw.title,
            type: .concept,
            summary: raw.summary,
            sourceAnchors: [anchor],
            confidence: 1.0,
            level: .chapter
        )
    }

    // MARK: - Concept-to-Chapter Attachment

    /// After concept extraction, scan each concept's source-anchor page
    /// indices and create `containsConcept` edges from every overlapping
    /// chapter. Multi-parent semantics: a concept appearing on pages 5-7
    /// when chapter A covers 3-6 and chapter B covers 7-10 gets edges
    /// from BOTH chapters.
    static func attachConceptsToChapters(graph: KnowledgeGraph, documentURL: URL) {
        let chapters = graph.allNodes.filter { node in
            node.level == .chapter &&
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        guard !chapters.isEmpty else { return }

        // Index chapters by page range for fast lookup.
        struct ChapterRange { let id: UUID; let pageStart: Int; let pageEnd: Int }
        let chapterRanges = chapters.compactMap { chapter -> ChapterRange? in
            guard let anchor = chapter.sourceAnchors.first(where: { $0.documentURL == documentURL })
            else { return nil }
            return ChapterRange(id: chapter.id, pageStart: anchor.pageIndex, pageEnd: anchor.pageIndex)
        }
        // Note: chapter ranges as stored currently capture only the start
        // page in the anchor. The `pageEnd` value from RawChapter was
        // dropped when we built the node — fix below uses adjacency to
        // neighboring chapters to reconstruct ranges.

        // Reconstruct end-pages by sorting starts and using next-start - 1.
        let sortedStarts = chapterRanges.sorted { $0.pageStart < $1.pageStart }
        var ranges: [(id: UUID, start: Int, end: Int)] = []
        for (i, ch) in sortedStarts.enumerated() {
            let end: Int
            if i + 1 < sortedStarts.count {
                end = max(ch.pageStart, sortedStarts[i + 1].pageStart - 1)
            } else {
                end = Int.max  // last chapter extends to end of doc
            }
            ranges.append((id: ch.id, start: ch.pageStart, end: end))
        }

        let concepts = graph.allNodes.filter { node in
            node.level == .concept &&
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }

        var added = 0
        for concept in concepts {
            let pages = Set(concept.sourceAnchors
                .filter { $0.documentURL == documentURL }
                .map { $0.pageIndex })

            for range in ranges {
                let overlaps = pages.contains { page in
                    page >= range.start && page <= range.end
                }
                guard overlaps else { continue }
                let alreadyLinked = graph.allEdges.contains { e in
                    e.type == .containsConcept &&
                    e.sourceNodeID == range.id &&
                    e.targetNodeID == concept.id
                }
                if !alreadyLinked {
                    let edge = GraphEdge(
                        sourceNodeID: range.id,
                        targetNodeID: concept.id,
                        type: .containsConcept,
                        confidence: 1.0
                    )
                    graph.addEdge(edge)
                    added += 1
                }
            }
        }
        log.info("[Chapter] attached \(concepts.count) concept(s) to chapters via \(added) containsConcept edge(s)")
    }
}
