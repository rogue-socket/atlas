# Post-α-Migration Bug Report

**Created:** 2026-05-15
**Updated:** 2026-05-16 — B5, B4, B1, B2, B3 Stage 1, L2 fixed and **pushed to `origin/main`** (HEAD `8225e37`). User smoke-tested on the NexaPay 4-PDF corpus — B2/B3/B4/L2 confirmed working live; B5 covered by unit test only (no legacy graphs on disk to exercise live). Plus the Connections-panel UX gap that surfaced during smoke-test is also fixed (commit `f1ad018`).
**Context:** Runtime test of the 4-level knowledge-graph migration (commits `9ea83d6` → `3e69414`) against a 4-PDF test corpus (`harvest_hearth_*.pdf`). Bugs and limitations discovered both visually and via log inspection at `pdf_projects/temp_logs.txt`.

## Status snapshot (2026-05-16)

| ID | State | Notes |
|---|---|---|
| **B5** | ✅ Pushed | Custom `CodableRepresentation` decoder; `LossyEdge` wrapper. Test: `test_decode_skipsEdgesWithRetiredEdgeType_keepsNodesAndOtherEdges`. Commit `d600b83` + `56fe5c5`. **Not live-tested** (no legacy graphs on disk after the wipe); unit test covers the scenario. |
| **B4** | ✅ Live-verified | `encodeSubgraph(for:)` + `mergeSubgraph(from:scopedTo:)`; per-tab merge load. Legacy bloated files self-clean on load. 4 new tests. Commits `5d2e75f` + `388bdca` + `53803b5` + `1697a41` + `63df680`. **Live confirmed:** per-doc files saved with correctly-scoped counts (57/89, 38/52, 14/14, 55/78), not cumulative. |
| **B1** | ✅ Pushed | Carve-out removed; `activeNodeID` param dropped from `DensityManager.visibleNodes`. Inverted test in place. Commits `aa0605a` + `4f07652`. |
| **B2** | ✅ Live-verified | Notification carries `sourceDocumentURL`; doc-switch via `openDocument` + 150ms dispatch; toast on `.fileNotReadable`/`.invalidPDF`/`.tooManyTabs`. No unit tests (UI integration). Commits `53c1ad0` + `e832adb`. **Live confirmed:** source-link routing works across tabs. |
| **B3** | ✅ Stage 1 live-verified | `LevelBandSeeder` + cross-tab position preservation via `validNodeIDs`. 3 unit tests. Commits `072b0cd` + `d0368f6` + `a2f6b91` + `087ad4a`. **Live confirmed:** layout stays consistent across Doc/Chapter/Concept/Entity tab switches. Stage 2 (band-Y clamp during iteration) deferred. |
| **L2** | ✅ Live-verified | `ChapterEdgeAggregation.synthesize` after `appendDocumentSummary` in both pipelines. 5 unit tests. Commits `75a217c` + `8432c5e`. **Live confirmed:** 30 chapter-level aggregated edges across the 4-PDF NexaPay corpus (`[Pipeline] Synthesized 5/8/2/15 chapter-level aggregated edge(s)`). Renderer style differentiation deferred (open design question). |
| **B6** | ⏸ Deferred | Until Deep mode is next touched. |
| **L1** | ⏸ Deferred | Waits for SCE/ETR cross-doc branches. |
| **L3** | ⏸ Deferred | Waits for user evidence. |
| **N1** | ⏸ Superseded | Connections-panel UX gap (containment edges shown in panel but not on canvas) was fixed during smoke-test — see commit `f1ad018`. The audit's hairline-transitive-connector idea is no longer the lead mitigation; SCE/ETR will produce real cross-doc edges that obsolete N1. |

---

## Test Setup

- 4 PDFs in a single project (`harvest_hearth_company_and_people.pdf`, `harvest_hearth_customer_experience_and_operations.pdf`, `harvest_hearth_product_lines_and_pricing.pdf`, `harvest_hearth_sustainability_security_and_compliance.pdf`).
- All four had pre-α-migration graphs cached (with `subtopicOf` edges).
- User re-analyzed each PDF after relaunch.
- Observed both visually (Document/Chapter/Concept/Entity tabs) and via Console logs over the full session.

