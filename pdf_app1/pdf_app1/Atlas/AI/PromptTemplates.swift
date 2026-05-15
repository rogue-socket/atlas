//
//  PromptTemplates.swift
//  Atlas
//
//  All LLM prompts for concept extraction, edge proposal, summarization, and Q&A
//

import Foundation

enum PromptTemplates {

    // MARK: - Hierarchical Concept Extraction

    static func conceptExtraction(text: String, context: ExtractionContext) -> String {
        let existingList = context.existingConcepts.isEmpty
            ? "None yet."
            : context.existingConcepts.joined(separator: ", ")

        let outlineHints = context.outlineHints.isEmpty
            ? ""
            : "\nDocument outline hints: \(context.outlineHints.joined(separator: " > "))"

        return """
        You are a concept map extraction system following Novak's methodology. Analyze the following text from "\(context.documentTitle)" (pages \(context.pageRange.lowerBound + 1)-\(context.pageRange.upperBound)) and extract a hierarchical concept map.
        \(outlineHints)

        Already extracted concepts (do not duplicate): \(existingList)

        ## Core Principle

        A concept map is a network of PROPOSITIONS. Each proposition is a triple: Concept A —[linking phrase]→ Concept B that reads as a meaningful sentence. For example: "Glycolysis" —[produces]→ "Pyruvate" reads as "Glycolysis produces Pyruvate."

        ## Extraction Rules

        1. Identify 5-6 TOP THEMES (hierarchyLevel 0) — these are the broadest ideas or processes in the text. Label them as short readable noun phrases (2-6 words).

        2. For each theme, identify 3-8 SUB-CONCEPTS (hierarchyLevel 1+) — these are more specific ideas that fall under a theme. Each sub-concept must specify its parent theme via subtopicOf.

        3. Every concept (theme or sub-concept) MUST have a textSpan that is an EXACT verbatim quote from the text. If you cannot find an exact quote, do not include that concept.

        4. Propose edges between concepts. Each edge MUST have a linkingPhrase — a short verb phrase (1-4 words MAX) that makes "sourceLabel [linkingPhrase] targetLabel" read as a grammatical sentence. Good: "produces", "requires", "inhibits", "is a type of". Bad: "is far less efficient than aerobic respiration in producing" (too long — rephrase as "yields less than").

        5. Do not invent concepts not present in the text. Prefer specific, concrete concepts over vague abstractions.

        6. Concept labels should be readable noun phrases, NOT full sentences. Good: "ATP production", "Krebs cycle enzymes". Bad: "ATP is produced by oxidative phosphorylation".

        ## JSON Schema

        EVERY field below is REQUIRED. Do not omit any field. Return ONLY a JSON object with this exact structure:
        {
          "concepts": [
            {
              "label": "Readable Noun Phrase (2-6 words)",
              "type": "concept",
              "summary": "One sentence explaining this concept",
              "textSpan": "exact verbatim quote from text",
              "confidence": 0.95,
              "hierarchyLevel": 0,
              "subtopicOf": null
            },
            {
              "label": "More Specific Sub-concept",
              "type": "concept",
              "summary": "One sentence explanation",
              "textSpan": "exact verbatim quote from text",
              "confidence": 0.9,
              "hierarchyLevel": 1,
              "subtopicOf": "Parent Theme Label"
            }
          ],
          "edges": [
            {
              "sourceLabel": "Concept A",
              "targetLabel": "Concept B",
              "type": "dependsOn",
              "confidence": 0.85,
              "linkingPhrase": "requires"
            }
          ]
        }

        REQUIRED concept fields: label, type, summary, textSpan, confidence, hierarchyLevel, subtopicOf
        REQUIRED edge fields: sourceLabel, targetLabel, type, confidence, linkingPhrase
        hierarchyLevel: 0 = top theme, 1 = direct sub-concept, 2 = sub-sub-concept (rarely needed)
        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses
        linkingPhrase: 1-4 word verb phrase making "A [phrase] B" a readable sentence

        Return valid JSON only, no markdown formatting.

        TEXT:
        \(text)
        """
    }

    // MARK: - Edge Proposal

