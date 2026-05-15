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

1. **Test corpus selection** — user picks 5-8 PDFs OR generates via `sample_pdfs/generate.py`. Capture choice in this doc.
2. **20+20 quality pairs** — written down before any branch is implemented.
3. **Embedding model defaults** for ETR — when implementing the settings selector, decide which embedding model is default for each backend.
