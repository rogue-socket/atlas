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
        You are a concept map extraction system. Analyze the following text from "\(context.documentTitle)" (pages \(context.pageRange.lowerBound + 1)-\(context.pageRange.upperBound)) and extract concepts, their entities, and relationships between concepts.
        \(outlineHints)

        Already extracted concepts (do not duplicate): \(existingList)

        ## Core Principle

        A concept map is a network of PROPOSITIONS. Each proposition is a triple: Concept A —[linking phrase]→ Concept B that reads as a meaningful sentence. For example: "Glycolysis" —[produces]→ "Pyruvate" reads as "Glycolysis produces Pyruvate."

        Concepts have nested **entities** — specific terms, definitions, people, examples, results, equations — that belong under them.

        ## Extraction Rules

        1. Identify 3-8 CONCEPTS in this batch — coherent ideas, topics, or processes. Label them as short readable noun phrases (2-6 words). Concepts should be readable noun phrases, NOT full sentences. Good: "ATP production", "Krebs cycle enzymes". Bad: "ATP is produced by oxidative phosphorylation".

        2. For each concept, identify 1-5 ENTITIES — specific terms, definitions, examples, people, results, equations — that belong under it. Each entity must have its own textSpan.

        3. Every concept and entity MUST have a textSpan that is an EXACT verbatim quote from the text. If you cannot find an exact quote, do not include that concept or entity.

        4. Propose edges between concepts. Each edge MUST have a linkingPhrase — a short verb phrase (1-4 words MAX) that makes "sourceLabel [linkingPhrase] targetLabel" read as a grammatical sentence. Good: "produces", "requires", "inhibits", "is a type of". Bad: "is far less efficient than aerobic respiration in producing" (too long).

        5. Do not invent concepts not present in the text. Prefer specific, concrete concepts over vague abstractions.

        ## JSON Schema

        Return ONLY a JSON object with this exact structure:
        {
          "concepts": [
            {
              "label": "Concept Name (2-6 words)",
              "type": "concept",
              "summary": "One sentence explaining this concept",
              "textSpan": "exact verbatim quote from text",
              "confidence": 0.95,
              "entities": [
                {
                  "label": "Specific Entity Name",
                  "type": "definition",
                  "summary": "One sentence explanation",
                  "textSpan": "exact verbatim quote from text",
                  "confidence": 0.9
                }
              ]
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

        REQUIRED concept fields: label, type, summary, textSpan, confidence
        REQUIRED entity fields: label, type, summary, textSpan, confidence
        REQUIRED edge fields: sourceLabel, targetLabel, type, confidence, linkingPhrase
        Concept types: concept, theorem, method, claim
        Entity types: definition, example, person, dataset, result, equation
        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses
        linkingPhrase: 1-4 word verb phrase making "A [phrase] B" a readable sentence

        Note: Document and Chapter abstraction levels are extracted by separate dedicated passes. Do not produce them here — only concepts and their entities.

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
        - Dependency relationships (dependsOn): one concept requires understanding another
        - Similarity (sameTopic): concepts that overlap significantly
        - Other relationships: contradicts, extends, uses, defines, exampleOf, partOf, cites

        Edge types: dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses

        Note: structural fold edges (containsChapter, containsConcept, containsEntity) are produced by dedicated passes and must not appear here.

        Return ONLY a JSON array:
        [
          {
            "sourceLabel": "...",
            "targetLabel": "...",
            "type": "dependsOn|sameTopic|...",
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

    // MARK: - ETR Merge Adjudication

    /// Prompt the LLM with N candidate pairs in the 0.85–0.95 similarity band
    /// (per `ResolverThresholds`) and ask whether each pair should be merged.
    /// Expected output is a JSON array of N booleans in input order.
    ///
    /// Cross-level pairs (one `.concept` + one `.entity`) are explicitly
    /// called out in the prompt — same-real-world-thing only, not "similar
    /// topic." Same-name-but-different-scope cases ("on-site labs" vs
    /// "external labs", "internal audits" vs "external audits") are anti-
    /// examples drawn from the locked-in vitacare quality pairs.
    /// Public entry point. Currently routes to v2 (the published prompt that
    /// matches the rubric scores in `prds/2026-05-15_4-level-knowledge-graph.md`
    /// §"Quality Rubric v2" and the analysis in
    /// `audits/2026-05-17_etr-prompt-tune.md`).
    ///
    /// **To A/B test v3 or v4**: change the call below to
    /// `mergeAdjudicationV3(...)` or `mergeAdjudicationV4(...)`.
    /// v3 is the abstract-pattern variant (no vitacare-specific exemplars in
    /// the prompt body); v4 fixes v3's two known failure modes
    /// (asymmetric leaf-of-catalog rule + regulatory-subset MERGE category) —
    /// see `audits/2026-05-18_v3-prompt-experiment.md` and
    /// `audits/2026-05-18_rubric-v3-vitacare.md`. All versions share the
    /// pair-format helper and the final JSON-array instruction wrapper.
    static func mergeAdjudication(pairs: [(a: ConceptNode, b: ConceptNode)]) -> String {
        return mergeAdjudicationV4(pairs: pairs)
    }

    /// Pair formatter shared by every prompt revision.
    private static func formatAdjudicationBody(_ pairs: [(a: ConceptNode, b: ConceptNode)]) -> String {
        let formatPair: (Int, ConceptNode, ConceptNode) -> String = { i, a, b in
            let summaryA = a.summary?.isEmpty == false ? a.summary! : "(no summary)"
            let summaryB = b.summary?.isEmpty == false ? b.summary! : "(no summary)"
            return """
            \(i + 1). A: "\(a.label)" (type=\(a.type.rawValue), level=\(a.level.rawValue)) — \(summaryA)
               B: "\(b.label)" (type=\(b.type.rawValue), level=\(b.level.rawValue)) — \(summaryB)
            """
        }
        return pairs.enumerated().map { formatPair($0.offset, $0.element.a, $0.element.b) }.joined(separator: "\n\n")
    }

    /// **v2 — published prompt (2026-05-17).** Vitacare-specific MERGE and
    /// KEEP-SEPARATE exemplars inline. 7/7 in-band rubric recall claim was
    /// later corrected to 6/7 (`audits/2026-05-17_etr-prompt-tune.md` §A).
    /// On the 2026-05-18 fresh extraction (different abstraction level), this
    /// produced 12/52 approvals at floor 0.80 with ~33% eyeball precision —
    /// the vitacare exemplars don't match new-extraction labels, so the
    /// patterns under-generalize and over-merge.
    private static func mergeAdjudicationV2(pairs: [(a: ConceptNode, b: ConceptNode)]) -> String {
        let body = formatAdjudicationBody(pairs)
        return """
        You are deciding whether candidate pairs of knowledge-graph nodes describe the same real-world thing.

        For each numbered pair, output exactly one boolean: true to merge, false to keep separate.

        The test: could the two labels appear as bullet points under the same heading in a corporate handbook describing a single process, service, fact, or entity? If yes → merge. If they share a topic word but describe different events or different aspects → keep separate.

        MERGE when:
        - Both labels describe the same operational fact with different framings, e.g.:
          • "Asynchronous messages" ↔ "In-app messaging: response within 6 business hours" (same in-app messaging service)
          • "Lab result release: typically within 24 hours" ↔ "same-day or next-day results" (same lab-result delivery SLA)
          • "Lab results are posted to the patient portal" ↔ "Lab result release: typically within 24 hours" (same lab-result release event, one names the channel, one names the timing)
        - One label is a concept naming a process and the other is an entity describing how that process happens, e.g.:
          • "Referral Process" ↔ "referral and prior authorization handled by VitaCare care coordinators"
        - One label names a specific instance of a broader operational pathway and they are operationally the same activity, e.g.:
          • "Advanced Imaging Referrals" ↔ "External Care Coordination" (advanced imaging is referred externally via the care-coordination pathway)
          The test for this case: the two labels must describe the SAME activity from different angles, not a leaf service and the broader catalog that contains it.
        - Two entity labels describe the same role or actor performing the same task, e.g.:
          • "Care coordinator handles prior authorization" ↔ "care coordinator manages the referral end-to-end"

        KEEP SEPARATE when:
        - The labels share a noun (lab, portal, audit, insurance, officer, program, network) but describe different events or different aspects, e.g.:
          • "Lab results are posted to the patient portal" ↔ "Patient portal meets WCAG 2.1 AA accessibility standards" (same portal, different facts: release event vs accessibility standard)
          • "Insurance Networks" (accepted payors) ↔ "Insurance Policies" (corporate liability insurance)
          • "internal audits" ↔ "external audits"
          • A list of co-founders ↔ a list of compliance officers (different people, same role-noun)
          • "on-site labs" ↔ "external labs" (different vendors, different locations)
        - One is a metric or outcome and the other is a different metric, even if both are operational numbers, e.g.:
          • "98.9% on-time visit starts" ↔ "Patient Net Promoter Score: 71"
          • "Hypertension control to under 140/90 mmHg: 81%" ↔ "98.9% on-time visit starts"
        - One is an employee/staff benefit and the other is a patient-facing service, e.g.:
          • "Free VitaCare primary care for employees and dependents" ↔ "includes all primary care visits" (commercial product)
        - One is a service catalog item and the other is a vendor-management process, e.g.:
          • "Specialty Care Services" ↔ "Specialist Network Curation"
        - Both are program types but with distinct delivery modalities or populations, e.g.:
          • "Group Programs" ↔ "Chronic Condition Programs"
          • "Health Coaching" ↔ "Chronic Condition Programs"
        - One label is a leaf service or program and the other is the broader catalog or umbrella it sits inside (use a hierarchy edge, not a merge), e.g.:
          • "Post-Discharge Care" ↔ "VitaCare Services" (specific service inside the umbrella service catalog)
          • "Health Coaching" ↔ "VitaCare Services"
          • "External Care Coordination" ↔ "VitaCare Services"
          • "Group Programs" ↔ "VitaCare Services"

        When uncertain, prefer KEEP SEPARATE (false). Only merge when you can articulate the single real-world thing both labels point at.

        Pairs:
        \(body)

        Return ONLY a JSON array of \(pairs.count) booleans, one per pair, in the same order. No prose, no explanation, no code fences. Example for 4 pairs: [true, false, true, false]
        """
    }

    /// **v3 — abstract-pattern variant (2026-05-18, experimental).** Same
    /// pattern scaffolding as v2, vitacare-specific exemplars stripped, leaf-
    /// of-catalog anti-pattern made explicit via word-list heuristic. On the
    /// same 2026-05-18 fresh extraction this produced 4/52 approvals at floor
    /// 0.80 (vs v2's 12/52). Correctly rejected 5 of v2's likely-wrong merges,
    /// kept all 4 cleanest merges, but dropped 1 real merge (SUD Record
    /// Protections ↔ Behavioral Health Record Privacy — regulatory subset)
    /// because the abstract patterns don't surface that relationship.
    /// Still over-merges on 2 umbrella↔umbrella pairs where the leaf-of-
    /// catalog rule can't asymmetrically detect umbrella vs aspect.
    /// Full A/B in `audits/2026-05-18_v3-prompt-experiment.md`.
    private static func mergeAdjudicationV3(pairs: [(a: ConceptNode, b: ConceptNode)]) -> String {
        let body = formatAdjudicationBody(pairs)
        return """
        You are deciding whether candidate pairs of knowledge-graph nodes describe the same real-world thing.

        For each numbered pair, output exactly one boolean: true to merge, false to keep separate.

        The test: could the two labels appear as bullet points under the same heading in a document describing a single process, service, fact, or entity? If yes → merge. If they share a topic word but describe different events, different aspects, or different scope → keep separate.

        MERGE when ANY of these patterns fit. Each pattern names a relationship type and the criterion that must hold:

        - **Paraphrase.** Both labels describe the same operational fact, action, or measurable property — same who, same what, same when, same scope — written with different wording.
        - **Process ↔ implementation.** One label names a process at the concept level and the other describes how that exact process is carried out. The "what" must be identical at the same scope; only the abstraction level differs.
        - **Same activity from different angles.** Two labels describe the same activity (same actor + same action + same target), differing only in which side of the activity the label foregrounds. Not to be confused with the leaf-of-catalog anti-pattern below.
        - **Same role + same task.** Two role descriptions where both the actor and the task are the same.

        KEEP SEPARATE when ANY of these patterns fit. Each pattern names a failure mode the merge prompt is commonly tempted by:

        - **Shared noun, different fact.** The labels share a topic word but address different events, different aspects of the same object, different timeframes, or different scope.
        - **Different metrics.** Both are numeric outcomes but measure different things, even if related.
        - **Audience / population mismatch.** One serves an internal audience (staff, employees, vendors) and the other serves an external audience (customers, patients, regulators), even when the underlying activity rhymes.
        - **Same job-title noun, different people.** Two distinct named roles that share a role-noun ("officer", "coordinator", "lead") are not the same role.
        - **Adjacent-but-distinct programs.** Two programs of the same general type but differing by delivery modality, population, location, or vendor relationship (internal vs external, on-site vs off-site, etc.).
        - **Service vs the function that manages it.** A service offering vs the procurement / vendor-management / quality function around that service category.
        - **LEAF ↔ CATALOG (most common false-positive).** One label is a specific service, program, or item, and the other is the broader umbrella catalog, portfolio, overview, or grouping it sits inside. The relationship is hierarchy (use a hierarchy edge), NOT identity. Heuristic: if label A is a single concrete offering and label B uses words like "overview", "services", "portfolio", "model", "framework", "principles", "areas" — it is almost certainly leaf-of-catalog. Default to false here.
        - **Object ↔ property of object.** Both labels reference the same physical or organizational object, but one describes an operational use of it and the other describes a compliance, quality, or availability attribute of it.

        When uncertain, prefer KEEP SEPARATE (false). Merge only when you can articulate the single real-world thing both labels point at — without paraphrasing either label to fit the other.

        Pairs:
        \(body)

        Return ONLY a JSON array of \(pairs.count) booleans, one per pair, in the same order. No prose, no explanation, no code fences. Example for 4 pairs: [true, false, true, false]
        """
    }

    /// **v4 — noise-reduction over v3 (2026-05-18, experimental).**
    /// Two targeted edits to v3, motivated by `audits/2026-05-18_v3-prompt-experiment.md`:
    /// (1) Leaf-of-catalog rule recast as **asymmetric scope containment** —
    ///     fires when one label is strictly inside the other's scope, regardless
    ///     of which side carries the umbrella words. Stabilizes rejection of
    ///     umbrella↔umbrella pairs like "VitaCare Overview & Service Model"
    ///     ↔ "Core Care Principles" (rubric pairs #4 and #8 in
    ///     `audits/2026-05-18_rubric-v3-vitacare.md`).
    /// (2) New MERGE category **"Regulatory subset"** + paired KEEP-SEPARATE
    ///     "Parallel regimes that share a noun" anti-pattern. Names the
    ///     SUD ↔ BH privacy pattern (rubric pair #11) explicitly; in the 3-of-3
    ///     A/B (`audits/2026-05-18_v4-prompt-experiment.md`) v4 ties v3 on
    ///     stable recall but wins on union-of-approvals noise envelope
    ///     (6 vs 11 pairs over 3 runs) and worst-case behavior (4 vs 10
    ///     approvals max).
    /// Everything else carries forward from v3 unchanged.
    private static func mergeAdjudicationV4(pairs: [(a: ConceptNode, b: ConceptNode)]) -> String {
        let body = formatAdjudicationBody(pairs)
        return """
        You are deciding whether candidate pairs of knowledge-graph nodes describe the same real-world thing.

        For each numbered pair, output exactly one boolean: true to merge, false to keep separate.

        The test: could the two labels appear as bullet points under the same heading in a document describing a single process, service, fact, or entity? If yes → merge. If they share a topic word but describe different events, different aspects, or different scope → keep separate.

        MERGE when ANY of these patterns fit. Each pattern names a relationship type and the criterion that must hold:

        - **Paraphrase.** Both labels describe the same operational fact, action, or measurable property — same who, same what, same when, same scope — written with different wording.
        - **Process ↔ implementation.** One label names a process at the concept level and the other describes how that exact process is carried out. The "what" must be identical at the same scope; only the abstraction level differs.
        - **Same activity from different angles.** Two labels describe the same activity (same actor + same action + same target), differing only in which side of the activity the label foregrounds. Not to be confused with the leaf-of-catalog anti-pattern below.
        - **Same role + same task.** Two role descriptions where both the actor and the task are the same.
        - **Regulatory subset.** One label names a regulatory regime, policy framework, or compliance program; the other names a stricter subset of that regime that applies to a narrower data class, population, or jurisdiction and is layered on top of the broader one. Both labels point at the same governed object viewed at two scopes of regulation. Examples of the abstract pattern: a general privacy program and the heightened protections for one record class within it; a baseline access-control framework and the stricter consent regime for a regulated subset; a tax regime and a jurisdiction-specific overlay on top of it. Merge here when the narrower regime is genuinely a subset (not a parallel regime that happens to share a noun).

        KEEP SEPARATE when ANY of these patterns fit. Each pattern names a failure mode the merge prompt is commonly tempted by:

        - **Shared noun, different fact.** The labels share a topic word but address different events, different aspects of the same object, different timeframes, or different scope.
        - **Different metrics.** Both are numeric outcomes but measure different things, even if related.
        - **Audience / population mismatch.** One serves an internal audience (staff, employees, vendors) and the other serves an external audience (customers, patients, regulators), even when the underlying activity rhymes.
        - **Same job-title noun, different people.** Two distinct named roles that share a role-noun ("officer", "coordinator", "lead") are not the same role.
        - **Adjacent-but-distinct programs.** Two programs of the same general type but differing by delivery modality, population, location, or vendor relationship (internal vs external, on-site vs off-site, etc.).
        - **Service vs the function that manages it.** A service offering vs the procurement / vendor-management / quality function around that service category.
        - **LEAF ↔ CATALOG (most common false-positive).** One label is strictly inside the other's scope: it is one item, program, principle, or aspect contained within the broader umbrella the other label names. The relationship is hierarchy (use a hierarchy edge), NOT identity. The asymmetry test that matters is *scope containment*, not which side uses umbrella words: if everything label A refers to is also referred to by label B but not vice versa (or vice versa), it is leaf-of-catalog. This includes umbrella ↔ umbrella pairs where one umbrella is broader than the other (e.g., a whole-company service catalog ↔ a sub-aspect like care philosophy, care model, or experience design — the catalog is broader even though both sides carry umbrella words like "overview", "model", "principles", "design"). Default to false whenever you suspect one side's scope is strictly inside the other's.
        - **Object ↔ property of object.** Both labels reference the same physical or organizational object, but one describes an operational use of it and the other describes a compliance, quality, or availability attribute of it.
        - **Parallel regimes that share a noun (not a regulatory subset).** Distinguish from the Regulatory-subset MERGE category above: this anti-pattern is two governance frameworks that share a topic word but operate independently (e.g., a corporate liability insurance program ↔ a patient health-insurance acceptance list both labeled "insurance"; an internal audit function ↔ an external audit function). Keep separate when neither regime is contained within the other.

        When uncertain, prefer KEEP SEPARATE (false). Merge only when you can articulate the single real-world thing both labels point at — without paraphrasing either label to fit the other.

        Pairs:
        \(body)

        Return ONLY a JSON array of \(pairs.count) booleans, one per pair, in the same order. No prose, no explanation, no code fences. Example for 4 pairs: [true, false, true, false]
        """
    }

    /// Parse the adjudication response into `[Bool]`. Tolerates leading/
    /// trailing whitespace and ```json code fences. Throws when the JSON is
    /// invalid, not an array, or the array length doesn't match `expectedCount`
    /// (callers can't safely map decisions back to pairs on a length mismatch).
    static func parseMergeAdjudicationResponse(_ raw: String,
                                               expectedCount: Int) throws -> [Bool] {
        let cleaned = JSONRepair.cleanAndRepair(raw)
        guard let data = cleaned.data(using: .utf8) else {
            throw AIError.decodingError("adjudication response not UTF-8")
        }
        guard let bools = try JSONSerialization.jsonObject(with: data) as? [Bool] else {
            throw AIError.decodingError("adjudication response not [Bool]: \(cleaned.prefix(120))")
        }
        guard bools.count == expectedCount else {
            throw AIError.decodingError("adjudication response length \(bools.count) != expected \(expectedCount)")
        }
        return bools
    }
}