    static func edgeProposal(concepts: [String], context: String) -> String {
        return """
        Given these concepts: \(concepts.joined(separator: ", "))

        And this context text:
        \(context)

        Propose relationships (edges) between the concepts. Do NOT propose edges between a concept and its own child entities — those containment relationships are already captured.

        Only propose edges between:
        - Two concepts (cross-topic relationships)
        - Two entities that belong to different concepts
        - An entity and a concept it relates to (other than its parent)

        Return ONLY a JSON array:
        [
          {
            "sourceLabel": "...",
            "targetLabel": "...",
            "type": "...",
            "confidence": 0.9
          }
        ]

        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses

        Only propose edges you are confident about. Return valid JSON only.
        """
    }

    // MARK: - Semantic Merge Proposal

    static func semanticMergeProposal(
        documentATitle: String,
        documentAConcepts: [(label: String, summary: String?)],
        documentBTitle: String,
        documentBConcepts: [(label: String, summary: String?)]
    ) -> String {
        let formatConcepts: ([(label: String, summary: String?)]) -> String = { concepts in
            concepts.map { c in
                if let s = c.summary { return "- \(c.label): \(s)" }
                return "- \(c.label)"
            }.joined(separator: "\n")
        }

        return """
        You are analyzing two documents to find overlapping concepts between them.

        Document A: "\(documentATitle)"
        Concepts:
        \(formatConcepts(documentAConcepts))

        Document B: "\(documentBTitle)"
        Concepts:
        \(formatConcepts(documentBConcepts))

        Identify which concepts from Document A and Document B refer to the same or closely related topic, even if they use different terminology, abbreviations, or phrasings. Consider:
        - Synonyms and alternative names (e.g., "Neural Networks" ↔ "Deep Learning Architectures")
        - Abbreviations (e.g., "NN" ↔ "Neural Network")
        - Specificity differences (e.g., "Optimization" ↔ "Gradient Descent" — partial overlap)
        - Domain-equivalent terms (e.g., "Loss Function" ↔ "Cost Function")

        Return ONLY a JSON array of matches:
        [
          {
            "labelA": "concept label from Document A",
            "labelB": "concept label from Document B",
            "confidence": 0.85,
            "reason": "Brief explanation of why these are the same/related",
            "mergeType": "exactMatch|semanticEquivalent|partialOverlap"
          }
        ]

        - exactMatch: clearly the same concept, just different wording
        - semanticEquivalent: same underlying idea, different framing
        - partialOverlap: one is a subset or special case of the other

        Only propose matches you are confident about (confidence > 0.6). Return valid JSON only.
        """
    }

    // MARK: - Deep Mode Pass 1: Fact Extraction

    static func deepFactExtraction(text: String, documentTitle: String, pageRange: Range<Int>) -> String {
        return """
        You are a knowledge extraction system performing detailed fact extraction from "\(documentTitle)" (pages \(pageRange.lowerBound + 1)-\(pageRange.upperBound)).

        Extract every distinct fact, claim, definition, observation, or result stated in the text. Each fact should be atomic — one idea per fact.

        For each fact, provide an EXACT verbatim quote (textSpan) from the source text.

        Return ONLY a JSON object:
        {
          "facts": [
            {
              "claim": "One-sentence statement of the fact",
              "textSpan": "exact verbatim quote from text supporting this fact",
              "type": "claim|definition|observation|example|result|method",
              "confidence": 0.95
            }
          ]
        }

        Return valid JSON only, no markdown formatting.

        TEXT:
        \(text)
        """
    }

    // MARK: - Deep Mode Pass 2: Clustering & Deduplication

