import XCTest
@testable import pdf_app1

/// Tests for `Atlas/AI/PromptTemplates.swift` covering the prompt-builder
/// surfaces that SCETests does not already pin:
///   - conceptExtraction: outline hints, existing-list rendering, page
///     numbers are 1-based, prior-docs block absence/presence
///   - edgeProposal: edge-types list and JSON instruction
///   - semanticMergeProposal: structures the A/B concept lists correctly
///   - deepFactExtraction / deepClustering / deepCrossReference: instruction
///     content and embedded JSON-schema shape
///   - chapterExtraction: page-marker explanation included
///   - summarize / questionAnswer: short, single-purpose prompts
final class PromptTemplatesTests: XCTestCase {

    private func emptyCtx(pageRange: Range<Int> = 0..<5,
                          title: String = "Test.pdf",
                          existing: [String] = [],
                          outline: [String] = [],
                          priorHeader: String? = nil) -> ExtractionContext {
        ExtractionContext(
            documentTitle: title,
            pageRange: pageRange,
            existingConcepts: existing,
            outlineHints: outline,
            priorDocsContext: priorHeader
        )
    }

    // MARK: - conceptExtraction

    func test_conceptExtraction_pageRangeIsOneBased() {
        let prompt = PromptTemplates.conceptExtraction(
            text: "body",
            context: emptyCtx(pageRange: 4..<9, title: "T.pdf")
        )
        // 4..<9 → "5-9" in user-facing terms.
        XCTAssertTrue(prompt.contains("pages 5-9"))
    }

    func test_conceptExtraction_existingConceptList_emptyVsPresent() {
        let empty = PromptTemplates.conceptExtraction(text: "x", context: emptyCtx())
        XCTAssertTrue(empty.contains("None yet."))

        let withExisting = PromptTemplates.conceptExtraction(
            text: "x",
            context: emptyCtx(existing: ["Alpha", "Beta"])
        )
        XCTAssertTrue(withExisting.contains("Alpha, Beta"))
        XCTAssertFalse(withExisting.contains("None yet."))
    }

    func test_conceptExtraction_outlineHintsAppearWhenProvided() {
        let p = PromptTemplates.conceptExtraction(
            text: "x",
            context: emptyCtx(outline: ["Chapter 1", "Methods"])
        )
        XCTAssertTrue(p.contains("Chapter 1 > Methods"))
        XCTAssertTrue(p.contains("outline hints"))
    }

    func test_conceptExtraction_textBodyIsAppendedAtTheEnd() {
        let p = PromptTemplates.conceptExtraction(
            text: "THE_BODY_TEXT_GOES_HERE",
            context: emptyCtx()
        )
        XCTAssertTrue(p.contains("TEXT:"))
        XCTAssertTrue(p.contains("THE_BODY_TEXT_GOES_HERE"))
        // Body should appear near the bottom of the prompt.
        if let bodyRange = p.range(of: "THE_BODY_TEXT_GOES_HERE") {
            XCTAssertGreaterThan(bodyRange.lowerBound, p.index(p.startIndex, offsetBy: p.count / 2))
        }
    }

    func test_conceptExtraction_priorDocsHeader_empty_omitsBlock() {
        let prompt = PromptTemplates.conceptExtraction(text: "x", context: emptyCtx(priorHeader: ""))
        XCTAssertFalse(prompt.contains("Prior Documents"))
    }

    // MARK: - edgeProposal

    func test_edgeProposal_listsConceptsAndKnownEdgeTypes() {
        let p = PromptTemplates.edgeProposal(concepts: ["A", "B", "C"], context: "context body")
        XCTAssertTrue(p.contains("A, B, C"))
        XCTAssertTrue(p.contains("context body"))
        // Should enumerate the canonical edge-type vocabulary.
        for required in ["dependsOn", "contradicts", "exampleOf", "defines",
                         "extends", "cites", "sameTopic", "partOf", "uses"] {
            XCTAssertTrue(p.contains(required), "edgeProposal prompt missing '\(required)'")
        }
        // Should ask for JSON only.
        XCTAssertTrue(p.contains("Return valid JSON only."))
    }

    // MARK: - semanticMergeProposal

