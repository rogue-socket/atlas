# Backlog

Durable "someday/maybe" items — distinct from session-level Unresolved (which is "next session"). Each entry: one-line item specific enough to act on cold, optional priority, **Why:** if non-obvious.

<!-- from: docs/STATUS.md (What's Next, as of 2026-04-29) -->
<!-- from: docs/TODO.md (unchecked items, as of 2026-05-04) -->

## Bugs

<!-- Fixed 2026-05-11: RecentFilesManager.autoRemoveStaleFiles never fired (init's sync call read inaccessibleFiles before the async file-check populated it). Restructured init to dispatch autoRemoveStaleFiles as a barrier on fileCheckQueue → main, so it runs as a continuation after async checks. Coverage: testInaccessibleFileMarkedAfterAsyncCheck (tracer), testInaccessibleFileAutoRemovedAfterThreeStaleLaunches (the bug), testRemoveInaccessibleFileResetsStaleCounter (counter-reset on manual remove). -->

<!-- Fixed 2026-05-07 (on wip/feature-cherry-pick, not yet committed):
  - Shared in-memory graph leaks across documents → MultiDocumentView.loadGraphIfNeeded clears when no saved graph
  - deleteProject doesn't clean up → ProjectsManager.deleteProject deletes per-doc + project graphs; call site closes open tabs
  - Two analyze paths use different modes → MultiDocumentView now reads @AppStorage selectedMode and passes to processFullDocument
  - GraphStore URL-only cache key (content invalidation) → StoredGraph wrapper stamps mtime+size; load invalidates on mismatch
  - hierarchyLevel decode default wrong for concept nodes → KnowledgeGraph.swift:109 now defaults based on level
-->
<!-- Fixed 2026-05-08 (on wip/feature-cherry-pick):
  - JSONRepair double-bracket on truncated edges array → JSONRepair.swift tracks closedArray; targeted test passes (commit 3a0f813)
  - .document zoom = picked-node not summary → ConceptNode gains isDocumentSummary; ExtractionPipeline.appendDocumentSummary helper called from both fast and deep pipelines; DensityManager prefers summary node (uncommitted, build green, tests blocked by testmanagerd hang)
-->

## Active / Next

- [active 2026-05-12] Annotation move/resize — body-drag-to-translate landed on `main` (via PR #49, commits `30a884d` → `690e0a6`) and **user-confirmed working** during PR #49 smoke testing. Remaining for full feature: corner/edge resize via `AnnotationGeometry.resized` + `handle(at:)` (math is in but unused), selection chrome overlay (handles + selection rect), click-without-drag selection, keyboard delete. **Priority:** medium-high.
- [next 2026-05-14] Port `rogue-socket/issue-11` (guided tour, #11) — last unmerged branch. ~700 unique lines: new `Atlas/Tour/` directory (`GuidedTour`, `TourGenerator`, `TourPlayer`, `TourPlaybackView`, `TourPlayerTests`) + `MapInteraction.focusOnNode` + `KnowledgeMapView` wiring. Apply same audit-diff-adapt-commit pattern used for grounded-chatbot today. Will need a real port (not an already-merged finding).
- [next 2026-05-14] After issue-11 port, next batch is **PR-A (6 perf wins, behavior-preserving)** or **PR-B (7 correctness bugs)**. See `audits/2026-05-12_issue-batching.md`. Smallest single fix: #47 `MapInteraction.recenter` triple-walk. Largest perf win: #27 hoist per-frame derivations out of MapCanvasRenderer draw closures. PR-B should land before any PR-D refactor (#25/#33/#34/#37/#40/#41) touches the same files.
- [next] **Smoke-test the 2026-05-14 backend changes live.** Behavioral changes from drift reconciliation (Claude temperature 0.1 → deterministic extraction; throw on UTF8/JSON decode failure → clear error in chat instead of garbled text) shipped in commit `058936e` but were build-green-only — never exercised against a live backend. Run extraction on a sample PDF with Claude + Ollama at minimum. If a regression shows up, the revert is one commit.
- [next] **Smoke-test the PDFViewerView split (`a01e05c`).** Pure file shuffle landed build-green only; no test coverage on PDFViewerView. Open a PDF and exercise: every annotation mode (highlight text / underline / strikethrough / area highlight / ink / rectangle / circle / line / arrow / text / sticky note / select-and-drag), cursor changes per mode (this is the fragile `updateNSView` path now living in the moved `PDFViewRepresentable.swift`), outline panel navigation, annotation list panel (refresh, click-to-navigate, delete). Bundle with the backend smoke-test above if convenient. Revert window is one commit if anything regresses.
- Tier 1 #3 (renderer per-frame allocations) — **deferred until profiled.** Attempted in `fa9f768`, reverted in `22b770e`. See `audits/2026-05-14_simplify-survey.md` Deferred paragraph. If a real perf issue surfaces, the right shape is an `entitiesByParent` index in `KnowledgeGraph` (analogous to `be9814b`'s `labelIndex`), not a renderer rewrite.
- Tier 1 #4 (sequential LLM batches) — **deferred (accuracy over speed).** All three optimization paths (move `proposeEdges` out of per-batch loop, K=3 `TaskGroup` concurrency, larger `batchSize`) trade some concept-graph accuracy for wall-time. See `audits/2026-05-14_simplify-survey.md` Tier 1 #4 Deferred paragraph for the three-option walkthrough. Option (a) — hoist `proposeEdges` to a single end-of-extraction call — is future-scope if wall-time becomes a complaint that outweighs the edge-quality cost.

<!-- Done 2026-05-14 (overnight, second pass):
  - /simplify Tier 1 #5 (PDFViewerView split, commit `a01e05c`): pure file shuffle, no behavior change. Three new files — `pdf_app1/pdf_app1/PDFViewRepresentable.swift` (601 lines: bridge + nested Coordinator), `Atlas/UI/PDFOutlinePanel.swift` (98 lines), `Atlas/UI/AnnotationListPanel.swift` (146 lines). PDFViewerView.swift shrinks 1549 → 734 lines; retains BookmarkManager + HighlightingPDFView at top, PDFViewerView itself, plus TextAnnotationDialog (35) and PDFThumbnailViewRepresentable (19) — too tiny to split. Project's PBXFileSystemSynchronizedRootGroup auto-discovers new files. Build green. Off-by-one extraction caught a missing `}` mid-build; live smoke-test still recommended since no test coverage on PDFViewerView and the known `updateNSView` cursor workaround now lives in the moved bridge file.
-->

<!-- Pattern A resolved 2026-05-11 via structural fix: removed `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from project.pbxproj (4 occurrences). Only fallout was 2 PDFKit-touching methods in HighlightSyncBridge needing explicit @MainActor. Full suite: 58/6-incomplete → 64/0-incomplete. Side-effect: exposed and fixed a long-standing ProjectsManager save/load race (CombineLatest3 never emitted without projectsSortMode change; load() overwrote in-memory state when file missing). -->
- Optionally swap `summarizeConcept` for `generateRawResponse` + custom doc-summary prompt if "Summarize the concept '<filename>'" wording produces awkward output once a real run happens. Low priority; only if observed.

<!-- Done 2026-05-14 (late):
  - PR-C audit cleanup batch landed on main as 3 commits (range 40da3ac..5973d19, pushed): `4c345f0` dropped dead `HighlightingPDFView.pageCache` machinery (write-only cache + boundsDidChange observer + debounce timer + thumbnail rendering, −77 lines, **#31**); `b9b8f83` dropped `annotationModeLabel`/`annotationUsesColor` from PDFViewerView (superseded by MultiDocumentView equivalents during 2026-05-12 toolbar relocation) plus unused `columnVisibility` `@State`; `5973d19` switched `DocumentManager.recentFilesManager` from `weak var ?` to init-injected `let` (PDFViewerApp constructs both @StateObjects in `init()`; eliminates silent-nil failure mode) and inverted stale `testDeepModeIsUnavailable` test that had been red since `7315aad` flipped Deep available. Net −93 lines. Build green; ExtractionModeTests green. **#31 + #46 (DI half) closed via trailers.**
  - #36 (textAnnotationPoint dead state) closed won't-fix after first-principles reassessment: the `@State` "buffer between callbacks" is the normal SwiftUI pattern; refactor to `.sheet(item:)` required an Identifiable wrapper struct + hand-rolled `Binding(get:set:)` that added cognitive load without solving any defect. Prototype reverted before committing.
  - #46a (zoom format) declined as part of #46 close: comment added explaining the formatter rewrite had unverified `isLenient` interaction with `positiveSuffix` (parsing "150" without suffix may fail under strict mode) and unrequested min/max/allowsFloats restrictions that could reject pre-existing stored values. Original `format: .number` + `Text("%")` pattern is widely used (e.g. Print > Scale) and left alone.
  - Open-issues sweep: spot-checked all 24 open issues. #6 Deep mode close-eligible on 3 of 4 hard criteria but criterion 5 (per-pass progress UI) unverified and 6 (HITL quality) is #50 — kept open. #26 cache coherence partially obsolete (2 of 3 cache vars gone via `f6b35b6`; cache now hot-path-read; but `graphForCurrentZoom` allocates per call + dual `onChange` race remains) — kept open. Everything else verified still applicable.

  Grounded chatbot (#12) landed on main as 8 commits (range 7a03bf7..2b16016): ChatViewModel + ChatPanelView + 10-cycle ChatViewModelTests + MultiDocumentView integration (⌘4 toggle, HStack wrap, lazy toggleChat()). Smoke-tested live; 10/10 tests pass. Port adapted to use main's existing `aiService` env var (not duplicate `aiServiceManager`) and preserved 3-arg `onNavigateToPage` callback. Skipped branch's pbxproj/xcscheme hunks — project uses PBXFileSystemSynchronizedRootGroup which auto-discovers new files.
  - Branch cleanup: deleted 4 orphan branches whose content was already on main under different SHAs — `rogue-socket/fix-resize-lag` (PR #19 + later refinement b6e35dd), `rogue-socket/fix-settings-link` (PR #21, d4aaa5f), `rogue-socket/wire-multi-doc-extract` (PR #20, 997d254; main's version is strictly better, passes `mode: selectedMode`), `rogue-socket/fix-map-drag-zoom` (PR #22, was held by Conductor worktree at ~/conductor/workspaces/atlas/papeete — worktree removed first). Also pruned stale `origin/refactor/24-fdl-barnes-hut` ref.
  - KnowledgeMapView cleanup landed as f6b35b6: removed dead `cachedFilteredNodeCount` + `cachedZoomLevel` @State vars and their writes (4 lines). Vestige of a planned staleness check that was never wired up — actual cache refresh is gated by the onChange handlers that call recomputeLayout. Workspace-wide grep confirmed zero reads pre-removal.
  - Local `rogue-socket/grounded-chatbot` branch deleted post-merge.
  - One unmerged branch remains: `rogue-socket/issue-11` (guided tour subsystem, ~700 unique lines including `Atlas/Tour/*` + KnowledgeMapView wiring + MapInteraction.focusOnNode).
  - Flagged but not pulled forward: HighlightingPDFView pageCache machinery (~70 lines populated-but-never-read) is audit issue #31, slotted for PR-C cleanup batch.
-->

<!-- Done 2026-05-14 (late evening):
  - /simplify Tier 3 cheap-dedup batch — 2 commits direct to main (`8e48cfc..f54af50`, pushed): #20 extracted `String.sha256HexPrefix16` helper in new `Atlas/Utils/String+Hash.swift`, removed the SHA256→hex-16 dup at GraphStore.graphFileURL + AIServiceManager.cacheKey (CryptoKit imports dropped from both); #26 deleted the wasted `page.selection(for: NSRange(fullText))` inside `TextExtractor.extractBlocks`'s per-line loop — the `_ = selection // suppress warning` line was a band-aid pointing at exactly this dead work. Reframe during analysis: the call ran once per line (not once per page as the audit implied), so the impact is a real per-extraction perf win on text-heavy pages, not just dead-code removal.
  - /simplify Tier 3 #28 (`2990b57`): dropped `.PDFViewVisiblePagesChanged` observer from `ScrollTracker` — duplicated `.PDFViewPageChanged` at slower debounce (200ms vs 100ms) in this app's `.singlePageContinuous` mode. Plus equality-guarded the 3 `activeNodeID` write sites in `BidirectionalSyncManager.updateActiveNode` so `@Observable` doesn't notify downstream (`DensityManager`, `MapCanvasRenderer`) for stay-on-same-page scrolls.
  - /simplify Tier 3 #22 (`be82520`): map search filter now @State-cached (was a computed property that ran on every body eval, doubled because referenced in 2 places) AND 250ms-debounced via `.task(id: searchQuery)`. TextField stays bound to the immediate `searchQuery` so input is responsive; `debouncedSearchQuery` drives the filter. Clearing the field is immediate (no 250ms hangover). Re-runs filter on graph.nodeCount changes too so new nodes appearing during extraction with search open get filtered.
  - /simplify Tier 3 #23 (`6f8131c`): `HighlightSyncBridge.applyPersistentHighlights` now diff-based. Storage moves from `[UUID: [PDFAnnotation]]` to `[AnchorKey: PDFAnnotation]` (Hashable struct over documentURL + nodeID + pageIndex + decomposed bounds) so apply can compute desired vs existing per-document and only add/remove the delta. Previously each extraction batch wiped and re-added ALL Atlas annotations — O(N²/2) PDFKit ops total. `refreshHighlights` collapses to a one-line alias. URL in the key also fixes a latent wholesale-overwrite quirk relevant to audit #21. All 5 HighlightSyncBridgeTests pass.
  - Build green at each step.
-->

<!-- Done 2026-05-14 (evening):
  - /simplify Tier 2 cheap-sweep batch landed direct to main as 5 commits (`6447ba9..940e414`, pushed): #7 typed Notification.Name + dead `OpenDocuments` observer deletion; #12 `URL.deletingPathExtension()` over lowercase-only string strip; #14 guard-let over force-unwrap in ExtractionPipeline; #15 UserDefaults keys (`atlas.ai.backendType/model`, `atlas.ollama.baseURL`) into AppConstants; #6 new `Atlas/Annotations/PDFAnnotation+Kind.swift` shim that re-prefixes PDFKit's read/write slash asymmetry so all kind comparisons unify on `PDFAnnotationSubtype` constants. Build green at each step.
  - Phase-1 "deep why" pass on each item before code. Notable findings: `OpenDocuments` was orphan listener with zero posters (codebase + plists + no AppDelegate URL hook); audit's claim about `PDFSearchManager` raw keys was wrong (already encapsulated as private let); #6's "use an enum" was the wrong shape because PDFKit's read/write API uses two different string forms — a thin getter shim was the right size of fix.
  - /simplify Tier 2 latent-bug track: #9 `GraphStore.scheduleSave` race fixed (`42fe76c`) — encode now runs synchronously on caller's thread, work item captures `Data` (value type) instead of `KnowledgeGraph` reference. Eliminates the concurrent dict read/write hazard between background save and ongoing extraction mutations. #10 (TOCTOU on file load) declined — the `fileExists` precheck the audit wanted removed is deliberate log differentiation between "no saved graph yet" (info) vs "load failed" (error); reasoning captured in survey.
  - Open Tier 2 items: #8, #11, #13 held pending profile data (same reasoning as Tier 1 #3).
-->

<!-- Done 2026-05-14 (late afternoon):
  - Full-codebase /simplify survey across 57 Swift files / ~13.4k lines. Three parallel agents (reuse / quality / efficiency); aggregated to 30 findings in 3 tiers at `audits/2026-05-14_simplify-survey.md`.
  - Tier 1 #1 (AI backend dedup, commit `058936e`): Discovered 5 real drifts via deep-dive analysis (most consequential: Claude's `temperature` knob was unset, defaulting to ~1.0 vs OpenAI/Gemini's 0.1 — silent quality drift). Drafted `audits/2026-05-14_backend-drift-decisions.md` with user sign-off (D2 overrode my recommendation: throw errors, don't surface garbled text). Applied 7 surgical reconciliation edits, then extracted `LLMBackend` protocol with default implementations of all 6 public methods + `LLMResponseParser` enum. Each vendor backend now only implements `transport(prompt:)` + identity. Net Backends/ folder: 593 → 391 lines.
  - Tier 1 #2 (label-lookup dedup + perf, commit `be9814b`): Added `labelIndex: [String: UUID]` to `KnowledgeGraph` with `node(matching:)` for O(1) lookup. Made `nodes` and `edges` `private(set)` after `rg`-verifying zero external writes. Routed `merge(from:)` through silent private `insert(_:)` (no per-node log spam during cross-document merges). Replaced 11 `allNodes.first { $0.label.lowercased() == ... }` call sites with `graph.node(matching:)` across `ExtractionPipeline.swift`, `DeepExtractionPipeline.swift`, `GraphMergeEngine.swift`.
  - Build green at each step. Tests not run. Ollama still works (verified path through `OpenAIBackend` with localhost base URL).
  - Documentation pass (commit `c83ef3e`): added Status table to the simplify survey with per-finding state / commit SHA / partial markers; wrote `audits/WORKFLOW.md` capturing the 5-phase pattern (Analyze → Decide → Reconcile → Refactor → Commit) with anti-patterns, the "intern translation" technique, and Tier 1 #1 + #2 as worked examples pointing at actual commits. Intended as the baseline for future audit work.
  - Five commits landed direct to `main` and pushed: `46ea52c..c83ef3e` (audit docs / backend dedup+reconciliation / KnowledgeGraph label index / backlog sync / docs pass).
  - Open follow-ups: smoke-test live (build-green only); the 3 `allNodes.map { $0.label }` prompt-context sites in `ExtractionPipeline.swift` could become `Array(labelIndex.keys)` opportunistically; Tier 3 #24 (`addNode` `.info` log spam during extraction/decode) still open — only `merge(from:)` is silent now.
-->

<!-- Done 2026-05-09:
  - Doc-migration commit landed as 0e5d650 (13 files, +123/-1048): 7 doc deletions, 2 test-script renames to pdf_app1/scripts/, scaffolding directories. Branch now 30 commits ahead of main.
  - XCTest verification completed for items that did run: test_jsonRepair_closesUnclosedNovakResponse and test_conceptNode_hierarchyLevel_legacyJSON_defaultsByLevel both passed; existing ConceptNode Codable tests pass with the new isDocumentSummary field; 0 regressions.
  - Pattern A diagnosed: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor in project.pbxproj makes every class implicitly @MainActor; macOS 26.3's Swift Concurrency runtime double-frees during isolated-deinit teardown of arrays of nested class instances. Backtrace from .ips: ___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED → swift::TaskLocal::StopLookupScope::~StopLookupScope() → swift_task_deinitOnExecutorImpl → QuadTreeNode.deinit.
  - macOS 26.3 fixes landed as c8cad91 (4 files, +54/-9): QuadTreeNode and HighlightSyncBridge marked `nonisolated`, XCTest-host guard added to DocumentManager.restoreOpenSession() so tests no longer load user PDFs/graphs. Bundled with yesterday's pending HighlightSyncBridge whitespace-flexible regex fix (multi-line snippet matching) since adjacent in same file. Result: 42→54 passing, BarnesHut and HighlightSyncBridge classes now fully clean; testFindPassageRects_multiLineSnippet_returnsMultipleRects verified.
  - .document summary node + 05-07/08 bug-triage bundle landed as 7001791 (8 files, +191/-22): ConceptNode.isDocumentSummary field with backward-compat decode, ExtractionPipeline.appendDocumentSummary helper called from fast and deep pipelines, DensityManager prefers summary nodes; plus ProjectsManager.deleteProject cleanup, MultiDocumentView.loadGraphIfNeeded clear-on-doc-switch, analyze-mode @AppStorage threading, level-aware hierarchyLevel decode default, GraphStore content-invalidation via StoredGraph wrapper. Two themes were entangled in KnowledgeGraph.swift and DensityManager.swift — bundled rather than split.
  - Branch wip/feature-cherry-pick is now 32 commits ahead of main (was 28 going into today). Working tree clean.
  - isDocumentSummary Codable coverage added to NodeSizingTests.swift (testDecodingWithoutIsDocumentSummaryDefaultsFalse + testIsDocumentSummaryRoundTripsThroughCodable). 9/9 NodeSizingTests pass.
  - Stale backlog item dropped: "Resolve pre-merge STATUS.md conflict in commit 853cbba." Inspection showed 853cbba's actual diff is `DeepExtractionPipelineTests.swift` only — the commit message mentions STATUS.md but no STATUS.md change was ever staged. No conflict to resolve.
-->


## Annotations
<!-- Body-drag-translate landed 2026-05-12 — see [active] above. Remaining work tracked there. -->
- Annotation move/resize — drag handles UX, the resize half (TODO #13). **Priority:** medium-high. Now scoped to: corner/edge handle resize (math in `AnnotationGeometry.resized` is unused but tested), selection chrome overlay (NSView on top of `PDFView`, ~80 lines), click-without-drag selection, keyboard delete on selection.
- Verify annotation coordinate conversion accuracy; use PDFKit built-in conversion methods consistently; fix Y-coordinate inversion if needed; dynamic annotation sizing based on content; coordinate-conversion tests; thorough bounds validation (TODO #9).
- Annotation state persistence between sessions; fix `currentHighlight` sync; improve state management patterns; state validation (TODO #10).

## Dark mode
- Dark mode end-to-end appearance validation: test, optimize colors, ensure readability (TODO #13).

## Performance & profiling
- Run Instruments (Time Profiler + Allocations) on large PDFs and address hotspots (TODO #11; Final Review 2026-01-16).
- Add memory leak detection in tests (TODO #5).

## Recent files
- Test recent files persistence across app restarts and system reboots (TODO #2).
<!-- Removed 2026-05-07: stale-bookmark refresh persistence — already implemented in RecentFilesManager.swift:151-184 (likely via commit 7e1c605). -->


## Window state
- Test default fullscreen on different screen sizes (TODO #3).
- Consider user preference for window state (windowed vs fullscreen) (TODO #3).

## updateNSView
- Test state synchronization for updateNSView (TODO #8).

## Tests / CI
<!-- Verified 2026-05-11: tests are wired — scheme `pdf_app1` has a TestAction with `pdf_app1Tests.xctest` as a TestableReference; `xcodebuild test` runs the full suite. Stale CLAUDE.md note removed. -->
- Set up CI/CD with test automation (TODO #16).
- Aim for >80% code coverage (TODO #16).

## Documentation
- Document all extracted constants (TODO #6).
- Code documentation: comments for complex logic, public-API docs, architecture doc, coordinate-conversion logic, annotation system, state management patterns (TODO #7).
- Create developer guide (TODO #7).

## UX research / accessibility
- Research standard PDF viewer UI patterns (Preview.app, Adobe Reader); document best practices (TODO #12).
- Test with accessibility tools (TODO #12).

## Export & sync (future)
- Export annotations: separate file / text / markdown / share (TODO #15). **Priority:** low.
- Cloud sync integration: iCloud, other providers, sync annotations across devices (TODO #15). **Priority:** low.
- Advanced annotation tools: shapes (rectangle, circle, arrow), freehand drawing, stamps, more types (TODO #15). **Priority:** low.

## Project-level search V2
<!-- from: docs/TODO.md #18 -->
- Project-level search bar: searches across PDFs within selected project. **Priority:** medium.
  - UX: scope = selected project (default); group results by file then page; click result opens file + scrolls to page + highlights match.
  - Perf: async + cancellable (typing cancels prior search); progressive/streamed results; hard cap per file and total; avoid re-indexing unchanged PDFs (cache by mtime).
  - Data model: persist per-project search history; persist per-file index metadata (hash/mtime/pages).
  - Implementation: extend `PDFSearchManager` to multi-document; per-file tasks with cooperative cancellation; in-memory index cache for current project session; optional background "index warmup" on project open.
  - Polish: per-file "Searching…" indicator; show skipped (inaccessible/missing) files; "Stop" button.
