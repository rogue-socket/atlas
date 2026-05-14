# Atlas Simplify Survey — 2026-05-14

Read-only review of `Atlas/` source (57 Swift files, ~13.4k lines) across three lenses: code reuse, code quality, efficiency. Findings prioritized by impact.

## Status

| Tier | Finding | Status | Commit | Notes |
|---|---|---|---|---|
| 1 | #1 AI backend duplication | ✅ done | `058936e` | Folded with 5-drift reconciliation per [`2026-05-14_backend-drift-decisions.md`](./2026-05-14_backend-drift-decisions.md). Net -202 lines across `Atlas/AI/Backends/`. |
| 1 | #2 O(n²) label lookups | ✅ done | `be9814b` | Added `KnowledgeGraph.labelIndex` + `node(matching:)`; locked `nodes`/`edges` to `private(set)`; routed `merge(from:)` through silent `insert`. 11 call sites converted. |
| 1 | #3 Renderer per-frame allocations | deferred — not profiled | `fa9f768` (reverted `22b770e`) | Audit's "per frame" framing was misleading: Canvas re-runs on `@Observable` invalidation, not a frame timer. Only `graph.entities(for:)` in the concept loop was actually quadratic; the other three flagged sites were O(N) singletons. Defer until a profile shows the renderer in a hotspot. |
| 1 | #4 Sequential LLM batches | deferred — accuracy over speed | — | All three optimization paths trade some accuracy for wall-time. Decision: keep sequential. Option (a) — move `proposeEdges` out of per-batch loop into one end-of-extraction call — retained as future-scope if extraction wall-time becomes a complaint. |
| 1 | #5 Split `PDFViewerView.swift` | ✅ done | `a01e05c` | Bridge + outline panel + annotation list panel extracted to dedicated files. `PDFViewerView.swift` 1549 → 734 lines. Two tiny types (`TextAnnotationDialog` 35 lines, `PDFThumbnailViewRepresentable` 19 lines) intentionally left in place. |
| 2 | #6 Stringly-typed PDF annotation kinds | ✅ done | `940e414` | New `PDFAnnotation+Kind.swift` shim normalizes PDFKit's read/write slash asymmetry. 5 read sites + `typeIcon` switch converted to typed `PDFAnnotationSubtype` constants. |
| 2 | #7 `Notification.Name` literals duplicated | ✅ done | `6447ba9` | Typed extension in `Constants.swift`; ~20 sites converted. Surfaced `OpenDocuments` as dead code (zero posters anywhere — no Swift, no plist, no AppDelegate). Observer deleted. |
| 2 | #8 `findSourceAnchor` per-page decode | open | — | Held — wider blast radius; would benefit from profile data, like Tier 1 #3. |
| 2 | #9 `GraphStore.scheduleSave` race + retention | ✅ done | `42fe76c` | Encode moved to caller; work item now captures `Data` payload instead of `KnowledgeGraph` reference. Eliminates the concurrent dict read/write on `nodes`/`edges` between debounced save (background) and ongoing extraction (main). Retention concern resolved as side effect. |
| 2 | #10 TOCTOU + sync I/O on document open | won't-fix | — | The `fileExists` precheck is not redundant — it differentiates "no saved graph yet" (info log) from "load failed" (error log), which matters during debugging. The TOCTOU window is benign (no concurrent writers in this app; same nil-return outcome either way). Sync I/O is fine in practice — KB-MB files, local disk, once per document-open, not in a hot loop. The audit's framing ignored why the precheck exists. |
| 2 | #11 Levenshtein + dup similarity util | open | — | Held — wider blast radius; profile-first. |
| 2 | #12 `.pdf` strip via `replacingOccurrences` | ✅ done | `ae78939` | `URL.deletingPathExtension()` — fixes case-insensitive (`.PDF`) and double-extension (`v1.pdf.pdf`) edge cases. |
| 2 | #13 `resolveOverlaps` O(n²) | open | — | Renderer perf, profile-first (same reasoning as Tier 1 #3). |
| 2 | #14 force-unwraps in extraction | ✅ done | `96924d4` | `guard let` over `if nil { continue }` + `!`. No behavior change. |
| 2 | #15 UserDefaults raw keys | ✅ done | `5e1bf32` | 3 keys consolidated into existing `AppConstants` UserDefaults block. Audit's `PDFSearchManager` claim was wrong — that file already encapsulates its key. |
| 3 | #24 `addNode` `.info` log per node | partial | `be9814b` | `merge(from:)` is now silent (routed through a private `insert(_:)`). Extraction/decode paths still emit `.info` per node. Demoting globally was not approved this session. |
| 3 | All other Tier-3 items | open | — | |

