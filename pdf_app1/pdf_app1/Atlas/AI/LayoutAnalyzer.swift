//
//  LayoutAnalyzer.swift
//  Atlas
//
//  Heuristic classifier for text blocks: heading, body, caption, footnote, etc.
//  Uses position, size, and font metrics — no AI needed.
//

import Foundation
import PDFKit

class LayoutAnalyzer {

    struct LayoutConfig {
        /// Minimum font height ratio (relative to median) to classify as heading
        var headingHeightRatio: CGFloat = 1.4
        /// Maximum Y position ratio (from bottom) for footnotes
        var footnoteYRatio: CGFloat = 0.15
        /// Maximum height ratio for captions
        var captionHeightRatio: CGFloat = 0.7
        /// Minimum character count for body text
        var bodyMinChars: Int = 40
    }

    let config: LayoutConfig

    init(config: LayoutConfig = LayoutConfig()) {
        self.config = config
    }

    /// Classify all blocks on a page using heuristics
    func classify(blocks: [PageTextBlock], pageSize: CGSize) -> [PageTextBlock] {
        guard !blocks.isEmpty else { return blocks }

        // Compute median line height for reference
        let heights = blocks.map { $0.boundingBox.height }.sorted()
        let medianHeight = heights[heights.count / 2]

        return blocks.map { block in
            let classifiedType = classifyBlock(block, medianHeight: medianHeight, pageSize: pageSize)
            return PageTextBlock(
                text: block.text,
                pageIndex: block.pageIndex,
                boundingBox: block.boundingBox,
                blockType: classifiedType
            )
        }
    }

    private func classifyBlock(_ block: PageTextBlock, medianHeight: CGFloat, pageSize: CGSize) -> TextBlockType {
        let bbox = block.boundingBox
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Equation heuristic: heavy math symbols or LaTeX-like patterns
        if looksLikeEquation(text) {
            return .equation
        }

        // Heading heuristic: taller than median, short text, near top or after spacing
        if medianHeight > 0 && bbox.height > medianHeight * config.headingHeightRatio
            && text.count < 120 {
            return .heading
        }

        // Short all-caps lines are likely headings too
        if text.count < 80 && text == text.uppercased() && text.count > 3
            && text.rangeOfCharacter(from: .lowercaseLetters) == nil {
            return .heading
        }

        // Footnote heuristic: near the bottom of the page
        if pageSize.height > 0 && bbox.origin.y < pageSize.height * config.footnoteYRatio
            && text.count < 200 {
            return .footnote
        }

        // Caption heuristic: short text, small font
        if medianHeight > 0 && bbox.height < medianHeight * config.captionHeightRatio
            && text.count < 150 {
            return .caption
        }

        // Figure reference heuristic
        if text.lowercased().hasPrefix("figure ") || text.lowercased().hasPrefix("fig. ") {
            return .caption
        }

        return .body
    }

    private func looksLikeEquation(_ text: String) -> Bool {
        let mathSymbols: Set<Character> = ["∑", "∫", "∂", "∇", "≈", "≠", "≤", "≥", "∈", "∉", "⊂", "⊃", "∪", "∩", "→", "←", "⇒", "⇔", "∀", "∃", "∞", "α", "β", "γ", "δ", "ε", "θ", "λ", "μ", "π", "σ", "φ", "ω"]

        let mathCharCount = text.filter { mathSymbols.contains($0) }.count
        if mathCharCount > 2 { return true }

        // Simple heuristic: lots of operators and single-letter variables
        let operatorCount = text.filter { "=+-*/^_{}()[]".contains($0) }.count
        if text.count > 5 && Double(operatorCount) / Double(text.count) > 0.3 {
            return true
        }

        return false
    }

    /// Extract the document's structural outline (TOC) from PDF outline
    func extractOutline(from document: PDFDocument) -> [(title: String, pageIndex: Int)] {
        var entries: [(title: String, pageIndex: Int)] = []
        guard let root = document.outlineRoot else { return entries }
        collectOutlineEntries(root, into: &entries, document: document)
        return entries
    }

    private func collectOutlineEntries(
        _ outline: PDFOutline,
        into entries: inout [(title: String, pageIndex: Int)],
        document: PDFDocument
    ) {
        if let label = outline.label, let destination = outline.destination,
           let page = destination.page {
            let pageIndex = document.index(for: page)
            entries.append((title: label, pageIndex: pageIndex))
        }
        for i in 0..<outline.numberOfChildren {
            if let child = outline.child(at: i) {
                collectOutlineEntries(child, into: &entries, document: document)
            }
        }
    }
}