    static func deepClustering(facts: [RawFact], documentTitle: String) -> String {
        let factsJSON = facts.enumerated().map { i, f in
            "  {\n    \"index\": \(i),\n    \"claim\": \"\(f.claim.replacingOccurrences(of: "\"", with: "\\\""))\",\n    \"type\": \"\(f.type)\"\n  }"
        }.joined(separator: ",\n")

        return """
        You are organizing extracted facts from "\(documentTitle)" into a hierarchical concept map.

        Here are \(facts.count) facts extracted from the document (each has an index):
        [\(factsJSON)]

        ## Instructions

        1. Group related facts into 3-12 high-level CONCEPTS (themes/topics). Each concept should represent a coherent theme.

        2. For each concept, identify 1-5 ENTITIES (specific definitions, examples, techniques, people, results) that belong under it.

        3. DEDUPLICATE: If multiple facts express the same idea (even with different wording), group them under the same concept. Use factIndices to reference which input facts belong to each concept/entity.

        4. Every concept and entity must reference at least one fact via factIndices.

        Return ONLY a JSON object:
        {
          "concepts": [
            {
              "label": "Short Name (2-5 words)",
              "type": "concept|theorem|method|claim",
              "summary": "One sentence description synthesizing the grouped facts",
              "level": "concept",
              "factIndices": [0, 3, 7],
              "entities": [
                {
                  "label": "Specific Entity Name",
                  "type": "definition|example|person|dataset|result|equation",
                  "summary": "One sentence description",
                  "parentLabel": "Short Name",
                  "factIndices": [3]
                }
              ]
            }
          ]
        }

        Return valid JSON only, no markdown formatting.
        """
    }

    // MARK: - Deep Mode Pass 3: Cross-Referencing

    static func deepCrossReference(concepts: [(label: String, summary: String?)], documentTitle: String) -> String {
        let conceptList = concepts.map { c in
            if let s = c.summary { return "- \(c.label): \(s)" }
            return "- \(c.label)"
        }.joined(separator: "\n")

        return """
        You are building a knowledge map for "\(documentTitle)". Given these concepts, propose relationships between them.

        Concepts:
        \(conceptList)

        ## Instructions

        Propose edges between concepts. Consider:
        - Hierarchical relationships (subtopicOf): one concept is a subtopic of another
        - Dependency relationships (dependsOn): one concept requires understanding another
        - Similarity (sameTopic): concepts that overlap significantly
        - Other relationships: contradicts, extends, uses, defines, exampleOf, partOf

        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses, subtopicOf

        Return ONLY a JSON array:
        [
          {
            "sourceLabel": "...",
            "targetLabel": "...",
            "type": "subtopicOf|dependsOn|...",
            "confidence": 0.9
          }
        ]

        Only propose edges you are confident about. Return valid JSON only.
        """
    }

    // MARK: - Summarization

    static func summarize(conceptLabel: String, sourceText: String) -> String {
        return """
        Summarize the concept "\(conceptLabel)" based on this source text in 1-2 clear sentences suitable for a knowledge map node. Be concise and precise.

        Source text:
        \(sourceText)
        """
    }

    // MARK: - Question Answering

    // MARK: - Chapter Extraction

    /// Asks the LLM to identify chapter / section boundaries in a document.
    /// Fed the full text with `=== Page N ===` separators so the LLM can
    /// reference page indices in its output.
    ///
    /// Falls back to PDF outline (`LayoutAnalyzer.extractOutline`) when one
    /// exists — author-embedded TOC is treated as authoritative and skips
    /// this prompt entirely. Used only when no outline is available, or as
    /// a supplement.
    static func chapterExtraction(
        documentTitle: String,
        totalPages: Int,
        text: String
    ) -> String {
        return """
        You are identifying chapter / section structure in the document "\(documentTitle)" (\(totalPages) pages).

        The text below is the full document, with `=== Page N ===` markers between pages. Page indices are 0-based — page 0 is the first page.

        ## Task

        Identify the chapter or section structure. A chapter is a coherent unit of the document — typically a labeled section in a textbook, a major heading in an article, or a logical grouping of pages in an unstructured PDF. Each chapter has a title, a contiguous page range, and a short description.

        Guidelines:
        - Prefer real chapter titles when the document has them ("Chapter 3: DNA Replication", "Methods", "Results").
        - For documents without explicit structure (essays, novels, slide decks), group pages into 3-10 coherent sections by topic shift.
        - Chapter page ranges MUST be contiguous and MUST NOT overlap. Together they should cover the full document.
        - Aim for chapters of 2-30 pages each. Avoid 1-page chapters unless the document is genuinely structured that way (cover page, abstract, etc.).
        - Title: 2-8 readable words, no chapter numbering ("DNA Replication" not "Chapter 3: DNA Replication").
        - Summary: one sentence (under 20 words) describing what the chapter covers.

        ## Output

        Return ONLY a JSON object with this exact structure:
        {
          "chapters": [
            {
              "title": "Short Title",
              "pageStart": 0,
              "pageEnd": 4,
              "summary": "One sentence about this chapter."
            }
          ]
        }

        Return valid JSON only, no markdown formatting.

        DOCUMENT:
        \(text)
        """
    }

    static func questionAnswer(question: String, context: String) -> String {
        return """
        Answer the following question based on the provided document context. Cite specific passages.

        Return a JSON object:
        {
          "answer": "Your answer here",
          "citations": [
            {"text": "exact quote from context", "pageIndex": 5}
          ]
        }

        Question: \(question)

        Context:
        \(context)

        Return valid JSON only.
        """
    }
}