Also closed as side effects of #2 (not in this survey but flagged by an upstream agent before consolidation): `KnowledgeGraph.merge(from:)` previously bypassed `addNode` and wrote to `nodes[id]` directly — the same `be9814b` commit fixes that by routing through the new private `insert(_:)` helper.

Sign-off rationale for the work that landed lives in [`2026-05-14_backend-drift-decisions.md`](./2026-05-14_backend-drift-decisions.md). The shape of the process used today is documented in [`WORKFLOW.md`](./WORKFLOW.md).

## Tier 1 — Highest impact

### 1. AI backend duplication (~300-400 lines removable) — ✅ done (`058936e`)
**Files:** `Atlas/AI/Backends/ClaudeBackend.swift:31-99`, `OpenAIBackend.swift:37-104`, `GeminiBackend.swift:35-94`

Six public methods (`extractConcepts`, `proposeEdges`, `summarizeConcept`, `answerQuestion`, `proposeMerges`, `generateRawResponse`) plus three parse helpers (`parseExtractionResponse`, `parseEdgesResponse`, `parseAnswerResponse`) plus the `extractJSON` wrapper are near-byte-identical across all three backends, varying only by log tag and HTTP transport call. The parse helpers have already drifted: Claude's `parseExtractionResponse` has retry-via-`ExtractionResponse` that OpenAI lacks; `parseAnswerResponse` error-handling differs between Claude (throws) and OpenAI/Gemini (swallow).

**Fix:** Extract a `BaseLLMBackend` (class or protocol extension) implementing everything except `func send(prompt:) async throws -> String`. Drop the `extractJSON` forwarders — call `JSONRepair.cleanAndRepair` directly (already done at `DeepExtractionPipeline.swift:46,75,171`).

**As landed:** Introduced `LLMBackend` protocol with `var logTag: String` + `func transport(prompt:)` as the only requirements; default implementations of all six public methods live on a protocol extension; new `LLMResponseParser` enum holds the four unified parsers. Each concrete backend now only carries vendor identity + the transport body. Step-1 drift reconciliation (5 numbered decisions, all signed off in [`2026-05-14_backend-drift-decisions.md`](./2026-05-14_backend-drift-decisions.md)) was folded into the same commit since the intermediate file shape no longer exists in the working tree.

### 2. O(n²) label lookups across extraction hot path — ✅ done (`be9814b`)
**Files:** `Atlas/AI/ExtractionPipeline.swift:86,121,304,335,373,415,424-425,431,606`; `DeepExtractionPipeline.swift:96,128,181-182`; `Atlas/Persistence/GraphMergeEngine.swift:144-145`

~10 sites do `graph.allNodes.first { $0.label.lowercased() == X.lowercased() }` inside per-concept and per-batch loops. Each is O(N); cumulative cost grows quadratically with graph size during extraction.

**Fix:** Add `KnowledgeGraph.node(matching label: String) -> ConceptNode?` backed by a `[String: UUID]` lowercased-label index, updated on add/update/remove.

**As landed:** Reframed during analysis — the headline value is *dedup* (one place to change the lowercased-equality rule) with perf as a side effect (the string-compare cost is noise next to LLM network calls). Added `labelIndex: [String: UUID]` + private `insert(_:)` to `KnowledgeGraph`; new public `node(matching:)` for O(1) lookup. Locked `nodes`/`edges` to `private(set)` after `rg`-verifying zero external writes existed. `merge(from:)` now routes through silent `insert` (no per-node log spam). The 11 lookup call sites converted; the 3 `allNodes.map { $0.label }` sites (label list for LLM prompt context, not a lookup) intentionally left alone. Sub-decisions and their rationale captured in [`WORKFLOW.md`](./WORKFLOW.md) as a worked example.

