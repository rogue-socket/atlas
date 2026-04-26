//
//  TextExtractor.swift
//  Atlas
//
//  Extracts structured text from PDF pages with bounding box information
//

import Foundation
import PDFKit

// MARK: - Page Text Block

struct PageTextBlock: Identifiable {
    let id = UUID()
    let text: String
    let pageIndex: Int
    let boundingBox: CGRect
    let blockType: TextBlockType
}

enum TextBlockType {
    case heading
    case body
    case caption
    case footnote
    case equation
    case figure
    case unknown
}

// MARK: - Page Extraction Result

struct PageExtractionResult {
    let pageIndex: Int
    let fullText: String
    let blocks: [PageTextBlock]
}

// MARK: - Text Extractor

class TextExtractor {

    /// Extract text with bounding boxes from a range of pages
    func extractPages(from document: PDFDocument, pageRange: Range<Int>) -> [PageExtractionResult] {
        let clampedRange = max(0, pageRange.lowerBound) ..< min(document.pageCount, pageRange.upperBound)
        var results: [PageExtractionResult] = []

        for pageIndex in clampedRange {
            guard let page = document.page(at: pageIndex) else { continue }
            let result = extractPage(page, at: pageIndex)
            results.append(result)
        }
        return results
    }

    /// Extract text from a single page
    func extractPage(_ page: PDFPage, at pageIndex: Int) -> PageExtractionResult {
        let fullText = page.string ?? ""
        let blocks = extractBlocks(from: page, pageIndex: pageIndex)
        return PageExtractionResult(pageIndex: pageIndex, fullText: fullText, blocks: blocks)
    }

    /// Extract text blocks by splitting on line breaks and getting bounding boxes
    private func extractBlocks(from page: PDFPage, pageIndex: Int) -> [PageTextBlock] {
        guard let pageText = page.string, !pageText.isEmpty else { return [] }

        var blocks: [PageTextBlock] = []
        let lines = pageText.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        for line in lines {
            guard let selection = page.selection(for: NSRange(location: 0, length: (pageText as NSString).length)) else { continue }

            // Find this line's selection within the page
            if let lineSelection = findSelection(for: line, in: page) {
                let bounds = lineSelection.bounds(for: page)
                guard bounds.width > 0 && bounds.height > 0 else { continue }

                let block = PageTextBlock(
                    text: line.trimmingCharacters(in: .whitespaces),
                    pageIndex: pageIndex,
                    boundingBox: bounds,
                    blockType: .unknown // LayoutAnalyzer classifies later
                )
                blocks.append(block)
                _ = selection // suppress warning
            }
        }

        // If line-by-line extraction yielded nothing, fall back to whole-page block
        if blocks.isEmpty && !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let pageBounds = page.bounds(for: .mediaBox)
            blocks.append(PageTextBlock(
                text: pageText.trimmingCharacters(in: .whitespacesAndNewlines),
                pageIndex: pageIndex,
                boundingBox: pageBounds,
                blockType: .body
            ))
        }

        return blocks
    }

    /// Find a PDFSelection for a specific text string within a page
    private func findSelection(for text: String, in page: PDFPage) -> PDFSelection? {
        guard let pageText = page.string as NSString? else { return nil }
        let range = pageText.range(of: text)
        guard range.location != NSNotFound else { return nil }
        return page.selection(for: range)
    }

    /// Extract text with context (surrounding pages) for AI processing
    func extractWithContext(
        from document: PDFDocument,
        centerPage: Int,
        contextPages: Int = 2
    ) -> (centerText: String, contextText: String, blocks: [PageTextBlock]) {
        let start = max(0, centerPage - contextPages)
        let end = min(document.pageCount, centerPage + contextPages + 1)

        var contextParts: [String] = []
        var allBlocks: [PageTextBlock] = []

        for i in start..<end {
            guard let page = document.page(at: i) else { continue }
            let result = extractPage(page, at: i)
            contextParts.append("--- Page \(i + 1) ---\n\(result.fullText)")
            allBlocks.append(contentsOf: result.blocks)
        }

        let centerText = document.page(at: centerPage)?.string ?? ""
        let contextText = contextParts.joined(separator: "\n\n")

        return (centerText, contextText, allBlocks)
    }
}
