//
//  PromptTemplates.swift
//  Atlas
//
//  All LLM prompts for concept extraction, edge proposal, summarization, and Q&A
//

import Foundation

enum PromptTemplates {

    // MARK: - Concept Extraction

    static func conceptExtraction(text: String, context: ExtractionContext) -> String {
        let existingList = context.existingConcepts.isEmpty
            ? "None yet."
            : context.existingConcepts.joined(separator: ", ")

        let outlineHints = context.outlineHints.isEmpty
            ? ""
            : "\nDocument outline hints: \(context.outlineHints.joined(separator: " > "))"

        return """
        You are a knowledge extraction system. Extract concepts from the following text of "\(context.documentTitle)" (pages \(context.pageRange.lowerBound + 1)-\(context.pageRange.upperBound)).
        \(outlineHints)

        Already extracted concepts (do not duplicate): \(existingList)

        For each concept, provide:
        - label: Short human-readable name (2-5 words)
        - type: One of: concept, definition, theorem, example, claim, person, dataset, method, result, equation
        - summary: One sentence description (optional)
        - textSpan: The exact quote from the text where this concept appears (must be verbatim from the text)
        - confidence: 0.0 to 1.0

        Return ONLY a JSON object with this exact structure:
        {
          "concepts": [
            {
              "label": "...",
              "type": "...",
              "summary": "...",
              "textSpan": "...",
              "confidence": 0.95
            }
          ],
          "edges": [
            {
              "sourceLabel": "...",
              "targetLabel": "...",
              "type": "...",
              "confidence": 0.9
            }
          ]
        }

        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses

        Rules:
        - Every concept MUST have a textSpan that is an exact quote from the text
        - Do not invent concepts not present in the text
        - Prefer specific, meaningful concepts over vague ones
        - Include edges between new concepts and existing ones where relationships exist
        - Return valid JSON only, no markdown formatting

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

        Propose relationships (edges) between the concepts.

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

    // MARK: - Summarization

    static func summarize(conceptLabel: String, sourceText: String) -> String {
        return """
        Summarize the concept "\(conceptLabel)" based on this source text in 1-2 clear sentences suitable for a knowledge map node. Be concise and precise.

        Source text:
        \(sourceText)
        """
    }

    // MARK: - Question Answering

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