### 3. Renderer rebuilds `allNodes` array on every frame — deferred until profiled (`fa9f768` reverted `22b770e`)
**File:** `Atlas/Renderer/MapCanvasRenderer.swift:36,73,112,118`

Every Canvas redraw calls `graph.allNodes` (3 sites) and `graph.allEdges` (1 site) — each rebuilds `Array(nodes.values)` on `KnowledgeGraph`. `drawGroupBackgrounds` then filters to concept nodes and calls `graph.entities(for:)` per concept (a full `allNodes.filter`) → O(C·N) per frame.

**Fix:** Cache `conceptNodes` + an `entitiesByParent` map (already done for badges at line 117) once per body invocation; pass into the three draw passes.

**Deferred:** Attempted in `fa9f768` (hoisted four allocations into the Canvas closure, threaded through three helpers as new params), then reverted in `22b770e`. On reread, three of the four flagged sites (`allNodes` at lines 73, 112, 118) are O(N) singletons per redraw — cheap and not compounding. Only `graph.entities(for:)` inside `drawGroupBackgrounds`'s concept loop was actually C × O(N). And Canvas does not redraw on a frame timer — it re-runs on `@Observable` invalidation — so the "per frame" framing inflated the picture. Without a profile showing the renderer in a hotspot, optimizing at the call site (growing three helper signatures by six params total) traded locality for an unmeasured win. If a real perf issue surfaces here later, the right shape is at the data layer: add an `entitiesByParent` index to `KnowledgeGraph` analogous to `be9814b`'s `labelIndex`, leaving the renderer untouched.

### 4. Sequential batched LLM calls dominate wall-time — deferred (accuracy over speed)
**File:** `Atlas/AI/ExtractionPipeline.swift:93-134`

The 5-page-batch `while` loop awaits each LLM call before starting the next. Batches are network-bound and largely independent (anchor lookup reads disjoint pages).

**Fix:** Wrap inner loop in `TaskGroup` with bounded concurrency (K=3); merge into the graph on the main actor. Edge proposal (step 6) stays serial.

**Deferred:** Foundational walkthrough on 2026-05-14 surfaced three optimization paths, each with an accuracy cost. User declined all three; current sequential behavior preserved.

The audit fix as written is incomplete on its own: today each `processBatch` makes **two** LLM calls — concept extraction (Step 4) and per-batch `proposeEdges` (Step 6) — so 50-page extraction is 10 × 2 = 20 calls, not 10. Just wrapping the loop in `TaskGroup` parallelizes both, but doesn't reduce call count.

Three options considered:

- **(a) Hoist `proposeEdges` out of the per-batch loop into a single call at end.** 20 → 11 calls. ~2× wall-time win, no concurrency. Cost: the single end-of-extraction `proposeEdges` call gets one batch's contextText (or a representative slice), not the per-batch context that currently informs each invocation. Edge meaning quality may degrade. Net trade: bigger graph view, narrower contextual grounding.
- **(b) `TaskGroup` K=3 concurrency.** Parallelizes the LLM-call wait. Costs: the per-batch prompt's `Already extracted concepts: …` dedup signal goes stale within a parallel wave — the LLM has no way to know what other in-flight batches are emitting, so more lexical/semantic duplicate concepts. The post-LLM `graph.node(matching:)` check catches lexical dupes (case-insensitive label match) but not semantic ones ("Random Forests" vs "Random Forest Classifier"). Also: Ollama users serialize on local GPU/CPU — concurrent requests queue or OOM, making this strictly worse for the local-AI path unless a per-backend max-concurrency hint is added to `AtlasModel`.
- **(c) Raise `batchSize` from 5 to 10 or 15.** One-line tuning change. Fewer batches → fewer total calls. Cost: unknown empirically — the existing `batchSize = 5` is unannotated, likely tuned for concept-extraction quality. Longer prompts may degrade the LLM's instruction-following or cause it to skim and miss concepts. Requires A/B output comparison on real PDFs to know.

User's reasoning (verbatim): "feels like we're losing on accuracy." Decision: status quo. Option (a) retained as future-scope to revisit if wall-time becomes a complaint that outweighs the edge-quality cost. Options (b) and (c) parked.