## Summary of Findings

| ID | Type | Severity | Effort | One-line description |
|---|---|---|---|---|
| **B1** | Bug | High | Trivial | activeNode/pinned carve-out bleeds across tab levels — Document tab shows 5 nodes when 4 are correct |
| **B2** | Bug | High | Medium | Source-link routes to wrong PDF: clicking a node sourced from PDF C while viewing PDF A jumps to PDF A's page |
| **B3** | Bug | High | Medium | Layout restructures on every tab switch — nodes appear "on wrong plane" and shuffle |
| **B4** | Bug | High | Small | Per-doc graph files save the entire project graph (4× bloat for a 4-PDF project) |
| **B5** | Bug | Medium | Small | Old graphs throw a decode error on `subtopicOf` and the load wipes in-memory state |
| **B6** | Bug | Low | Small | Deep pipeline Pass 1 fails when LLM returns facts missing `claim` or `type` fields |
| **L1** | Limitation | (defer) | — | No Document↔Document edges yet — comes from SCE/ETR cross-doc merging branches |
| **L2** | Limitation | Medium | Medium | No Chapter↔Chapter edges — would aggregate from cross-chapter concept relations |
| **L3** | Limitation | (defer) | — | No Entity↔Entity edges — LLM prompt doesn't extract them |
| **N1** | Note | — | — | Document-level "no edges" feel like a bug to users even though it's a known design wait |

---

## B1 — activeNode/pinned carve-out bleeds across tabs

**Observed:** Document tab sometimes shows 5 nodes when there are exactly 4 analyzed PDFs in the project. Switching tabs sometimes makes a node "appear on the wrong plane" or vanish — usually correlated with scrolling the PDF.

**Root cause:** `DensityManager.visibleNodes` in `pdf_app1/pdf_app1/Atlas/Renderer/DensityManager.swift` includes a carve-out clause:

```swift
return graph.allNodes.filter { node in
    if node.isPinned || node.id == activeNodeID { return true }
    return node.level == target
}
```

`activeNodeID` is set by `BidirectionalSyncManager` when the PDF scrolls — typically points at a `.concept` or `.entity` level node (whichever the user is reading on the current page). Same for `isPinned`. Both bypass the level filter, so when the user is at the Document tab but the PDF has scrolled to a concept node's source page, that *concept* node also appears at the Document level — extra "5th" node alongside the 4 Document nodes.

The vanishing/reappearing is the same mechanism: as the user scrolls, `activeNodeID` changes, and the carve-out flips which off-level node leaks into the view. Each flip is a visible-set change → FDL recomputes → layout shuffles.

**Fix shape:** Drop the carve-out entirely. Each tab strictly shows its level. The renderer's existing "highlight" / "selected" / "active" overlay can still call attention to the active node *if it happens to be at the current level*; off-level active nodes simply aren't visible at the current zoom.

```swift
func visibleNodes(from graph, zoomLevel, activeNodeID) -> [ConceptNode] {
    let target = nodeLevel(for: zoomLevel)
    return graph.allNodes.filter { $0.level == target }
}
```

Affected files: `pdf_app1/pdf_app1/Atlas/Renderer/DensityManager.swift` only.

**Test coverage:** `FourLevelGraphTests.test_densityManager_pinnedNode_visibleAtAllLevels` *passes* today but encodes the wrong behavior. Replace with negative assertion: pinned nodes are NOT visible at non-matching levels.

---

## B2 — Source-link navigation routes to the wrong PDF

