# Atlas PDF Viewer - Current Status

**Last updated:** 2026-04-28

## Quick Orientation

Atlas is a macOS PDF reader with an AI-powered knowledge map. Read `CLAUDE.md` in the project root for build commands, architecture, and gotchas.

Key entry points:
- `MultiDocumentView.swift` — main container (sidebar + detail pane)
- `PDFViewerView.swift` — PDF viewer (~1800 lines, largest file)
- `Atlas/` directory — knowledge map system (extraction pipeline, graph, renderer)

## What Was Just Done (2026-04-28)

Fixed two knowledge map interaction bugs (GitHub #15, #18):

### Issue #15: Node drag fixes
- **Root cause:** `handleDragChanged` applied cumulative translation on top of already-moved node position, causing runaway movement. Also, `selectedNodeID` set during drag could trigger layout recomputation which calls `fitToContent`, resetting the viewport.
- **Fixes:** Store initial node position on drag start, compute new position from `startPos + delta`. Guard `fitToContent` and `recomputeLayout` with `isDraggingNode` flag. Made `isDraggingNode` publicly readable.

### Issue #18: Scroll wheel zoom
- **New file:** `ScrollWheelOverlay.swift` — `NSViewRepresentable` wrapper that captures `scrollWheel:` events from AppKit and forwards delta+location to `MapInteraction.handleScrollWheel()`.
- **Zoom-toward-cursor:** `handleScrollWheel` adjusts both `viewScale` and `viewOffset` so the zoom centers on the cursor position.

## What Was Done (2026-04-27)

Implemented 4 UX fixes from `docs/UX_FIXES_PLAN.md`. All compile cleanly.

### PR1: Viewer UX
- **Alert system wired up** — `CompactAlertView` overlay added to `MultiDocumentView` (was dead code before). Alert goes after command palette overlay and dismisses palette on appear. `AppError` now has `.severity` (`.modal` vs `.toast`). `AlertManager.routeError()` dispatches accordingly.
- **Recent files UX** — Inaccessible files no longer silently removed. They show dimmed with warning icon. Tap failure shows modal alert with "Remove from Recents". Right-click context menu on all items. Stale launch counter auto-removes after 3 launches. `DocumentManager.openDocument()` returns `OpenResult` enum instead of `Bool`.

### PR2: Extraction UX
- **Progress + cancel** — `ExtractionPipeline` now has `progress` property, `cancel()` via `Task` cancellation, page counter. `KnowledgeMapView` shows linear progress bar + cancel button in a material card.
- **OCR fallback** — `TextExtractor` has Vision OCR (`ocrExtractPages`). Auto-runs when no embedded text found. One page at a time for memory safety. Low-density text (<10 chars/page) sets `scannedPDFDetected` flag; banner shown in map view with "Run OCR" button.

## What's Next

See `docs/UX_FIXES_PLAN.md` verification checklist (bottom of file) — those scenarios need manual testing in the running app.

### Remaining work from `docs/TODO.md` (not yet started):
- **Annotation move/resize** — handles/drag UX (TODO item 13)
- **Dark mode** — end-to-end appearance validation (TODO item 13)
- **Instruments profiling** — Time Profiler + Allocations on large PDFs (TODO item 11)
- **Annotation coordinate system** — verify accuracy, use PDFKit built-in methods (TODO item 9)
- **State management** — currentHighlight sync, annotation persistence (TODO item 10)
- **Xcode test target** — test files exist in `pdf_app1Tests/` but aren't wired into a scheme (TODO item 16)
- **Project-level search** — V2 of Projects feature, multi-PDF search (TODO item 18)

### Priority order (user's judgment):
1. Manual testing of the 4 UX fixes just implemented
2. Annotation move/resize
3. Dark mode tuning
4. Project-level search (V2)

## Files Modified This Session

| File | What changed |
|------|-------------|
| `MapInteraction.swift` | Fixed node drag position calc, added `handleScrollWheel`, guarded `fitToContent` during drag |
| `KnowledgeMapView.swift` | Added `ScrollWheelOverlay`, guarded `recomputeLayout` during drag |
| `ScrollWheelOverlay.swift` | **New** — NSViewRepresentable for scroll wheel capture |

## Files Modified Previous Session

| File | What changed |
|------|-------------|
| `AppError.swift` | Added `severity`, `ErrorSeverity` enum, `routeError()` on AlertManager |
| `MultiDocumentView.swift` | Alert overlay, recent files dimming/context menu/OpenResult handling |
| `PDFViewerView.swift` | Added `@EnvironmentObject var alertManager` |
| `DocumentManager.swift` | `OpenResult` enum, `openDocument` returns it |
| `RecentFilesManager.swift` | `inaccessibleFiles` as Set, stale launch counter, no auto-remove |
| `ExtractionPipeline.swift` | `progress`, `cancel()`, `scannedPDFDetected`, Task-based processing, OCR fallback path |
| `TextExtractor.swift` | `import Vision`, `ocrExtractPages()` with 300 DPI rendering |
| `KnowledgeMapView.swift` | Progress bar + cancel button, scanned PDF banner, non-async startExtraction |