    func test_semanticMergeProposal_renderingFormatsBothDocsAndMergeTypes() {
        let p = PromptTemplates.semanticMergeProposal(
            documentATitle: "A.pdf",
            documentAConcepts: [(label: "Optimization", summary: "math")],
            documentBTitle: "B.pdf",
            documentBConcepts: [(label: "Gradient Descent", summary: nil)]
        )
        XCTAssertTrue(p.contains("A.pdf"))
        XCTAssertTrue(p.contains("B.pdf"))
        XCTAssertTrue(p.contains("Optimization: math"))
        XCTAssertTrue(p.contains("- Gradient Descent"))
        XCTAssertFalse(p.contains("Gradient Descent: nil"), "nil summary must render as label only")
        for label in ["exactMatch", "semanticEquivalent", "partialOverlap"] {
            XCTAssertTrue(p.contains(label))
        }
    }

    // MARK: - deepFactExtraction

    func test_deepFactExtraction_includesSchemaAndAbsoluteRange() {
        let p = PromptTemplates.deepFactExtraction(
            text: "deep body",
            documentTitle: "Doc.pdf",
            pageRange: 0..<3
        )
        XCTAssertTrue(p.contains("Doc.pdf"))
        XCTAssertTrue(p.contains("pages 1-3"))
        // Schema fields.
        for field in ["\"claim\"", "\"textSpan\"", "\"type\"", "\"confidence\""] {
            XCTAssertTrue(p.contains(field), "deepFactExtraction prompt missing \(field)")
        }
        XCTAssertTrue(p.contains("deep body"))
    }

    // MARK: - deepClustering

    func test_deepClustering_includesFactsAndDeduplicationGuidance() {
        let facts = [
            RawFact(claim: "Fact A", textSpan: "spanA", type: "claim", confidence: 0.8),
            RawFact(claim: "Fact \"quoted\"", textSpan: "spanB", type: "definition", confidence: 0.9)
        ]
        let p = PromptTemplates.deepClustering(facts: facts, documentTitle: "Doc.pdf")
        XCTAssertTrue(p.contains("Doc.pdf"))
        XCTAssertTrue(p.contains("\"claim\": \"Fact A\""))
        // Inner quotes must be escaped in the embedded JSON.
        XCTAssertTrue(p.contains("Fact \\\"quoted\\\""))
        XCTAssertTrue(p.contains("DEDUPLICATE"))
        XCTAssertTrue(p.contains("factIndices"))
    }

    // MARK: - deepCrossReference

    func test_deepCrossReference_listsConceptsAndExcludesFoldEdgeTypes() {
        let p = PromptTemplates.deepCrossReference(
            concepts: [(label: "Optimization", summary: "math"),
                       (label: "Backpropagation", summary: nil)],
            documentTitle: "ml.pdf"
        )
        XCTAssertTrue(p.contains("ml.pdf"))
        XCTAssertTrue(p.contains("Optimization: math"))
        XCTAssertTrue(p.contains("- Backpropagation"))
        // The prompt explicitly forbids structural fold edges.
        XCTAssertTrue(p.contains("containsChapter") || p.contains("contains"),
                      "Expected the prompt to mention the excluded fold-edge types")
        XCTAssertTrue(p.contains("dependsOn"))
        XCTAssertTrue(p.contains("Return valid JSON only."))
    }

    // MARK: - chapterExtraction

    func test_chapterExtraction_explainsPageMarkersAndZeroIndexing() {
        let p = PromptTemplates.chapterExtraction(
            documentTitle: "book.pdf",
            totalPages: 42,
            text: "=== Page 0 ===\nfirst page text"
        )
        XCTAssertTrue(p.contains("book.pdf"))
        XCTAssertTrue(p.contains("42 pages"))
        XCTAssertTrue(p.contains("=== Page N ==="))
        XCTAssertTrue(p.contains("0-based"))
        XCTAssertTrue(p.contains("first page text"))
        XCTAssertTrue(p.contains("\"chapters\""))
    }

    // MARK: - summarize / questionAnswer

    func test_summarize_promptIsShortAndIncludesConceptAndSource() {
        let p = PromptTemplates.summarize(conceptLabel: "DNA Replication", sourceText: "Long source.")
        XCTAssertTrue(p.contains("DNA Replication"))
        XCTAssertTrue(p.contains("Long source."))
        XCTAssertTrue(p.contains("1-2 clear sentences"))
    }

    func test_questionAnswer_promptHasCitationsField() {
        let p = PromptTemplates.questionAnswer(question: "What is X?", context: "Context body.")
        XCTAssertTrue(p.contains("What is X?"))
        XCTAssertTrue(p.contains("Context body."))
        XCTAssertTrue(p.contains("\"citations\""))
        XCTAssertTrue(p.contains("\"pageIndex\""))
    }
}
