# Issue Batching: 2026-05-04 Audit Dump (#25–#47)

**Date:** 2026-05-12
**Source audit:** 22 issues filed in a batch on 2026-05-04 covering perf, bugs, dead code, and large refactors across `PDFViewerView`, `MultiDocumentView`, the map renderer/layout, and supporting views.

This doc groups the 22 issues into 4 PR-sized chunks ordered by risk profile, with file lists and effort estimates. The intent is: each batch is reviewable in one sitting, and the order avoids refactoring buggy code.

GitHub labels track membership:

- `batch-A-perf` — hot-path perf wins, behavior-preserving
- `batch-B-bugs` — state hazards and correctness fixes
- `batch-C-cleanup` — dead code and small polish
- `batch-D-refactor` — large architectural splits

---

## PR-A — Hot-path perf wins (6 issues)

Behavior-preserving micro-optimizations. Land first.

| # | Title | Primary file |
|---|---|---|
| #27 | Perf: hoist per-frame derivations out of MapCanvasRenderer draw methods | `Atlas/Renderer/MapCanvasRenderer.swift` |
| #28 | Perf: skip group-background draw when graph has no entity groups | `Atlas/Renderer/MapCanvasRenderer.swift` |
| #29 | ForceDirectedLayout: convergence early-exit, position preservation, cached group centers | `Atlas/Renderer/ForceDirectedLayout.swift` |
| #35 | Perf: sepia overlay and toolbar GeometryReader rebuild every render | `PDFViewerView.swift` |
| #38 | Perf: memoize `filteredProjects` and `hasUnprocessedFiles` | `MultiDocumentView.swift` |
| #47 | Perf: `MapInteraction.recenter` walks layout positions three times instead of once | `Atlas/Renderer/MapInteraction.swift` |

**Effort:** 1–2 days. Each fix is localized (10–50 line edits). Add XCTest measuring iteration counts where verifiable; skip micro-benchmarks otherwise.

## PR-B — State hazards & correctness bugs (7 issues)

Real bugs causing visible misbehavior or resource leaks. Must land before PR-D so refactors operate on correct code.

| # | Title | Primary file(s) |
|---|---|---|
| #26 | Bug: KnowledgeMapView cache coherence hazard + per-render graph rebuild | `Atlas/Renderer/KnowledgeMapView.swift` |
| #30 | Bug: KnowledgeMapView onChange handlers race; `filteredNodeIDs` recomputed every frame | `Atlas/Renderer/KnowledgeMapView.swift` |
| #39 | Bug: `highlightBridge.refreshHighlights` called unconditionally; cross-document state leak | `Atlas/Sync/HighlightSyncBridge.swift`, `MultiDocumentView.swift` |
| #42 | Bug: EnhancedDropView has duplicate `.onDrop` modifiers; `isDropTargeted` stuck on cancelled drag | `EnhancedDropView.swift` |
| #43 | Bug: EnhancedDropView accepts duplicate URLs in a single drop | `EnhancedDropView.swift` |
| #44 | Bug: SearchBarView clears highlights live but only searches on submit — inconsistent UX | `SearchBarView.swift` |
| #45 | Bug: DocumentManager leaks security-scoped access on late PDF load failure; `maxOpenDocuments` hardcoded | `DocumentManager.swift` |

**Effort:** 2–3 days. Write a **failing test first** for #39, #42, and #45 — silent-regression risk is high for state-leak bugs.

## PR-C — Dead code & small polish (3 issues)

Net-negative line counts. Lowest risk; could be the warmup PR.

| # | Title | Primary file(s) |
|---|---|---|
| #31 | Cleanup: HighlightingPDFView `pageCache` populated but never used | `PDFViewerView.swift` (nested class) |
| #36 | Cleanup: dead state in PDFViewerView (`textAnnotationPoint`) | `PDFViewerView.swift` |
| #46 | Cleanup: AppPreferences zoom-level input format; PDFViewerApp `recentFilesManager` wiring | `AppPreferences.swift`, `PDFViewerApp.swift` |

**Effort:** half day.

## PR-D — Large refactors (6 issues)

Architectural work. Land last on stabilized code.

| # | Title | Primary file(s) |
|---|---|---|
| #25 | Refactor: split PDFViewerView.swift (1890 lines) into composable views | `PDFViewerView.swift` → new files |
| #33 | Bug: PDFViewerView relies on `DispatchQueue.asyncAfter` timing hacks for layout stabilization | `PDFViewerView.swift` |
| #34 | Bug: PDFViewerView owns NSView via `@State`; redundant document assignment; unsafe weak deref; gesture-recognizer init | `PDFViewerView.swift` |
| #37 | Refactor: MultiDocumentView consolidates duplicate doc-load paths in `onChange`/`onAppear` | `MultiDocumentView.swift` |
| #40 | Refactor: extract shared Recents component; dedupe Cmd+K command-palette handler | `MultiDocumentView.swift` → new `RecentsView.swift` |
| #41 | Refactor: split MultiDocumentView (1174 lines) into sidebar / detail / tabs | `MultiDocumentView.swift` → new files |

**Effort:** ~1 week. Two natural sub-chunks if it gets unwieldy:

- **D1** (PDFViewerView): #25, #33, #34
- **D2** (MultiDocumentView): #37, #40, #41

D1 first — splitting PDFViewerView makes #33/#34 simpler. Then D2 — splitting MultiDocumentView makes #37/#40 cleaner.

---

## Suggested merge order

1. **PR-C** — warmup, half day, removes dead code
2. **PR-A** — perf, 1–2 days, behavior-preserving (can run in parallel with reviewing B)
3. **PR-B** — correctness, 2–3 days, fixes bugs before refactors touch them
4. **PR-D** — refactors, ~1 week, optionally split into D1/D2

A and C don't conflict and can ship in parallel. B must land before D regardless.

## Notes

- Issue **#32** is absent — closed, never existed, or skipped in numbering. Not in this audit dump.
- Each PR should include `Closes #N` trailers so issues auto-close on merge.
- Suggested PR labels: `enhancement`+`performance` (A), `bug` (B), `cleanup` (C), `refactor` (D).