### 5. `PDFViewerView.swift` bundles ~5 unrelated sub-views in 1549 lines — ✅ done (`a01e05c`)
**File:** `PDFViewerView.swift`

Contains: main `PDFViewerView`, `PDFViewRepresentable` + Coordinator (683-1271, ~600 lines), `TextAnnotationDialog`, `PDFThumbnailViewRepresentable`, `PDFOutlinePanel` + `OutlineItemView`, `AnnotationListPanel` + `AnnotationRowView` (1326-1549).

**Fix:** Move panels and `PDFViewRepresentable`/Coordinator to their own files.

**As landed:** Pure file shuffle, no behavior change. Three new files: `PDFViewRepresentable.swift` (601 lines — the bridge + its nested `Coordinator`, kept together since they're one cohesive unit), `Atlas/UI/PDFOutlinePanel.swift` (98 lines — outline panel + recursive row), `Atlas/UI/AnnotationListPanel.swift` (146 lines — list panel + row). `PDFViewerView.swift` shrinks from 1549 to 734 lines and retains `BookmarkManager` (only used internally), `HighlightingPDFView` (referenced from `MultiDocumentView`/`PDFToolbarBridge` so accessible same-module), `PDFViewerView` itself, plus the two tiny adjacent types (`TextAnnotationDialog` 35 lines, `PDFThumbnailViewRepresentable` 19 lines) — too small to earn their own files. Project uses `PBXFileSystemSynchronizedRootGroup` so the new files auto-discover; no `.xcodeproj` edits needed. Build green. **Live smoke-test still recommended** — there's no test coverage on `PDFViewerView`, so a runtime regression (e.g., the known `updateNSView` cursor workaround at the original L768-802, now in the bridge file) wouldn't be caught by the build alone.

## Tier 2 — Cheap consolidations & correctness

### 6. Stringly-typed PDF annotation kinds
`PDFViewerView.swift:900,906,924,952,1486,1502-1510` — repeated `annotation.type == "Highlight"/"FreeText"/...` plus a 10-case string switch in `AnnotationRowView.typeIcon`. Introduce `enum AtlasAnnotationKind: String`.

### 7. `Notification.Name` string literals duplicated across 4 files
`MultiDocumentView.swift:32,155,162,326,352,357,369,374,608,718,849,954,1293`; `PDFViewerApp.swift:48,53,70,75,80`; `PDFViewerView.swift:254`. Names: `OpenNewDocument`, `NavigateToPage`, `CloseOtherTabs`, `SetPaneMode`. Add `extension Notification.Name`.

### 8. `findSourceAnchor` re-decodes every PDF page per concept
`ExtractionPipeline.swift:533-545` — loops `0..<document.pageCount` calling `page.string` (PDFKit decodes per call) and `.lowercased().contains(prefix)` for each unmatched concept. Cache `pageTexts: [Int: String]` for the batch; short-circuit by searching the batch's page range first.

### 9. `GraphStore.scheduleSave` race + strong-graph retention — ✅ done (`42fe76c`)
`Atlas/Persistence/GraphStore.swift:146-156` — debounced work item captures `graph` strongly (only `self` is weak); `save(_:)` runs on `.utility` queue while main-actor mutates `nodes`/`edges` during `graph.encode()`. Snapshot/encode on caller; debounce only the file write.

**As landed:** Reframed during analysis. The race was real (Swift `Dictionary` concurrent read+write is undefined behavior — `KnowledgeGraph` is `@Observable nonisolated class`, chosen for the deinit-crash workaround in `c8cad91`, not thread-safety). Hasn't crashed yet because windows are tight (encode is fast, batches are slow ~10s apart) but could surface with fast local Ollama. The retention concern was technically true but harmless — `DispatchWorkItem.cancel()` doesn't drop already-queued items so cancelled items hold graph refs for up to 1s, but the graph is a class so all refs point to the same instance; no real leak. Fix: encode synchronously on caller, capture `Data` payload (value type) into the work item. Retention falls out as a bonus since the work item no longer references the graph. `save(_:for:)` removed (only caller was the rewritten `scheduleSave` closure). `saveProjectGraph` left alone — different path, out of scope.

### 10. TOCTOU + sync I/O on document-open path — won't-fix
`GraphStore.swift:82,133`; `AIServiceManager.swift:116` — `fileExists` precheck then `Data(contentsOf:)` synchronously. Drop the precheck, handle the throw. Move callers off main if not already.

**Declined.** The audit missed why the precheck exists. The precheck differentiates two log cases: `info: "No saved graph for X"` (user hasn't extracted this document yet — normal) vs `error: "Failed to load graph for X"` (file exists but read/decode failed — actually broken). Dropping the precheck collapses both into the catch and loses the signal during debugging. Could preserve it by introspecting `NSError.code == NSFileReadNoSuchFileError`, but that's uglier than the current code and observable behavior doesn't change either way — both paths return nil. The TOCTOU race is benign here (no concurrent writers, same nil outcome whichever path runs). Sync I/O is fine in practice — files are KB-MB, on local disk, called once per document-open, not in a hot loop. Current code is correct as-written for this app.

### 11. Levenshtein with no prefilter; duplicated similarity util
`GraphMergeEngine.swift:70-91,105-127,268-308` — pairwise O(N·M) Levenshtein with `Set` constructions inside the inner loop. `computeSimilarity` + `levenshteinDistance` are hand-rolled and called from 4 sites in the same file with inconsistent thresholds (0.5 vs 0.7). Length-bucket prefilter (skip if `|len(a) − len(b)| > threshold`); extract to a `StringSimilarity` util.

### 12. `.pdf` extension stripped via `replacingOccurrences`
`DocumentManager.swift:26`; `ProjectCorrelationSidebar.swift:220,228`. Use `URL.deletingPathExtension().lastPathComponent`.

### 13. `ForceDirectedLayout.resolveOverlaps` is O(n²)
`Atlas/Renderer/ForceDirectedLayout.swift:244-266` — runs after main F-R loop, ~20 iters; 500 nodes ⇒ 5M comparisons per layout. The existing `BarnesHutQuadTree` is already wired for the main loop — reuse it here, or a uniform grid keyed on `nodeSpacing`.

### 14. Force-unwraps in extraction hot path
`ExtractionPipeline.swift:308,376` — `existing.sourceAnchors.append(conceptAnchor!)` (and `entityAnchor!`). Guarded by an earlier `if conceptAnchor == nil { continue }`, but fragile to refactors. Replace with `guard let anchor = ... else { continue }`.

### 15. `UserDefaults` keys split between `AppConstants` and raw strings
`AIServiceManager.swift:140,144,151,152,61`; `AISettingsView.swift:95,164`; `PDFSearchManager.swift:113,123` use raw `"atlas.ai.backendType"`, `"atlas.ollama.baseURL"`. Consolidate into `AppConstants` (`Constants.swift:102`).

## Tier 3 — Lower urgency

### 16. `MultiDocumentView` carries 22 flat `@State` properties
`MultiDocumentView.swift:267-292`. Extract `CreateProjectSheetState`, `RenameProjectSheetState`, `SidebarFilter` structs.

### 17. Parameter sprawl on key APIs
`PDFViewRepresentable` 8-param init (`PDFViewerView.swift:694-714`); `AlertManager.showAlert` 6-param (`AppError.swift:124`); `ExtractionPipeline.processPages` 7-param (`ExtractionPipeline.swift:45-52`); `ForceDirectedLayout.runIteration` 6-param (`ForceDirectedLayout.swift:120-126`); `HighlightSyncBridge` 7-param functions (`HighlightSyncBridge.swift:147-153, 219-225`). Bundle into config structs (`PDFViewCallbacks`, `LayoutFrame`, `PulseRequest`).

### 18. `RawConcept`/`RawEdge` use `String` for typed enum fields
`Atlas/AI/AtlasModelProtocol.swift:14,30` — `let type: String // maps to ConceptType raw value`. Every call site does `ConceptType(rawValue:) ?? .concept` (5 sites across `ExtractionPipeline` + `DeepExtractionPipeline`). Decode directly to `ConceptType`/`EdgeType` with a fallback decoder.

### 19. Three ad-hoc debouncers coexist with Combine `.debounce`
Manual `DispatchWorkItem + asyncAfter`: `GraphStore.swift:146-156`, `RecentFilesManager.swift:50`, `PDFViewerView.swift:567-571`. Combine `.debounce`: `ScrollTracker.swift:24,37`, `ProjectsManager.swift:118`. The manual variants have different trailing-edge/cancel semantics. Pick one.

### 20. SHA256→hex-16 helper reimplemented
`GraphStore.swift:34-35` and `AIServiceManager.swift:131-134` — identical `hash.prefix(16).map { String(format: "%02x", $0) }.joined()`. Extract `Data.shortHexHash` or `String.shortHash16`.

### 21. Two `HighlightSyncBridge` instances live in parallel
`MultiDocumentView.swift:279` holds one; `PDFViewerView.swift:265` instantiates a fresh one inline for `NavigateToPage` handling. Pass the existing bridge in.

### 22. `KnowledgeMapView.filteredNodeIDs` recomputed every keystroke
`Atlas/Renderer/KnowledgeMapView.swift:49-57` — full graph scan per body during search-box typing. Debounce `searchQuery` 250ms + cache via `@State`.

### 23. `applyPersistentHighlights` rebuilds all annotations
`Atlas/Sync/HighlightSyncBridge.swift:38-63` — scans `graph.allNodes` and re-adds an annotation per anchor on every refresh. Diff against `activeAnnotations`; add/remove only the delta.

### 24. `KnowledgeGraph.addNode` emits `.info` log per node — partial (`be9814b`)
`Atlas/Models/KnowledgeGraph.swift:178` — 100-node batch ⇒ 100 log lines. Demote to `.debug`.

**Partially addressed:** `merge(from:)` now routes through a private silent `insert(_:)` helper (no per-node logs during cross-document merges). The extraction and decode paths still call `addNode` and emit `.info` per node. Full demotion to `.debug` was not approved this session — flag remains open.

### 25. `RecentFilesManager` re-resolves all bookmarks on each add/remove
`RecentFilesManager.swift:105,121` — full reload after every mutation. Mutate the in-memory list; resolve only the new URL.

### 26. `TextExtractor.extractBlocks` discards a `selection(for:)` call
`Atlas/AI/TextExtractor.swift:66-103`, line 87 has `_ = selection` — dead work, PDFKit selection isn't free.

### 27. Obsidian/Markdown exporters share ~70% structure
`Atlas/Export/ExportManager.swift:56-137`. Marginal cost/benefit; flag for future.

### 28. `ScrollTracker` subscribes to two overlapping notifications
`Atlas/Sync/ScrollTracker.swift:23-46` — `PDFViewPageChanged` and `PDFViewVisiblePagesChanged` both fire `onPageChanged`. `activeNodeID` set unconditionally in one branch (`BidirectionalSyncManager.swift:69-74`). Drop one observer; guard `activeNodeID` writes by equality.

### 29. Manual JSONSerialization response parsing in each backend
`ClaudeBackend.swift:142-149`, `OpenAIBackend.swift:145-152`, `GeminiBackend.swift:142-151` — `[String: Any]` casts to fetch assistant text. Use 3 tiny `Codable` DTOs.

### 30. File-leading "What" comments + decorative banners
Most files in `Atlas/` open with `//  Filename.swift / Atlas / one-line description` already obvious from class names. CLAUDE.md says skip WHAT-comments; trim opportunistically.

## Confirmed clean (verified non-issues)

- `BarnesHutQuadTree` already wired for large graphs in main F-R loop
- `PDFSearchManager.performSearch` runs off main; prior N² fixed
- `entityCountByParent` precomputed in renderer (`MapCanvasRenderer.swift:117`)
- `ConceptNode` no longer carries large blob fields
- `ScrollTracker` and `ProjectsManager` already use Combine debounce

## Suggested order

1. Tier 1 #1 (backend dedup) → unlocks most LOC reduction
2. Tier 1 #2 + #3 (label index + renderer caching) → biggest perf wins
3. Tier 1 #4 (concurrent batches) → ~3× extraction throughput
4. Tier 1 #5 (split `PDFViewerView`) → unblocks future edits to that file
5. Tier 2 #6, #7, #12, #14, #20 — sub-30-min cleanups
6. Tier 3 opportunistically when already in the file
