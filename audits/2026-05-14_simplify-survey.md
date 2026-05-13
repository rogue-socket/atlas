# Atlas Simplify Survey — 2026-05-14

Read-only review of `Atlas/` source (57 Swift files, ~13.4k lines) across three lenses: code reuse, code quality, efficiency. Findings prioritized by impact.

## Status

| Tier | Finding | Status | Commit | Notes |
|---|---|---|---|---|
| 1 | #1 AI backend duplication | ✅ done | `058936e` | Folded with 5-drift reconciliation per [`2026-05-14_backend-drift-decisions.md`](./2026-05-14_backend-drift-decisions.md). Net -202 lines across `Atlas/AI/Backends/`. |
| 1 | #2 O(n²) label lookups | ✅ done | `be9814b` | Added `KnowledgeGraph.labelIndex` + `node(matching:)`; locked `nodes`/`edges` to `private(set)`; routed `merge(from:)` through silent `insert`. 11 call sites converted. |
| 1 | #3 Renderer per-frame allocations | ⏳ next | — | Flagged as next-natural in `backlog.md`. |
| 1 | #4 Sequential LLM batches | open | — | |
| 1 | #5 Split `PDFViewerView.swift` | open | — | |
| 2 | #6–#15 | open | — | All ten cheap consolidations & correctness items unstarted. |
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

### 3. Renderer rebuilds `allNodes` array on every frame
**File:** `Atlas/Renderer/MapCanvasRenderer.swift:36,73,112,118`

Every Canvas redraw calls `graph.allNodes` (3 sites) and `graph.allEdges` (1 site) — each rebuilds `Array(nodes.values)` on `KnowledgeGraph`. `drawGroupBackgrounds` then filters to concept nodes and calls `graph.entities(for:)` per concept (a full `allNodes.filter`) → O(C·N) per frame.

**Fix:** Cache `conceptNodes` + an `entitiesByParent` map (already done for badges at line 117) once per body invocation; pass into the three draw passes.

### 4. Sequential batched LLM calls dominate wall-time
**File:** `Atlas/AI/ExtractionPipeline.swift:93-134`

The 5-page-batch `while` loop awaits each LLM call before starting the next. Batches are network-bound and largely independent (anchor lookup reads disjoint pages).

**Fix:** Wrap inner loop in `TaskGroup` with bounded concurrency (K=3); merge into the graph on the main actor. Edge proposal (step 6) stays serial.

### 5. `PDFViewerView.swift` bundles ~5 unrelated sub-views in 1549 lines
**File:** `PDFViewerView.swift`

Contains: main `PDFViewerView`, `PDFViewRepresentable` + Coordinator (683-1271, ~600 lines), `TextAnnotationDialog`, `PDFThumbnailViewRepresentable`, `PDFOutlinePanel` + `OutlineItemView`, `AnnotationListPanel` + `AnnotationRowView` (1326-1549).

**Fix:** Move panels and `PDFViewRepresentable`/Coordinator to their own files.

## Tier 2 — Cheap consolidations & correctness

### 6. Stringly-typed PDF annotation kinds
`PDFViewerView.swift:900,906,924,952,1486,1502-1510` — repeated `annotation.type == "Highlight"/"FreeText"/...` plus a 10-case string switch in `AnnotationRowView.typeIcon`. Introduce `enum AtlasAnnotationKind: String`.

### 7. `Notification.Name` string literals duplicated across 4 files
`MultiDocumentView.swift:32,155,162,326,352,357,369,374,608,718,849,954,1293`; `PDFViewerApp.swift:48,53,70,75,80`; `PDFViewerView.swift:254`. Names: `OpenNewDocument`, `NavigateToPage`, `CloseOtherTabs`, `SetPaneMode`. Add `extension Notification.Name`.

### 8. `findSourceAnchor` re-decodes every PDF page per concept
`ExtractionPipeline.swift:533-545` — loops `0..<document.pageCount` calling `page.string` (PDFKit decodes per call) and `.lowercased().contains(prefix)` for each unmatched concept. Cache `pageTexts: [Int: String]` for the batch; short-circuit by searching the batch's page range first.

### 9. `GraphStore.scheduleSave` race + strong-graph retention
`Atlas/Persistence/GraphStore.swift:146-156` — debounced work item captures `graph` strongly (only `self` is weak); `save(_:)` runs on `.utility` queue while main-actor mutates `nodes`/`edges` during `graph.encode()`. Snapshot/encode on caller; debounce only the file write.

### 10. TOCTOU + sync I/O on document-open path
`GraphStore.swift:82,133`; `AIServiceManager.swift:116` — `fileExists` precheck then `Data(contentsOf:)` synchronously. Drop the precheck, handle the throw. Move callers off main if not already.

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
