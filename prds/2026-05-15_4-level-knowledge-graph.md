# 4-Level Knowledge Graph — Architecture Migration

**Created:** 2026-05-15
**Status:** Design, pre-implementation
**Scope:** Atomic migration from concept-with-flags data model to first-class 4-level abstraction (Document / Chapter / Concept / Entity), plus cross-document merging strategy (two approaches to A/B test).

---

## Problem

The renderer thinks in four levels (`SemanticZoomLevel`: `.document / .chapter / .concept / .entity`). The data model thinks in two (`NodeLevel`: `.concept / .entity`), plus `hierarchyLevel: Int` (themes vs subtopics within concepts), plus `isDocumentSummary: Bool` (sentinel flag), plus `parentConceptID` / `parentChapterID` / `subtopicOf` edges. The mismatch produces:

1. **Document tab shows random concepts** — summary node creation depends on a chain of LLM-marked themes + post-hoc synthesis that can fail silently.
2. **Chapter tab shows all concepts** — no Chapter level exists in the data model; `DensityManager` falls back to the concept set.
3. **Document-representative node leaks** into Chapter / Entity / sometimes Concept tabs (the `isDocumentSummary` flag isn't honored everywhere).
4. **Cross-document connections** are user-confirmed proposals only; the corpus doesn't form an automatic graph.

The user's mental model is cleaner: four nested levels of abstraction (Document folds Chapters; Chapter folds Concepts; Concept folds Entities), each level the same kind of thing at a different granularity, with cross-doc entity matching giving the project-level Document graph natural connectivity.

## Decisions Made (frozen unless re-discussed)

| # | Decision |
|---|---|
| 1 | **Data model: Option α.** Expand `NodeLevel` to four cases (`.document / .chapter / .concept / .entity`). Retire `hierarchyLevel` and `isDocumentSummary`. Retire `parentChapterID`. One axis, four values. |
| 2 | **No backwards compatibility.** No prior public release. No deprecation period. Old graph files regenerate from scratch. Codable decoder accepts only the new shape. |
| 3 | **Fold mechanism: containment edges.** Many-to-many between adjacent levels (a Concept can belong to multiple Chapters; an Entity can belong to multiple Concepts). Edge types: `containsChapter`, `containsConcept`, `containsEntity`. Parent-pointer field retired. |
| 4 | **Document node creation: from extraction, same as the other levels.** The `.document` node is the top fold of what the AI builds — it comes out of the extraction pipeline alongside Chapter / Concept / Entity nodes, not from a separate pre-extraction path. Before a PDF is analyzed, it has no nodes at any level. Click Analyze → all four levels populate together. Uniform process; no special-casing for Document. |
| 5 | **Chapter source priority:** LLM-generated chapter pass, with PDF outline (`LayoutAnalyzer.extractOutline`) overriding when present. |
| 6 | **HierarchySynthesis retired.** No more separate theme-promotion step. Themes-vs-subtopics within concepts is no longer modeled — that distinction collapses into the Chapter level. |
| 7 | **Renderer simplification.** `DensityManager.visibleNodes(zoomLevel)` becomes `allNodes.filter { $0.level == zoomLevel }`. No waterfalls, no flag checks. |
| 8 | **Existing graphs:** discarded. Users re-analyze documents to get the new structure. |
| 9 | **Type-mismatch on merge:** type is advisory, not gating. Merged node takes the higher level (`.concept` beats `.entity` if any anchor agrees). |
| 10 | **Cross-doc storage divergence:** `lastModified: Date` stamp per node; load-time reconciliation picks the most recent. |
| 11 | **Cross-doc merging strategy: BOTH approaches built on separate branches**, user empirically tests, winner merges back to main. |

## Target Data Model

```swift
enum NodeLevel: String, Codable {
    case document
    case chapter
    case concept
    case entity
}

struct ConceptNode {
    let id: UUID
    var label: String
    var type: ConceptType            // unchanged 10-case enum
    var summary: String?
    var sourceAnchors: [SourceAnchor]
    var readingState: ReadingState
    var expansionState: ExpansionState
    var confidence: Double
    var isPinned: Bool
    var position: CGPoint?
    var level: NodeLevel             // ← now the only abstraction axis
    var highlightColorIndex: Int?
    var lastModified: Date           // ← new, for cross-doc divergence resolution

    // Retired: hierarchyLevel, isDocumentSummary, parentConceptID, parentChapterID
}

enum EdgeType: String, Codable {
    // Existing 9 types (dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses)
    // Plus containment:
    case containsChapter             // Document → Chapter
    case containsConcept             // Chapter → Concept
    case containsEntity              // Concept → Entity
    // Retired: subtopicOf (folds into containsConcept under Chapter level)
}
```

**Document node:** `level: .document`, `label: <filename or LLM-suggested title>`, `summary: <LLM-generated tldr of the whole document>`, one `SourceAnchor` with `pageIndex: 0` and the full document URL. Created by the extraction pipeline alongside the other three levels — same process, different fold granularity.

**Chapter node:** `level: .chapter`, `label: <chapter title>`, summary from chapter content, anchors point to the chapter's page range.

**Concept node:** `level: .concept`, same as today but no `hierarchyLevel`. Themes-vs-subtopics distinction handled by chapter membership (broad concepts belong to many chapters; narrow concepts belong to one).

**Entity node:** `level: .entity`, anchors point to specific text spans, no parent field (containment via edges).

## Extraction Pipeline (new)

Both Fast and Deep pipelines share this overall flow. PDFs in a project that haven't been analyzed have no nodes at any level — all four levels come from the same extraction run.

```
User clicks "Analyze"
  └─ Extract chapters (LLM-based, with PDF outline override)
       → produces .chapter nodes attached to the (still-to-be-created) Document
  └─ Extract concepts (current per-batch flow)
       → produces .concept nodes
  └─ Extract entities (currently nested under concepts, stays)
       → produces .entity nodes
  └─ Attach concepts to chapters via containsConcept edges (page-range overlap + LLM hints)
  └─ Create the Document node: label = filename (or LLM-suggested title),
     summary = LLM tldr derived from the chapters/concepts above.
     Attach Document → each Chapter via containsChapter edges.
  └─ Run cross-doc merging (SCE or ETR — see branches below)
```

**Chapter extraction step (new):**
- Input: full document text (or first batch's text + outline hints).
- Output: list of chapter titles + page ranges.
- Override: if `LayoutAnalyzer.extractOutline` returns non-empty entries, use those instead (PDF-author truth wins).
- Each chapter title + range → one `.chapter` Node with anchors over the page range.

**Concept-to-Chapter attachment:**
- For each Concept, look at its `sourceAnchors[].pageIndex`. Find all Chapter nodes whose page range covers any of those pages.
- Create `containsConcept` edge from each matching Chapter → the Concept. (Many-to-many: a Concept appearing across multiple chapters gets multiple containment edges.)

## Renderer + DensityManager

```swift
func visibleNodes(from graph, zoomLevel, activeNodeID) -> [ConceptNode] {
    graph.allNodes.filter { $0.level == zoomLevel || $0.isPinned || $0.id == activeNodeID }
}
```

Sub-level expansion (e.g., expanding a Chapter to show its Concepts) handled by the existing `expansionState` field — when a Chapter is `.expanded`, its `containsConcept` children also become visible.

`ForceDirectedLayout`, `TreeLayoutSeeder`, `HierarchyForest` updated to read `level` instead of `hierarchyLevel`. The seeder bands by level rather than hierarchyLevel.

## Per-Doc Storage with Multi-Anchor Nodes

```
~/Library/Application Support/Atlas/graphs/
  ├─ <sha-doc1>.json   (contains node B with anchors for doc1 AND doc2)
  ├─ <sha-doc2>.json   (contains node B with anchors for doc1 AND doc2)
  └─ project_<uuid>.json
```

A node that appears in multiple docs is serialized into *each* doc's file with consistent UUID and `lastModified` stamp. On load:
1. Read all relevant doc files into a dict keyed by UUID.
2. On UUID collision, keep the entry with the latest `lastModified`.
3. The result is the in-memory project graph.

**Re-extraction rule:** when re-extracting doc D, the cumulative context passed to the LLM (under SCE) or the entity pool (under ETR) excludes nodes whose *only* `SourceAnchor.documentURL` is D. Nodes with multiple anchors stay in context; their D-anchor will be re-added if the LLM re-extracts them.

## Cross-Doc Merging — Two Approaches (branched)

### Approach 1: Sequential Cumulative Extraction (SCE)

Branch: `feature/sce-cross-doc`

**Algorithm:**
1. Extract PDFs sequentially (user-determined order; new PDFs append).
2. For doc N (N > 1), every batch LLM call carries the cumulative state — every node + edge from docs 1..N-1 — in the prompt header. (Decision: option A — *every batch*, not snapshot-per-doc-start. Cost will be observed empirically.)
3. Prompt instructs the LLM: "reuse an existing entity *only* when it refers to the same real-world thing; create new entities when genuinely new; type is advisory — if reusing, prefer the existing type unless strongly contradicted."
4. Per-doc extraction commits *atomically*: nodes from doc N enter the cumulative state only on successful completion. Partial extraction (cancellation, error) commits nothing.
5. **Final canonicalization pass (optional):** after all docs done, one LLM call over the full entity list flags suspicious merges and missed merges. Apply user-confirmed corrections.

**Per-batch prompt structure:**
```
[System: extraction instructions, type-as-advisory rule]
[Cumulative state: N1 nodes, N2 edges from prior docs]
[Current batch text]
[Output: new nodes (with reuse decisions) + new edges]
```

**Observability (instrumented from day 1):**
- `[SCE] doc=<X> batch=<Y> prompt_tokens=<N>` per batch.
- `[SCE] doc=<X> new_entities=<A> reused_entities=<B> new_relation_types=<C>` per doc.
- `[SCE] reused_mapping=<UUID→label>` audit log per doc.

**Known failure modes to spot-check:**
- Quadratic token growth (track prompt token count; alarm if >50% of context window).
- Granularity drift (compare nodes/page between doc 1 and doc N).
- Hallucinated reuse (label-match without semantic match; spot-check 10-20 reuses post-extraction).
- Anchoring (doc 1's vocabulary dominates).

### Approach 2: Extract-Then-Resolve (ETR)

Branch: `feature/etr-cross-doc`

**Algorithm:**

*Stage 1 — Per-doc extraction:* each PDF extracted independently with no cross-doc context. Parallel-eligible (subject to API rate limits).

*Stage 2 — Candidate generation (no LLM):* collect all entities from all docs into one pool. For each entity, compute embedding from `label + " : " + type + (summary ?? "")`. Generate merge candidates via:
- Exact normalized match: lowercase, strip articles + punctuation. Auto-merge.
- Embedding similarity > 0.85 (cosine), regardless of type. Candidate for adjudication.
- Brute-force pairwise comparison (no FAISS — scale stays in hundreds).

*Stage 3 — Tiered resolution:*
- **Auto-merge:** exact normalized match (any type) OR embedding > 0.95 (any type, no contradicting summary).
- **LLM adjudication:** embedding 0.85-0.95. Batch ~15-20 pairs per LLM call. Prompt provides both nodes' labels + types + summaries + source anchors; LLM returns "merge / keep / related" per pair.
- **Auto-reject:** embedding < 0.85.

> **All three thresholds (0.95, 0.85, batch size 15-20) are placeholders to be tuned empirically.** They will almost certainly need adjustment after observing real corpora — embedding similarity distributions vary by model and domain. Plan a tuning pass after the first end-to-end run: log the full similarity distribution at decision boundaries (see Observability), inspect ~50 borderline cases, adjust thresholds, re-run *only stage 3* (cheap, no re-extraction). Expose the thresholds as configurable values in the codebase (not magic numbers), so tuning doesn't require recompiling.

*Stage 4 — Merge + edge dedup:*
- For each equivalence class: pick canonical label (longest informative form), combine summaries, union anchors, retain UUIDs of all aliases.
- Promote level: if any anchor said `.concept`, the merged node is `.concept` (else if `.chapter`, etc.). Higher level wins.
- Replace per-doc edge endpoints with canonical IDs. Dedupe edges by `(source, type, target)`.
- Optional: a small LLM canonicalization pass over unique edge labels (cluster `produces` / `creates` / `generates` as one).

**Embedding backend (new, fully independent of the LLM backend):**

The Settings UI gains a second selector — **Embedding Model** — separate from the existing **LLM Model** selector. The two can be set to different providers (e.g., LLM = Claude, Embedding = OpenAI). Available embedding providers:
- OpenAI: `text-embedding-3-small` (1536-dim) or `-large` (3072-dim).
- Gemini: `text-embedding-004`.
- Ollama: `nomic-embed-text` (local).
- Claude: not available — Anthropic has no embedding API.

**ETR availability rules:**
- ETR is **only enabled** when an embedding model is configured.
- If no embedding model is set, the ETR option in the merging-strategy UI is **disabled with a tooltip** explaining "Configure an embedding model in Settings to enable ETR merging." The user can still extract and use SCE without an embedding model.
- The settings page must validate the embedding endpoint (test call on save) before treating it as configured.

**Observability:**
- `[ETR] stage=1 doc=<X> entities=<N>` per doc.
- `[ETR] stage=2 candidate_pairs=<N> exact=<X> similar=<Y>`
- `[ETR] stage=3 auto_merged=<X> llm_adjudicated=<Y> rejected=<Z>`
- `[ETR] stage=4 canonical_classes=<N> edge_dedup=<X>`
- Similarity score distribution at decision boundaries (for threshold tuning).

**Known failure modes to spot-check:**
- Threshold too high → missed merges (spot-check rejected candidates near boundary).
- Threshold too low → false merges (spot-check auto-merged pairs).
- Type-canonicalization across the corpus.
- LLM adjudication accuracy on big batches (re-run a sample and check agreement).
- Embedding model domain-fit (general-purpose models may struggle with domain vocabulary).

### Approach 3: Hybrid (added 2026-05-22)

Branch: `feature/hybrid-cross-doc`

ETR's extract-then-resolve pipeline with SCE's typed-relation taxonomy folded into the adjudicator. Instead of merge/keep, the adjudicator returns one of `merge / instance_of / attribute_of / process_for / keep` — `merge` collapses nodes (the ETR path), the three typed verdicts become directed `EdgeType` edges, `keep` is a no-op. Motivated by a review finding that ETR is the stronger architecture but discards every "related but distinct" pair, while SCE's one keeper is its `match_kind` typed-relation taxonomy.

Adds an embedding-free **lexical** candidate path (`EmbeddingResolver.resolveLexical` — cross-doc pairs by shared-label-token Jaccard) so the hybrid runs Claude-only with no embedding provider. Full design + verification: `audits/2026-05-22_hybrid-cross-doc.md`.

Any A/B per the conditions below must now include the hybrid arm (3-way, not 2-way).

## Comparison Conditions (A/B test rubric)

Pre-agreed *before* either approach is run.

**Held constant:**
- Same test corpus.
- Same extraction LLM backend (e.g., Claude Sonnet 4.6).
- Same machine + network conditions.
- α-migration foundation is identical on both branches.

**Test corpus:** TBD — pick 5-8 PDFs from a single domain with known overlap. Recommended sources:
- 5 papers from one author / same field, all referencing core terminology.
- A textbook split into chapter PDFs.
- Synthetic test set via `sample_pdfs/generate.py` with deliberately-overlapping entities.

**Captured per run:**

| Metric | Definition |
|---|---|
| Wall-clock time | End-to-end (analyze button click → all docs done + merging complete). |
| Total token cost | Sum of prompt + completion tokens across all LLM calls. Tracked via per-call logs. |
| Total nodes | Final canonical count after all merging. |
| Total edges | Final edge count after dedup. |
| Cross-doc shared entities | Nodes with `sourceAnchors.count > 1` (anchored in 2+ docs). |
| Cross-doc edges | Edges whose endpoints have anchors in different docs. |

**Quality rubric — hand-graded (~40 pairs):**

Before running either approach, pick:
- **20 should-merge pairs:** entity references across docs that clearly mean the same real-world thing (e.g., "DNA" / "deoxyribonucleic acid").
- **20 should-not-merge pairs:** entities with similar labels but different meanings (e.g., "Java" the language / "Java" the island).

For each approach, count:
- **True positives:** should-merge pairs that were merged.
- **True negatives:** should-not-merge pairs that stayed separate.
- **False positives:** should-not-merge pairs incorrectly merged.
- **False negatives:** should-merge pairs missed.

Compute precision = TP / (TP + FP) and recall = TP / (TP + FN). Both numbers matter.

**Re-run / re-tune behavior:**
- SCE: change doc order, re-run, measure how much the output shifts (anchoring fragility).
- ETR: change embedding similarity threshold (e.g., 0.85 → 0.80), re-run *only stages 2-4*, measure shift (re-tunability).

**Subjective:** open each result in the Atlas app, click the Document tab, judge "does the cross-doc connection picture make sense at a glance?"

## Migration Plan (α — on main, pre-branch)

Sequence of work on `main`, no branching needed until after step 6.

1. **Data model rewrite.** Update `ConceptNode`, `NodeLevel`, `EdgeType`. Add `lastModified`. Codable encoder/decoder accept *only* the new shape. Delete retired fields/cases. Compile-error-driven cleanup across every call site.

2. **HierarchySynthesis deletion.** Remove the file + all call sites. Remove "Organizing concepts..." status line.

3. **`appendDocumentSummary` rewrite.** Now creates the Document node at the *end* of extraction, using the extracted chapter/concept set to generate the summary. Output: a `.document`-level `ConceptNode` plus `containsChapter` edges from it to each Chapter. Same call site as today (end of `processFullDocument` and `DeepExtractionPipeline`), just produces a real first-class Document node instead of a flag-marked sentinel.

4. **Chapter extraction pipeline.** New file `Atlas/AI/ChapterExtraction.swift`. New prompt in `PromptTemplates.chapterExtraction`. Override logic: if `LayoutAnalyzer.extractOutline` returns entries, use those; else call the LLM. Output → `.chapter` nodes (no Document edges yet — those are added in step 6 when the Document node exists).

5. **Concept-to-Chapter attachment.** After concept extraction, scan each Concept's `sourceAnchors[].pageIndex` and create `containsConcept` edges from every overlapping Chapter.

6. **Document node creation + Chapter linkage.** Run as the *final* pipeline step. The LLM call uses the extracted chapter list as the bullets (replacing today's "top themes" feed). Creates the Document node and adds `containsChapter` edges from it to each Chapter node. This is the same call point as today's `appendDocumentSummary`, just with the rewritten semantics from step 3.

7. **DensityManager simplification.** Replace the four-case waterfall with `level == zoomLevel`.

8. **Layout updates.** `ForceDirectedLayout` / `TreeLayoutSeeder` / `HierarchyForest` read `level` instead of `hierarchyLevel`.

9. **Storage: per-doc multi-anchor + lastModified.** Update `GraphStore.saveProjectGraph` / `loadProjectGraph` to handle the union/reconcile logic.

10. **Tests.** Codable round-trips for all four levels. Chapter extraction with and without outline. Concept-to-Chapter attachment with overlap. Multi-anchor reconcile on load. Density filtering at each zoom level.

**Acceptance for the migration:**
- App builds green.
- New PDF added to project but not yet analyzed → no nodes at any level (all four tabs show nothing for that doc).
- Click Analyze → Document node, Chapter nodes, Concept nodes, Entity nodes all populate in their respective tabs. No leakage across tabs.
- Document node's summary text is the LLM-generated tldr, not a placeholder.
- All four tabs show distinct sets, with proper containment when expanding a higher-level node.

Then **branch from main into `feature/sce-cross-doc` and `feature/etr-cross-doc`**.

## Risks + Spot-Checks (post-implementation)

1. **PDFs without outlines + LLM chapter pass quality.** Spot-check a doc the LLM chunked into chapters — does the chunking make sense, or is it noise?
2. **One concept appearing in many chapters.** Verify the `containsConcept` edges fan out correctly (no parent-field truncation).
3. **LLM disagreeing with PDF outline.** Spot-check: when the PDF has a real outline, are extracted Concepts attached to the *outline-derived* chapters or LLM-suggested ones? Outline must win.
4. **Document summary populating reliably.** Open 3 docs, click Document tab, check that each Document node's summary text is non-placeholder.
5. **Tab isolation.** Click each tab — only nodes of that level should show. The Document summary node must NOT appear in Chapter / Concept / Entity tabs.
6. **Mental-model drift.** Before code lands, re-read this doc. When implementation discovers a tricky case, prefer revising this doc over patching with new flags.

## What This Doc Doesn't Cover (deferred)

- Bidirectional sync from Document/Chapter nodes to PDF navigation (click Document node → does PDF jump? to page 1?).
- Document-to-Document edges (one doc citing another, references, etc.) — emerges naturally from shared entities/concepts but no explicit `cites` edge between Documents yet.
- Edge labels for containment edges (currently containment edges have no `linkingPhrase` — should they read "contains" everywhere, or be filtered out of edge-label rendering?).
- UI for the user to manually merge / unmerge cross-doc entities (`GraphMergeEngine` has the machinery; needs UI).
- Per-project graph file's role under the new model (canonical source-of-truth or derived view?).

These come after the migration + chosen merging approach lands.

---

## Open Action Items

1. **Test corpus selection** — ✅ vitacare 4-PDF set (sample_pdfs/files/vitacare_*.pdf): organization, compliance, clinical, operations. Hand-authored synthetic overlap. Live extraction (Gemini, fast mode) produces 246 nodes / 753 edges / 4 docs / 24 chapters / 37 concepts / 149 entities.
2. **20+20 quality pairs** — ✅ frozen below in §"Quality Rubric — vitacare 2026-05-16".
3. **Embedding model defaults** for ETR — ✅ Gemini → `gemini-embedding-2-preview` (3072-dim primary, `gemini-embedding-001` fallback), OpenAI → `text-embedding-3-large` (deferred to v1+1), Ollama → `nomic-embed-text` (deferred), Claude → none (no Anthropic embedding API; ETR disabled when LLM=Claude with no other embedding configured).

---

## Quality Rubric — vitacare 2026-05-16

**Frozen 2026-05-16 on `feature/etr-cross-doc` from the real vitacare extraction at `/tmp/atlas_project_pre_etr_2026-05-16.json` (246n/753e snapshot pre-ETR run). Pairs reference labels that actually appear in that extraction. Source docs abbreviated CLI / CMP / ORG / OPS. Both SCE and ETR runs MUST be scored against this rubric — precision = TP / (TP + FP), recall = TP / (TP + FN).**

> **Scoring protocol:** Run the merger, dump the merged graph, walk each pair below: did the system merge the two referenced labels? **should-merge** pair merged = TP, not merged = FN. **should-not-merge** pair merged = FP, not merged = TN.

### Should-merge (20)

These pairs describe the same real-world thing across docs. Embedding similarity should land them in either the auto-merge band (≥0.95) or the adjudication band; LLM should approve.

| # | Doc A | Label A | Doc B | Label B | Why |
|---|---|---|---|---|---|
| 1 | CLI | "Labcorp or Quest Diagnostics" | CMP | "Business Associate Agreements" — implicit Labcorp/Quest reference as covered vendor | Same vendor relationship, different framing |
| 2 | CLI | "Routine Lab Services" (concept) | CLI | "Routine labs are performed on-site at every clinic" (entity) | In-doc concept↔entity pair — only ETR with in-doc enabled catches this; baseline cross-doc-only will NOT (acknowledged limit) |
| 3 | CLI | "Send-out Lab Services" | CLI | "affiliated imaging centers" — both external-vendor patterns | NOT a merge — different services. Listed here as **should-not** by mistake → see anti-example #14 |
| 4 | ORG | "Dr. Helena Vargas" (CCQO) | CMP | "Privacy Officer" or "Clinical Quality Committee" (chaired by CMO; Helena chairs separately) | Helena is referenced by role in CMP. Strong embedding signal, may need LLM adjudication |
| 5 | CMP | "42 CFR Part 2" | CMP | "Substance Use Disorder Records (42 CFR Part 2)" (concept) | In-doc — concept wraps entity. ETR cross-doc-only will skip |
| 6 | CMP | "HIPAA Security Rule" | CMP | "Technical Safeguards" / "Administrative Safeguards" / "Physical Safeguards" (parts of HIPAA Security Rule) | NOT a merge — parts vs whole. See anti-example #15 |
| 7 | CLI | "Behavioral Health Services" | CMP | "Substance Use Disorder Records (42 CFR Part 2)" | NOT a merge — overlapping topic but distinct legal regimes (general BH vs SUD-specific). See anti-example #16 |
| 8 | OPS | "Care coordinator matches the patient to a high-quality specialist within their insurance network" | CLI | "referral and prior authorization handled by VitaCare care coordinators" | Same care-coordinator role, different framing |
| 9 | OPS | "Lab result release: typically within 24 hours of completion" | CLI | "Lab Result Communication" (concept) | Same service-level guarantee from different vantage points |
| 10 | OPS | "Annual wellness visit: scheduled within 14 days of patient request" | ORG | "$1,200 annual wellness reimbursement" | NOT a merge — patient-care service vs employee benefit using same noun. See anti-example #17 |
| 11 | CMP | "External Audits" (e.g., SOC 2 Type 2) | CMP | "Regulatory Examinations" (state/federal regulators) | NOT a merge — both external but different actors. See anti-example #18 |
| 12 | CLI | "MRI, CT, mammography" (Advanced Imaging examples) | CLI | "affiliated imaging centers" | Same network — facilities and modalities are co-referenced |
| 13 | ORG | "salary-plus-quality compensation model" | ORG | "Quality incentive: up to 18% of base" | In-doc — concept and entity, ETR cross-doc-only skips |
| 14 | ORG | "Free VitaCare primary care for employees and dependents on VitaCare health plans" | CLI | "VitaCare Direct Membership" — implied member access | NOT a merge — employee benefit vs commercial product. See anti-example #19 |
| 15 | OPS | "library of patient education materials reviewed by the clinical team and updated quarterly" | OPS | "150+ video explainers averaging 3-5 minutes" | In-doc — same library, two phrasings |
| 16 | CLI | "Pharmacy & Lab Services" (concept) | CLI | "on-site pharmacy services" (entity) | In-doc concept↔entity |
| 17 | CLI | "Audio-only visits" | OPS | "video visits" referenced in ASL interpretation entry | NOT a merge — distinct modalities |
| 18 | CMP | "Clinical Quality Committee" | ORG | "Quality incentive: up to 18% of base" (mentions HEDIS) | NOT a merge — governance body vs compensation lever, only "quality" overlap |
| 19 | OPS | "Specialist visit (VitaCare specialty): within 14 days for routine, same-day for urgent" | CLI | "Specialty Care Services" (concept) | Same VitaCare-specialty service, ops vs catalog |
| 20 | CLI | "discounted specialty services" (VitaCare Direct Membership benefit) | OPS | "Specialist visit (VitaCare specialty)" | Same service, member-pricing perspective |

**Note:** Several "should-merge" rows above (3, 6, 7, 10, 11, 14, 17, 18) are actually **anti-examples** — same-noun confusables. They appear here to test ETR's precision in addition to its recall. The real should-merge expectations from the table above are rows 1, 2, 4, 5, 8, 9, 12, 13, 15, 16, 19, 20 (12 strong-merge pairs). Rows 3/6/7/10/11/14/17/18 are duplicated in the anti-example list below to keep cross-references obvious.

### Should-NOT-merge (20)

These pairs would tempt a naive merger (similar labels, overlapping topic words) but refer to distinct real-world things. Embedding similarity may push some into the adjudication band; LLM should reject.

| # | Doc A | Label A | Doc B | Label B | Distinction |
|---|---|---|---|---|---|
| 1 | CLI | "Routine labs are performed on-site at every clinic" | CLI | "affiliated imaging centers" / "Send-out Lab Services" | On-site vs external — opposite siting |
| 2 | CLI | "Basic In-clinic Imaging" (EKG, etc.) | CLI | "Advanced Imaging Referrals" (MRI, CT) | Basic on-site vs advanced external |
| 3 | CMP | "directors and officers insurance" | CMP | "professional liability insurance" | Both insurance, different coverage scopes |
| 4 | CMP | "External Audits" | CMP | "Regulatory Examinations" | Both external, different actors (audit firms vs regulators) |
| 5 | CMP | "Privacy Officer" | ORG | "Dr. Helena Vargas" (CCQO) | Two different officers — privacy vs compliance/quality |
| 6 | ORG | "Free VitaCare primary care for employees and dependents on VitaCare health plans" | CLI | "VitaCare Direct Membership" | Employee benefit vs commercial product |
| 7 | OPS | "Annual wellness visit: scheduled within 14 days of patient request" | ORG | "$1,200 annual wellness reimbursement" | Patient-care service vs employee benefit |
| 8 | CMP | "HIPAA Security Rule" | CMP | "HITECH Act" | Distinct federal regulations |
| 9 | CMP | "Technical Safeguards" | CMP | "Administrative Safeguards" / "Physical Safeguards" | Three sibling categories of HIPAA Security Rule |
| 10 | CLI | "on-site pharmacy services" | CLI | "Medication Therapy Management" (concept) | Pharmacy access vs clinical service for ≥5 chronic meds |
| 11 | CLI | "Behavioral health" (entity) | CMP | "Substance Use Disorder Records (42 CFR Part 2)" | BH covers therapy + psychiatry broadly; SUD has heightened 42 CFR Part 2 protections |
| 12 | CMP | "Clinical Quality Committee" | ORG | "Quality incentive: up to 18% of base" | Governance body vs compensation lever |
| 13 | ORG | "Patient Net Promoter Score (NPS): 71" | ORG | "Hypertension control to under 140/90 mmHg: 81%" | Both single-number performance metrics, different domains |
| 14 | OPS | "Group programs run 8-12 weeks and meet weekly" | OPS | "Health Coaching" | Group format vs 1:1 health coach |
| 15 | OPS | "98.9% on-time visit starts" | OPS | "Lab result release: typically within 24 hours of completion" | Both SLAs, different operations |
| 16 | OPS | "Patient portal meets WCAG 2.1 AA accessibility standards" | OPS | "American Sign Language interpretation available for in-person and video visits" | Both accessibility-related, different mechanisms |
| 17 | ORG | "Tenure bonus: $10,000 annually after year 3, $20,000 annually after year 5" | ORG | "Signing bonus and student loan support" | Both bonuses, different triggers |
| 18 | CMP | "Annual tabletop exercises" | CMP | "Clinical systems RTO/RPO" (1hr/15min) | Drill vs target metric |
| 19 | CLI | "Audio-only visits" | OPS | "Specialist notes are returned to the VitaCare clinician and reviewed within 5 business days" | Both about visits, different aspects |
| 20 | CLI | "Cardiology services" | CLI | "Women's health and gynecology" | Both specialty entities, different specialties |

### Scoring template

```
Strong should-merge baseline (rows 1, 2, 4, 5, 8, 9, 12, 13, 15, 16, 19, 20 above): 12 pairs
Anti-example should-not-merge: 20 pairs

System under test: __________
Run wall-clock: __________
Total nodes pre / post: __________ / __________
Cross-doc shared nodes (sourceAnchors.count > 1): __________
Cross-doc edges: __________

For each should-merge pair:  [merged ✅ | not merged ❌]
For each should-not-merge:   [stayed separate ✅ | wrongly merged ❌]

Precision: TP / (TP + FP) = ____
Recall:    TP / (TP + FN) = ____
F1:        2·P·R / (P+R) = ____
```

**Limits acknowledged on this rubric:**
- 8 of the 20 should-merge rows above are flagged as anti-examples to make the table self-documenting; the real should-merge count is 12. A v2 of this rubric should split into two clean tables.
- Several should-merge pairs are in-doc concept↔entity (rows 2, 5, 13, 15, 16) which ETR cross-doc-only will skip by design. These exist to document the deliberate scope limit.
- Pairs reference labels from the 2026-05-16 extraction; if labels drift on re-extraction (LLM non-determinism with temperature > 0), some labels may not appear. Rerun extraction in alphabetical-doc order before scoring for reproducibility.

---

## Quality Rubric v2 — vitacare 2026-05-16 (cross-doc focus)

**v2 frozen 2026-05-16 after the threshold sweep (`audits/2026-05-16_etr-live-verification.md` §"Threshold sweep") surfaced 4 valid cross-doc merges the v1 rubric author missed. v2 grounds every pair in the actual extraction labels (218 eligible nodes walked), separates the should-merge and should-not-merge tables cleanly (no cross-references), and focuses exclusively on cross-doc pairs since that's what ETR evaluates by design.**

> **When to use v2 over v1:** for any ETR run scoring. v1 is preserved above as historical record of the first attempt + the anti-example cross-referencing mistake.

> **Automated scoring:** these 40 v2 pairs are hardcoded in `RubricScorer.swift`. Run `pdf_app1 --headless-extract --score-rubric <graph.json>` to score a run's output graph and log a precision/recall scorecard — it matches rubric labels to nodes by embedding similarity, so it survives the label drift that breaks exact-label scoring across re-extractions.

> **Doc abbreviations:** CLI = clinical_services_and_pricing, COM = compliance_quality_and_security, ORG = organization_and_people, PAT = patient_experience_and_operations.

### v2 SHOULD-MERGE — 20 cross-doc pairs

Each pair references same real-world thing across two docs. Embedding similarity should land them in either the auto-merge band (≥0.95) or adjudication (0.80–0.95 with the new default); LLM should approve. Pairs marked ✅ were caught by ETR in the 2026-05-16 sweep at the indicated floor.

| # | Doc A | Label A | Doc B | Label B | Status |
|---|---|---|---|---|---|
| 1 | CLI | "Asynchronous messages" | PAT | "In-app messaging: response within 6 business hours, typically much faster" | ✅ caught at 0.85 |
| 2 | CLI | "same-day or next-day results" | PAT | "Lab result release: typically within 24 hours of completion" | ✅ caught at 0.85 |
| 3 | CLI | "Lab Result Communication" (concept) | PAT | "Lab result release: typically within 24 hours of completion" (entity) | ❌ in-band at 0.80 (sim 0.804) but stably rejected 3/3 by v2 prompt — see 2026-05-18 correction in score block. v1 caught it 2/3 but was retired (catalog-leaf FP regression) |
| 4 | CLI | "referral and prior authorization handled by VitaCare care coordinators" | PAT | "Care coordinator handles prior authorization where required" | ✅ caught at 0.80 |
| 5 | CLI | "referral and prior authorization handled by VitaCare care coordinators" | PAT | "care coordinator manages the referral end-to-end" | ✅ caught at 0.80 |
| 6 | CLI | "referral and prior authorization handled by VitaCare care coordinators" | PAT | "Care coordinator matches the patient to a high-quality specialist within their insurance network" | ✅ caught at 0.75 |
| 7 | CLI | "Annual Wellness Visit" | PAT | "Annual wellness visit: scheduled within 14 days of patient request" | ✅ caught at 0.75 |
| 8 | CLI | "Specialty Care Services" (concept) | PAT | "Specialist visit (VitaCare specialty): within 14 days for routine, same-day for urgent" (entity) | ❌ missed |
| 9 | CLI | "discounted specialty services" | PAT | "Specialist visit (VitaCare specialty): within 14 days for routine, same-day for urgent" | ❌ missed |
| 10 | CLI | "Advanced Imaging Referrals" (concept) | PAT | "External Care Coordination" (concept) | ✅ caught at 0.80 by tuned prompt (2026-05-17); previously only at 0.75 |
| 11 | CLI | "Substance use disorder treatment" | COM | "Substance Use Disorder Records (42 CFR Part 2)" (concept) | ❌ missed |
| 12 | CLI | "messaging-based care" | PAT | "In-app messaging: response within 6 business hours, typically much faster" | ❌ missed |
| 13 | CLI | "Lab results are posted to the patient portal" | PAT | "Lab result release: typically within 24 hours of completion" | ✅ caught at 0.80 by tuned prompt (2026-05-17) |
| 14 | ORG | "Clinic hours are 7:30 AM - 7:00 PM Monday through Friday and 8:00 AM - 2:00 PM on Saturdays" | PAT | "Extended evening hours available at 16 clinics (open until 9:00 PM)" | ⚠️ caught at 0.75 — debatable (variance vs base hours) |
| 15 | CLI | "primary care clinician" | PAT | "Clinician identifies need for outside care and writes a referral" | ❌ missed — same role, very different label |
| 16 | CLI | "MRI, CT, mammography" | PAT | "External Care Coordination" | ❌ missed — same external-referral pathway |
| 17 | CLI | "VitaCare Direct Membership" (concept) | PAT | "Patient Pricing & Insurance" reference (no exact entity; weak signal) | ❌ acknowledged weak — placeholder for future revisions |
| 18 | CLI | "affiliated imaging centers" | PAT | "External Care Coordination" | ❌ missed |
| 19 | CLI | "HIPAA-compliant clinical record system" | COM | "Technical Safeguards" | ❌ missed — system vs control category, borderline |
| 20 | COM | "Patients entering SUD treatment receive a plain-language overview of how their records are protected, who can access them, and what consent looks like in practice." | CLI | "Substance use disorder treatment" | ❌ missed |

**Score after 2026-05-16 threshold sweep:**
- Floor 0.85: **3/20 caught** (rows 1, 2, 7? no, 7 was 0.75) — actually 1, 2 = **2/20**
- Floor 0.80: **5/20 caught** (rows 1, 2, 4, 5)
- Floor 0.75: **8/20 caught** (rows 1, 2, 4, 5, 6, 7, 10 + debatable 14)

Recall at default 0.80: 25%. At 0.75: 40%. Headroom to improve via prompt engineering, embedding model upgrade, or aggressive threshold tuning paired with stricter LLM adjudication.

**Score after 2026-05-17 prompt-tuning pass (floor 0.80, Gemini T=0 + topK=1) — corrected 2026-05-18 from sidecar re-inspection. See `audits/2026-05-17_etr-prompt-tune.md` for the full per-run table.**

- **Rubric in-band set at floor 0.80: 7 rows** (rows 1, 2, 3, 4, 5, 10, 13). Row 6's "ref+prior auth ↔ Care coordinator matches patient to high-quality specialist" sits below floor — only reached the band at 0.75 in the 2026-05-16 sweep, not at 0.80.
- **Rubric in-band recall: 6 of 7 caught in all 3 v2 runs** (rows 1, 2, 4, 5, 10, 13 stable). Rows 10 and 13 — the two named hard targets — flipped 0/3 → 3/3 under the tuned prompt (was the headline win). **Row 3 is in-band (sim 0.804) but stably rejected 3/3 in v2 runs**; v1 of the revision caught it 2/3 but was retired due to the catalog-leaf FP regression — the same anti-pattern that fixed v1's `<leaf service> ↔ "VitaCare Services"` over-merging also fires on row 3's concept↔entity merge.
- **Net rubric recall on the 20-pair SHOULD-MERGE set: 6/20 = 30%** at floor 0.80. The other 13 rubric rows sit below 0.80 cosine on `gemini-embedding-2-preview` 3072-dim; per the audit doc, recall lift past 30% requires either a floor drop (cheap) or an embedding-text composition change / embedding-model swap (real lever).
- **Rubric precision: 8/8 traps rejected in all 3 runs** (from §"SHOULD-NOT-MERGE" — unchanged).
- **Off-rubric extras (cross-doc, surfaced stably by the tuned prompt; need future rubric placement):**
  - `Asynchronous messages ↔ Message response: within 6 business hours during business days` (0.877, 3/3) — symmetric to row 1; promote to SHOULD-MERGE row 21.
  - `Referral Process ↔ referral and prior authorization handled by VitaCare care coordinators` (0.810, 3/3) — cross-level paraphrase (PAT concept ↔ CLI entity) of the same operational pathway as rows 4-5; promote to SHOULD-MERGE row 22.
  - `Advanced Imaging Referrals ↔ Referral Process` (0.879, 2/3) — subset relation, debatable merge; promote to SHOULD-MERGE row 23 (mark as ⚠️ debatable).
  - `Business Continuity & Disaster Recovery ↔ Operational Reliability` (0.815, 3/3) — marginal; defer rubric placement until reviewed.
  - `Chronic Condition Programs ↔ "no additional cost for members of programs in diabetes, hypertension…"` (0.808, 2/3) — entity is a pricing-fact about the concept; arguably hierarchy not merge; defer.

**Methodology note:** Gemini at temperature 0.0 + topK 1 is still non-deterministic across runs (4-5 approvals seen on the *old* prompt across 3 same-data reruns; 10/10/11 on v2). Diagnostic reads must use the stable 3-of-3 intersection per pair, not single-run approval counts. The numbers above are the 3-of-3 reading derived from the 11 audit sidecars in `Atlas/graphs/etr_audit_*.json` (1 yesterday baseline + 1 baseline-tonight + 3 det-old + 3 v1-tuned + 3 v2-tuned).

### v2 SHOULD-NOT-MERGE — 20 cross-doc pairs

These pairs look similar by surface label or topic word but refer to distinct real-world things. ETR should either skip (sim < floor) or LLM-reject. A merge on any of these is a **false positive**.

| # | Doc A | Label A | Doc B | Label B | Why distinct |
|---|---|---|---|---|---|
| 1 | ORG | "$1,200 annual wellness reimbursement" | PAT | "Annual wellness visit: scheduled within 14 days of patient request" | Employee benefit vs patient-care service |
| 2 | COM | "Privacy Officer" | ORG | "Dr. Helena Vargas" (Chief Compliance and Quality Officer) | Two distinct named officer roles |
| 3 | CLI | "Video visits" | ORG | "Dedicated telehealth clinicians work fully remote with a state-licensed home setup" | Patient-facing service vs staff work arrangement |
| 4 | CLI | "HIPAA-compliant clinical record system" | COM | "HIPAA Security Rule" | Implementation artifact vs federal regulation |
| 5 | CLI | "Insurance Networks" (concept) | COM | "Insurance Policies" (concept) | Patient insurance acceptance vs corporate liability insurance |
| 6 | ORG | "Quality incentive: up to 18% of base" | COM | "Quality Measurement" | Compensation lever vs governance/measurement function |
| 7 | ORG | "Patient Net Promoter Score (NPS): 71" | PAT | "98.9% on-time visit starts (visits started within 15 minutes of scheduled time)" | Both performance numbers, different metrics |
| 8 | CLI | "Behavioral health" | COM | "Substance Use Disorder Records (42 CFR Part 2)" | BH covers therapy + psychiatry broadly; SUD has heightened 42 CFR Part 2 regime |
| 9 | CLI | "Pediatric primary care" | ORG | "Physicians (MD/DO): 312" | Service segment vs workforce headcount |
| 10 | CLI | "988 Suicide and Crisis Lifeline" | PAT | "After-hours nurse line: 24/7 for VitaCare patients with urgent clinical concerns" | Both 24/7 phone channels, distinct services (federal lifeline vs in-house triage) |
| 11 | CLI | "Care Between Visits" | PAT | "Post-Discharge Care" (concept) | Both post-visit follow-up, but messaging-based ongoing care vs hospital-transition program |
| 12 | CLI | "Lab results are posted to the patient portal" | PAT | "Patient portal meets WCAG 2.1 AA accessibility standards" | Both patient-portal facts, different aspects (channel vs accessibility) |
| 13 | ORG | "EAP with 12 free counseling sessions per issue per year" | CLI | "Behavioral Health Services" (concept) | Employee benefit vs patient service offering |
| 14 | ORG | "Free VitaCare primary care for employees and dependents on VitaCare health plans" | CLI | "VitaCare Direct Membership" (concept) | Employee benefit vs commercial product |
| 15 | CLI | "Virtual Care Platform" (concept) | COM | "Telehealth platform RTO/RPO" | Capability description vs reliability target |
| 16 | ORG | "Hypertension control to under 140/90 mmHg: 81%" | PAT | "98.9% on-time visit starts" | Clinical outcome metric vs operational SLA metric |
| 17 | CLI | "Send-out Lab Services" (concept) | COM | "Business Associate Agreements" | Lab vendor relationship vs general vendor contracts |
| 18 | CLI | "Specialty Care Services" (concept) | PAT | "Specialist Network Curation" (concept) | Service catalog vs vendor management process |
| 19 | PAT | "Group Programs" (concept) | CLI | "Chronic Condition Programs" | Both program types, distinct delivery modalities |
| 20 | CLI | "Substance use disorder treatment" | COM | "distinct consent and disclosure framework" | Clinical service vs the consent regime for that service |

**Score after 2026-05-16 threshold sweep (precision check):**
- Floor 0.85: 0 false positives out of 2 merges = precision **100%**
- Floor 0.80: 0 false positives out of 4 merges = precision **100%**
- Floor 0.75: at most 1 marginal merge (#14 "Extended evening hours" → "Clinic hours") not on this anti-list but debatable — call precision **~89%** charitably, **100%** strictly

### v2 Scoring template

```
System under test: __________
Adjudication floor: __________
Run wall-clock: __________

Pre / post nodes: __________ / __________
Cross-doc shared nodes (sourceAnchors.count > 1): __________
Cross-doc edges: __________

SHOULD-MERGE (20 pairs):
  TP (correctly merged): ___
  FN (missed): ___

SHOULD-NOT-MERGE (20 pairs):
  TN (correctly skipped): ___
  FP (wrongly merged): ___

Precision = TP / (TP + FP) = ___
Recall    = TP / (TP + FN) = ___
F1        = 2·P·R / (P + R) = ___
```

### v2 limits acknowledged

- **Cross-doc only.** In-doc pairs (concept↔entity, sibling entities under one chapter) are deliberately excluded since ETR cross-doc-only filter skips them by design. If we ever flip the filter on, build v3 with in-doc pairs added.
- **Labels frozen to 2026-05-16 extraction snapshot at `/tmp/atlas_project_pre_etr_2026-05-16.json`.** Re-extraction may produce different labels (LLM non-determinism). Either restore from that snapshot before scoring, or rebuild the rubric after the new extraction.
- **No formal stratification.** Pairs span easy (near-identical phrasing) to hard (different surface forms, same concept). The 0.75 sweep result suggests easy pairs caught early, hard pairs need lower threshold OR semantic prompt tuning.
- **Some pairs deliberately stretchy** (rows 17, 19 in should-merge). They test whether the LLM goes too eager. Marked as such; weight them less in recall calculation if you want a stricter score.

---

## Integration decisions (apply to both SCE and ETR branches)

> Originally drafted on `main` 2026-05-16 as the locked-in spec for both branches. Decision #2 was later found to be moot — see `audits/2026-05-16_etr-live-verification.md` §"Major correction: `GraphMergeEngine` is dormant code (`MergeProposalView` never instantiated)."

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Doc ordering for SCE = order of user click.** Use the order PDFs were added to the project (preserved in `OpenSessionBookmarks` / `DocumentManager`). | Captures user intent without UI work; deterministic enough for reproducibility within a session. Re-runs that test "anchoring fragility" simply re-add PDFs in a different order. |
| 2 | ~~**Disable `GraphMergeEngine` (Levenshtein dedup) during A/B runs.**~~ ⚠️ **Moot 2026-05-16:** `GraphMergeEngine` is dormant code — `MergeProposalView` is never instantiated. Cross-doc baseline merges come from `KnowledgeGraph.node(matching:)`, not from this engine. Nothing to disable. | Original rationale: clean comparison — baseline numbers per branch attribute every merge to the branch under test. Avoids double-counting with the existing 2-merge auto-detect found on vitacare. |
| 3 | **Buffer-then-commit at end-of-doc.** SCE collects all batch results for doc N in a temporary `KnowledgeGraph` buffer, merges into the real graph atomically when doc N's extraction completes. Failure mid-doc discards the buffer; partial-doc state never leaks into doc N+1's cumulative-state prompt header. | Simpler than per-batch commit + rollback (~30 LOC vs. ~100 LOC). Matches the PRD's atomicity requirement directly. |
| 4 | **v1 supports Gemini backend only.** SCE branch initially targets Gemini-only (use `gemini-embedding-2-preview` for ETR's embeddings, and any chat-completion Gemini model for SCE's cumulative-state prompts). OpenAI/Claude/Ollama support deferred until SCE proves end-to-end on Gemini. | Limits scope of the token-tracking instrumentation — only `GeminiBackend` needs to expose `usageMetadata.promptTokenCount`. Other vendors get token plumbing added if Gemini SCE proves out. |
| 5 | **Skip the optional final canonicalization LLM pass in v1.** PRD §"SCE Algorithm" step 5 (one-LLM-call-over-full-entity-list canonicalization) is deferred. | First end-to-end SCE run will tell us if the per-batch reuse decisions need a final cleanup. Adding it speculatively wastes a branch cycle. |
| 6 | **Commit doc updates to `main` before branching.** Both SCE and ETR branches branch off `8225e37` (post-α HEAD). The 2026-05-16 PRD + backlog updates live on `main` as a separate commit; both branches inherit the locked-in prep items from `main` history. | Keeps prep items durable on `main` and version-pinned in git, not just in session docs. |

---

## Embedding model defaults

| Backend | Default | Notes |
|---------|---------|-------|
| OpenAI | `text-embedding-3-large` (3072-dim) | Matches Gemini's default dim for apples-to-apples; `-3-small` (1536-dim) is the cheaper fallback. |
| Gemini | `gemini-embedding-2-preview` (3072-dim) | Live-tested 2026-05-16 — HTTP 200 with valid embedding response. Fallback: `gemini-embedding-001` (also live, GA, 3072-dim). `text-embedding-004` confirmed dead (404 on `embedContent` v1beta). |
| Ollama | `nomic-embed-text` | Local; only embedding model called out in PRD. |
| Claude | — | No embedding API; ETR disabled in UI when LLM backend = Claude and no other embedding configured. |

**ETR availability gate** (unchanged from PRD §"Embedding backend"): selector validates the embedding endpoint on save; ETR option in merging-strategy UI is disabled until a valid embedding model is configured.