**Observed:** Clicking a node in the map (any level) navigates to a page in the currently-visible PDF, not in the source PDF where the node was extracted. If node X is sourced from `PDF C, page 3` and the user is currently viewing `PDF A`, the click takes them to `PDF A, page 3` (or nothing if page 3 doesn't exist in A). No pulse-highlight either.

**Root cause:** `KnowledgeMapView.onNavigateToPage` in `pdf_app1/pdf_app1/Atlas/Renderer/KnowledgeMapView.swift` (around line 992-1000 in `MultiDocumentView`) posts a `.navigateToPage` notification carrying only `pageIndex` (plus optional `boundingBox` / `textSnippet`):

```swift
NotificationCenter.default.post(
    name: .navigateToPage,
    object: pageIndex,
    userInfo: info.isEmpty ? nil : info
)
```

The notification handler in the active `PDFViewerView` routes it to whichever document `PDFView` is currently showing — there's no source-URL routing layer. This was acceptable when a graph was per-document and the in-memory graph only ever contained nodes from the active PDF. With the 4-level model the in-memory graph naturally contains nodes from every PDF in the project (Document nodes for all 4 PDFs always coexist) — the routing assumption breaks.

Compounding: the pulse highlight is wired via `HighlightSyncBridge` which requires the active `PDFDocument` to be the document the annotation belongs to. If we don't switch documents first, the highlight has nothing to attach to.

**Fix shape:**

1. Extend the notification payload to include `sourceDocumentURL: URL`. Read it from `node.sourceAnchors.first?.documentURL` (or a more specific match if multiple anchors).
2. In the notification handler:
   - If `sourceDocumentURL == documentManager.selectedDocument?.url` → just scroll as today.
   - Else → call `documentManager.selectDocument(url: sourceURL)` first (or open the doc if it's not currently open), then schedule the page-scroll on the next runloop tick (after the doc switch settles).
3. After the document switch, the existing `HighlightSyncBridge` pulse should fire correctly because the active document now matches the annotation's document.

Affected files: `MultiDocumentView.swift` (onNavigateToPage closure + handler), `DocumentManager.swift` (may need a `selectOrOpen(url:)` convenience).

**Edge case:** the source PDF isn't currently in the project (user removed it). Either degrade gracefully (toast "Source PDF not in this project") or treat it as a no-op. Recommend toast.

---

## B3 — Layout restructures on every tab switch

**Observed:** Switching between Document/Chapter/Concept/Entity tabs reshuffles node positions. Nodes briefly appear in unexpected places. The graph doesn't feel stable.

**Root cause:** Each tab change produces a different visible-node set → `ForceDirectedLayout.computeLayout` runs fresh on that set → output positions are different each time. There's no per-level position cache, and the layout has no awareness of which `NodeLevel` it's laying out.

The α-migration deleted `HierarchyForest` and `TreeLayoutSeeder` (which used `hierarchyLevel` for band seeding) without replacement. Phase 1I of the migration plan was "band-by-NodeLevel seeding" — explicitly deferred. This observation confirms it can't stay deferred.

**Fix shape (band-by-NodeLevel seeding):**

The 4 levels correspond to 4 horizontal bands in the canvas:
- `.document` → top band (y ~ canvas_height × 0.15)
- `.chapter`  → upper-middle (y ~ canvas_height × 0.40)
- `.concept`  → lower-middle (y ~ canvas_height × 0.65)
- `.entity`   → bottom band (y ~ canvas_height × 0.85)

When at a single-tab view, only one band of nodes is visible, but the band Y is stable across tab switches. Within a band, FDL still applies repulsion + attraction for X spread.

Within a band, sub-sort by:
- For Concept tab: cluster by chapter (use `containsConcept` incoming edges).
- For Entity tab: cluster by parent concept (`parentConceptByEntity`).
- For Document/Chapter tabs: alphabetical or by extraction order is fine — there are few.

**Alternative interim fix:** position cache per `NodeLevel`. Keep a `[NodeLevel: [UUID: CGPoint]]` map; when switching tabs, seed FDL with the cached positions for that level. First visit computes fresh; subsequent visits restore. Cheaper than band-seeding rewrite but doesn't solve "feels visually random the first time you visit each tab."

Recommend doing the band-by-NodeLevel rewrite — it's the right shape, matches the user's mental model of folds, and is stable.

Affected files: `Atlas/Renderer/ForceDirectedLayout.swift`, possibly a new `Atlas/Renderer/LevelBandSeeder.swift` helper file.

---

## B4 — Per-doc graph files contain the entire project graph

**Observed (logs):** As each PDF was analyzed in sequence, the saved file size for each per-doc graph grew cumulatively rather than reflecting just that doc's contribution:

```
[GraphStore] Saved graph for harvest_hearth_company_and_people.pdf: 47 nodes, 69 edges (90522 bytes)
[GraphStore] Saved graph for harvest_hearth_customer_experience_and_operations.pdf: 72 nodes, 114 edges (140618 bytes)
[GraphStore] Saved graph for harvest_hearth_product_lines_and_pricing.pdf: 113 nodes, 196 edges (230094 bytes)
[GraphStore] Saved graph for harvest_hearth_sustainability_security_and_compliance.pdf: 156 nodes, 266 edges (317038 bytes)
```

Doc 4's file contains 156 nodes — the union of all 4 PDFs' nodes. By the end, every per-doc file would also contain all 156 nodes (since each subsequent save sees the accumulated in-memory graph).

**Root cause:** `GraphStore.scheduleSave(_ graph:for:)` encodes the entire in-memory `KnowledgeGraph` (via `graph.encode()`) into the file keyed by `documentURL`. Under the pre-migration architecture the in-memory graph was one-doc-at-a-time (the `decode` clearing on tab switch reinforced this), so saving the whole graph and saving just-this-doc's-nodes happened to be equivalent.

Under the 4-level model, the in-memory graph naturally contains every analyzed PDF's nodes (Document nodes for all of them coexist by design). The "save the whole graph" behavior now denormalizes every file.

**Consequences:**

1. **Storage bloat.** For an N-PDF project, each per-doc file is ~N× larger than it needs to be.
2. **Stale references.** If the user removes a PDF from the project, every other PDF's saved graph still contains references to the removed doc's nodes. They become orphans.
3. **Misleading `alreadyHasNodes` short-circuit.** `MultiDocumentView.loadGraphIfNeeded` checks `knowledgeGraph.allNodes.contains { ... sourceAnchors.contains { $0.documentURL == documentURL } }`. After the first doc loads (bringing all 4 docs' nodes into memory), every subsequent tab switch's `alreadyHasNodes` is true, so the file isn't reloaded — but for the wrong reason.
4. **Cross-doc merging foundation is wrong.** When SCE/ETR branches start creating shared multi-anchor entities (one node with anchors in 2+ docs), the multi-anchor design assumes a node is serialized only into files for its anchored docs. Today everything is serialized into every file.

**Fix shape:**

Two layers of change:

**(a) Filter at save time.** In `GraphStore.scheduleSave` (or a new helper `encodeSubgraph(for: URL)` on `KnowledgeGraph`):

```swift
func encodeSubgraph(for documentURL: URL) throws -> Data {
    let scopedNodes = allNodes.filter { node in
        node.sourceAnchors.contains { $0.documentURL == documentURL }
    }
    let scopedNodeIDs = Set(scopedNodes.map(\.id))
    let scopedEdges = allEdges.filter { edge in
        scopedNodeIDs.contains(edge.sourceNodeID) && scopedNodeIDs.contains(edge.targetNodeID)
    }
    // ... encode CodableRepresentation with scopedNodes + scopedEdges
}
```

**(b) Fix `MultiDocumentView.loadGraphIfNeeded`.** The `alreadyHasNodes` short-circuit is no longer correct under multi-doc memory. Two options:
- (i) Switch to loading at the project level: when a project is opened, load all per-doc graphs into one in-memory graph (using `GraphStore.loadProjectWideGraph(documentURLs:)` we added in `3e69414`); per-tab navigation just changes which `documentURL` is active, no per-tab reload.
- (ii) Stay per-tab: clear the graph on tab switch and reload the active doc's file. Cheaper memory but breaks the Document tab (can't show all 4 PDFs).

Recommend (i). Aligns with the user's mental model ("all my analyzed docs are part of one project graph"). The Document tab needs this to ever show 4 nodes.

Affected files: `Atlas/Persistence/GraphStore.swift`, `Atlas/Models/KnowledgeGraph.swift` (new `encodeSubgraph` method), `MultiDocumentView.swift` (loadGraphIfNeeded rewrite).

---

## B5 — Old graphs fail to decode, wiping the in-memory state

**Observed (logs):** On first relaunch after the α-migration, every previously-extracted PDF threw a decode error:

```
[MultiDocView] loadGraphIfNeeded: decode failed for harvest_hearth_company_and_people.pdf:
Swift.DecodingError.dataCorrupted(
  Swift.DecodingError.Context(
    codingPath: [CodingKeys(stringValue: "edges", intValue: nil), _CodingKey(stringValue: "Index 16", intValue: 16), CodingKeys(stringValue: "type", intValue: nil)],
    debugDescription: "Cannot initialize EdgeType from invalid String value subtopicOf"
  )
)
```

The decode throws on the first `subtopicOf` edge case it encounters. The catch block in `MultiDocumentView.loadGraphIfNeeded` calls `knowledgeGraph.clear()` — wiping any state. The user has to re-analyze every PDF to get a usable graph back.

**Per the design doc** (decision #2: "No backwards compatibility"), this *is* the intended behavior. But the user-experience cost is severe — 4 PDFs to re-extract before the app is usable again, with no warning that this was going to happen. Logging is good (the warning is visible in Console), but it's not surfaced in-app.

**Fix shape (preserve concepts/entities, drop only the unknown edges):**

Currently the failure point is the `try c.decode(EdgeType.self, forKey: .type)` in `GraphEdge`'s synthesized Codable. Wrap it with a recovery layer that skips edges whose `type` doesn't match the current `EdgeType` enum:

```swift
struct CodableRepresentation: Codable {
    let nodes: [ConceptNode]
    let edges: [GraphEdge]
    let documentProcessingState: [String: ProcessingState]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.nodes = try c.decode([ConceptNode].self, forKey: .nodes)
        self.documentProcessingState = try c.decodeIfPresent([String: ProcessingState].self, forKey: .documentProcessingState) ?? [:]

        // Decode edges lossily: skip individual edges whose `type` is
        // unknown (e.g. retired enum cases like subtopicOf) rather than
        // failing the whole graph load.
        var edgeContainer = try c.nestedUnkeyedContainer(forKey: .edges)
        var collected: [GraphEdge] = []
        var skipped = 0
        while !edgeContainer.isAtEnd {
            if let edge = try? edgeContainer.decode(GraphEdge.self) {
                collected.append(edge)
            } else {
                _ = try? edgeContainer.decode(AnyCodable.self)  // skip
                skipped += 1
            }
        }
        if skipped > 0 {
            log.warning("[GraphStore] Skipped \(skipped) edge(s) with unknown types during decode")
        }
        self.edges = collected
    }
}
```

Same treatment for nodes if any node fields have been removed (under the migration, ConceptNode lost 4 fields but they were `decodeIfPresent` → fine; the new required `level` field has no migration path for old graphs that didn't have it — they'd throw on `try c.decode(NodeLevel.self, forKey: .level)`).

Actually checking: pre-migration ConceptNode also had `level` (it was `.concept` or `.entity`). New `NodeLevel` is a superset — `.concept` and `.entity` still decode fine. So nodes are safe; only edges need the lossy path.

Affected files: `Atlas/Models/KnowledgeGraph.swift` (custom decoder for `CodableRepresentation`).

---

## B6 — Deep pipeline Pass 1 fails on partial LLM responses

**Observed (logs):**

```
[Deep] Pass 1 error for chunk: Swift.DecodingError.keyNotFound(
  CodingKeys(stringValue: "claim", intValue: nil),
  Swift.DecodingError.Context(
    codingPath: [CodingKeys(stringValue: "facts", intValue: nil), _CodingKey(stringValue: "Index 21", intValue: 21)],
    debugDescription: "No value associated with key 'claim'"
  )
)
```

And:

```
debugDescription: "No value associated with key 'type'"
```

In both cases the LLM returned a facts array where item 21 (or 22) was missing a required field. The strict `RawFact` decoder fails on the whole chunk, losing every fact in it — not just the malformed one.

**Root cause:** `RawFact` declares `claim` and `type` as non-optional `String`. One malformed entry trips the whole array decode.

**Fix shape:**

Either:
1. Make fields optional and filter post-decode (`facts.compactMap { $0.claim != nil ? $0 : nil }`), or
2. Wrap the array decode in a lossy decoder that skips bad entries (same pattern as B5).

Option 2 is consistent. Option 1 is simpler.

Lower priority: only matters in Deep mode and the user is likely on Fast.

Affected files: `Atlas/AI/AtlasModelProtocol.swift` (RawFact decode), `Atlas/AI/DeepExtractionPipeline.swift` (call site if option 1).

---

## L1 — No Document↔Document edges (limitation, not bug)

**Observed:** Document tab shows 4 isolated nodes, no connecting edges.

**Why:** Today's data model has no extraction step that produces Document-to-Document relationships. Cross-doc connections come from the SCE/ETR cross-doc-merging branches (per the design doc). Until one lands, Document tab will show isolated nodes.

**No fix here.** This is expected. SCE makes shared entities → entities anchor to multiple docs → at Document level, two docs sharing entities can be connected via aggregated edges.

---

## L2 — No Chapter↔Chapter edges (worth doing)

**Observed:** Chapter tab shows ~26 isolated chapter nodes (across the 4 PDFs).

**Why:** No extraction step produces Chapter-to-Chapter relationships. The data exists to synthesize them: concepts have `dependsOn` / `sameTopic` / `partOf` edges, and concepts are linked to chapters via `containsConcept`. If a concept in Chapter A `dependsOn` a concept in Chapter B, that's evidence for an aggregated Chapter A → Chapter B `dependsOn` edge.

**Fix shape (Chapter-level edge synthesis):**

After concept extraction, scan every cross-chapter concept-edge and aggregate by `(chapterPair, edgeType)`:

```swift
// For each (sourceChapter, targetChapter, edgeType) triple,
// count the underlying concept edges. If count >= threshold (e.g. 1),
// emit a chapter-level edge with confidence proportional to count.

for conceptEdge in graph.allEdges where !conceptEdge.type.isContainment {
    guard let sourceConcept = graph.node(for: conceptEdge.sourceNodeID),
          let targetConcept = graph.node(for: conceptEdge.targetNodeID),
          sourceConcept.level == .concept, targetConcept.level == .concept
    else { continue }
    let sourceChapters = graph.parents(of: sourceConcept.id, edgeType: .containsConcept)
    let targetChapters = graph.parents(of: targetConcept.id, edgeType: .containsConcept)
    for sCh in sourceChapters {
        for tCh in targetChapters where sCh.id != tCh.id {
            // Add or strengthen edge sCh → tCh of type conceptEdge.type
        }
    }
}
```

Same mechanism could work for Entity-level aggregation (L3) but is lower priority because entities are dense and edges would be noisy.

**Visual treatment:** Aggregated edges should render slightly differently than LLM-extracted ones (lighter weight, no linking phrase, or with a count badge "3 shared concepts"). Open design question.

Affected files: new `Atlas/AI/ChapterEdgeAggregation.swift` (or extend `ChapterExtraction`), with a call site at the end of `ExtractionPipeline.processFullDocument`.

---

## L3 — No Entity↔Entity edges (defer)

**Observed:** Entity tab shows colored-but-isolated entity nodes.

**Why:** The LLM prompt asks for concept-level edges only; entities are nested under concepts as `containsEntity` children. No entity-to-entity relationships extracted.

**Defer.** Could be added via entity-level edge aggregation (similar to L2) or by extending the LLM prompt — but entity counts are higher (often 100+) and inter-entity edges would clutter the view. Wait for user evidence before committing.

---

## N1 — User-perception note: "no edges" feels like a bug even when it's a limitation

**Observation:** The user reported "no relations between nodes" at Document and Entity tabs as bugs, alongside the real bugs. Even though Document-tab isolation is a known design wait (L1), the user sees it as broken.

**Mitigation options:**

- Until cross-doc edges exist, the Document tab could surface "shared content" through *implicit* visualization: a faint hairline connector between any two Document nodes whose contained Chapters share at least one Concept (a transitive read). Not a real edge in the graph, just renderer-side.
- Or display a small badge per Document node showing total connection count to other docs (zero today, will grow once SCE/ETR lands).

Otherwise, surface a one-line empty-state hint at the Document tab: *"No cross-document connections yet. Connections appear when documents share concepts or entities (analyze more PDFs in this project)."*

Affected files: `Atlas/Renderer/MapCanvasRenderer.swift` for hairline rendering, or `KnowledgeMapView.swift` for the empty-state hint.

---

## Suggested fix sequence

Ordered by user-impact-per-effort, with consideration for what unlocks downstream work:

1. **B5** (graceful decode) — protects users with legacy graphs from data wipe. Single file change. ~30 min.
2. **B4** (per-doc save filtering) — correctness foundation for multi-doc storage. Touches `KnowledgeGraph.encodeSubgraph` + `GraphStore.scheduleSave` + `MultiDocumentView.loadGraphIfNeeded`. ~2 hours.
3. **B1** (drop carve-out) — trivial; kills the "5 instead of 4" mystery. ~10 min including replacing the now-wrong test.
4. **B2** (source-aware navigation) — biggest user-visible UX fix. Touches the notification payload + handler + DocumentManager. ~2 hours.
5. **B3** (band-by-NodeLevel layout) — most complex; biggest visual quality improvement. New seeder + FDL changes. ~3 hours.
6. **L2** (chapter-edge synthesis) — feature, lifts Chapter tab from "isolated dots." ~1 hour.
7. **B6** (Deep Pass 1 partial-response tolerance) — defer until next time Deep is touched.
8. **N1** (empty-state hint at Document tab) — copy/UI nicety, low priority.

Defer: **L1**, **L3** indefinitely (wait for SCE/ETR / user evidence respectively).

---

## Risks and considerations

**B4's project-wide load (option (i)) changes the in-memory model.** Today a fresh app launch only loads the first-tab's graph; subsequent tabs are loaded on demand. Project-wide load means loading all per-doc files at project-open time — slower startup for large projects, but predictable. For 4-PDF projects this is fine; for 50+ it may need lazy / paginated loading. Worth measuring once we have a stress corpus.

**B3's band-by-NodeLevel layout interacts with the existing `resolveClusterOverlaps` pass.** Cluster-overlap resolution assumes concepts + their entities form a visual cluster; under banding, entities and concepts live in different bands and the cluster rectangle would span both. Either:
- Skip cluster-overlap resolution under banding, or
- Make cluster bounds aware of band boundaries (don't push a cluster across bands).

**B2's "switch tabs before scrolling" timing**. SwiftUI document-switch + `setDocumentURL` propagation has its own settling time. The scroll may need a small async delay or a `.onChange(of: selectedDocumentID)` listener to know when it's safe to scroll. Watch for race conditions.

**B5's lossy decode might mask real corruption**. Today an unparseable graph file fails loudly; the lossy path will succeed quietly even when the file is genuinely corrupted. Mitigation: log loudly (already in the proposed code), and add a one-time "Some edges were skipped from your graph — re-analyze to refresh" notification surfaced in-app when skipped > 0.

---

## Out of scope for this report

- LLM prompt quality (concept extraction quality is "fine" per user; no investigation needed).
- Deep pipeline beyond the Pass 1 fix (B6).
- Cross-doc merging algorithm itself (lives on SCE/ETR branches).
- UI polish on individual node rendering (sizing, color, animation — current is "fine").
- Performance under load (no slowness reported yet).
