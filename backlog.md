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

## Active / Next (2026-05-09)

<!-- Pattern A resolved 2026-05-11 via structural fix: removed `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from project.pbxproj (4 occurrences). Only fallout was 2 PDFKit-touching methods in HighlightSyncBridge needing explicit @MainActor. Full suite: 58/6-incomplete → 64/0-incomplete. Side-effect: exposed and fixed a long-standing ProjectsManager save/load race (CombineLatest3 never emitted without projectsSortMode change; load() overwrote in-memory state when file missing). -->
- Optionally swap `summarizeConcept` for `generateRawResponse` + custom doc-summary prompt if "Summarize the concept '<filename>'" wording produces awkward output once a real run happens. Low priority; only if observed.

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
- Annotation move/resize — drag handles UX (TODO #13). **Priority:** medium-high.
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
