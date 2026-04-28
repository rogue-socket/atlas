# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build from command line
cd pdf_app1
xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build

# Build output location
~/Library/Developer/Xcode/DerivedData/pdf_app1-*/Build/Products/Debug/pdf_app1.app

# Clean build
xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 clean
```

Or open `pdf_app1/pdf_app1.xcodeproj` in Xcode and press Cmd+R.

**No test target is configured in the Xcode project.** Test files exist in `pdf_app1/pdf_app1Tests/` but are not wired into a test scheme.

**No external dependencies.** The app uses only Apple system frameworks: PDFKit, SwiftUI, AppKit, Combine, CryptoKit, Security, os.log.

## Architecture

The app is a macOS PDF reader ("Atlas") with an AI-powered knowledge map. Two main systems:

### 1. PDF Viewer (existing, pre-Atlas)

`PDFViewerView.swift` is the largest file (~1800 lines). It contains:
- `HighlightingPDFView` — custom `PDFView` subclass with mouse hooks, page caching (max 10), async rendering
- `PDFViewRepresentable` — `NSViewRepresentable` bridge with a `Coordinator` that handles gestures, annotations, context menus
- The toolbar (responsive, collapses at <580px width)
- Annotation system (8 types: highlight, underline, strikethrough, text, sticky note, ink, shapes)

`MultiDocumentView.swift` is the main container: `NavigationSplitView` with a sidebar (open tabs, projects/recents picker) and a detail pane that wraps `PDFViewerView` + `KnowledgeMapView` in a `SplitPaneContainer`.

### 2. Atlas Knowledge Map (`Atlas/` directory)

**Data flow:** PDF pages → `TextExtractor` → `LayoutAnalyzer` → `ExtractionPipeline` → AI backend → `KnowledgeGraph` → `ForceDirectedLayout` → `MapCanvasRenderer`

**State injection:** `PDFViewerApp` creates `KnowledgeGraph` and `AIServiceManager` as `@State` (using Swift `@Observable`, not `ObservableObject`) and injects via `.environment()`. The PDF viewer's existing managers (`DocumentManager`, `ProjectsManager`, `RecentFilesManager`) use the older `@StateObject` + `.environmentObject()` pattern.

**AI backends** implement the `AtlasModel` protocol (4 methods: extractConcepts, proposeEdges, summarizeConcept, answerQuestion). All use raw `URLSession` with 180s timeout. API keys stored in macOS Keychain via `Security` framework. Response caching uses SHA256(model+prompt) as key, stored in `~/Library/Application Support/Atlas/cache/`.

**Novak-style extraction (Fast mode):** The prompt asks for proposition-based concept maps — 5-6 top themes (`hierarchyLevel: 0`) with sub-concepts (`hierarchyLevel: 1+`) linked via `subtopicOf`. Every edge has a `linkingPhrase` (1-4 word verb phrase) so "A [phrase] B" reads as a sentence. `RawConcept` carries `hierarchyLevel: Int?` and `subtopicOf: String?`; `RawEdge` carries `linkingPhrase: String?`. The pipeline auto-creates `EdgeType.subtopicOf` edges from the `subtopicOf` field.

**Hierarchical collapse/expand:** `ConceptNode` has `hierarchyLevel: Int` (0 = top theme, 1+ = sub-concept) and `expansionState`. Parent-child relationships use `subtopicOf` edges. `DensityManager` gates visibility: level-0 nodes always visible, sub-concepts shown only when a `subtopicOf` parent is expanded.

**Graph rendering** uses SwiftUI `Canvas` (not Metal). The `ForceDirectedLayout` runs Fruchterman-Reingold with group clustering by concept type and a post-process overlap resolution pass. Nodes are grouped visually with colored background regions. Scroll-to-zoom uses `ScrollWheelOverlay` (AppKit bridge) since SwiftUI Canvas doesn't expose scroll events natively.

**PDF ↔ Map communication** uses `NotificationCenter` posts (e.g., `"NavigateToPage"`) and closure callbacks (`onNavigateToPage`), not direct references between the two views.

**Multi-document extraction:** `KnowledgeGraph` tracks per-document `ProcessingState` via `documentProcessingState: [URL: ProcessingState]`. The `ProjectCorrelationSidebar` provides per-document and batch "Analyze All" extraction triggers for projects with multiple PDFs.

## Key Gotchas

- **PDFKit is not thread-safe.** All PDFKit calls (page access, text extraction, drawing) must happen on the main thread. The page preload cache was moved off background queues for this reason.
- **`@Observable` vs `@ObservableObject`:** `KnowledgeGraph` and `AIServiceManager` use the new `@Observable` macro (injected with `.environment()`). The older managers use `@StateObject`/`@EnvironmentObject`. Don't mix them — `@ObservedObject` won't work with `@Observable` classes.
- **Don't duplicate `@Observable` instances.** If a Settings scene or sheet needs an `@Observable` object (e.g., `AIServiceManager`), pass the same instance from the environment — never create a second `@State private var` copy. Separate instances cause state divergence (Keychain writes succeed but in-memory `@Observable` notifications don't cross instances).
- **Use `SettingsLink`, not `NSApp.sendAction`.** SwiftUI does not support opening Settings programmatically via `NSApp.sendAction(Selector(("showSettingsWindow:")), ...)`. It logs `Please use SettingsLink for opening the Settings scene.` and does nothing. Use the `SettingsLink` view instead.
- **SwiftUI Canvas doesn't expose scroll wheel events.** For scroll-to-zoom on `Canvas`, you need an AppKit bridge (`NSViewRepresentable` wrapping an `NSView` that overrides `scrollWheel:`). See `ScrollWheelOverlay.swift`.
- **Debounce resize-driven work.** `SplitPaneContainer` drag, toolbar `GeometryReader`, and `PDFView.boundsDidChangeNotification` all fire on every frame during resize. Always debounce or throttle state updates triggered by continuous geometry/bounds changes.
- **Guard layout recomputation during drag.** Changing `selectedNodeID` during a node drag can invalidate `visibleNodes` → trigger `recomputeLayout()` → call `fitToContent()` which resets the viewport. Any code path that recomputes layout or calls `fitToContent` must check `isDraggingNode` first.
- **LLM JSON responses are often truncated.** `JSONRepair.cleanAndRepair()` handles this — always use it when parsing AI output. It closes unclosed strings/brackets and can recover partial concept arrays.
- **Gemini needs `responseMimeType: "application/json"`** in the generation config for structured output, plus a high `maxOutputTokens` (32768) to avoid truncation.
- **App Sandbox is enabled.** Network access requires the `com.apple.security.network.client` entitlement (already configured). File access uses security-scoped bookmarks.
- **Window uses `.hiddenTitleBar`** with `titlebarAppearsTransparent = true` and `fullSizeContentView`. The PDF toolbar sits in the title bar area. `PDFViewerView` has `.ignoresSafeArea(.container, edges: .top)`.
- **SourceKit diagnostics in Xcode console** about "Cannot find type X in scope" are SourceKit indexing noise for cross-file type resolution — they don't reflect actual build errors. Always verify with `xcodebuild`.

## Logging

Atlas uses `os.log` via `AtlasLogger` (subsystem `com.atlas.pdf`):
- `AtlasLogger.pipeline` — extraction pipeline steps
- `AtlasLogger.ai` — AI backend HTTP requests/responses/parsing
- `AtlasLogger.graph` — node/edge additions
- `AtlasLogger.ui` — map view lifecycle, layout computation
- `AtlasLogger.sync` — PDF ↔ map sync events

Filter Xcode console by `com.atlas.pdf` or look for prefixes like `[Step 1]`, `[Gemini]`, `[MapView]`, `[Graph]`.

## Persistence Locations

- Projects: `~/Library/Application Support/PDFViewer/projects.json`
- Knowledge graphs: `~/Library/Application Support/Atlas/graphs/<sha256>.json`
- AI response cache: `~/Library/Application Support/Atlas/cache/<sha256>.json`
- Recent files bookmarks: `UserDefaults` key `RecentPDFFilesBookmarks`
- AI preferences: `UserDefaults` keys `atlas.ai.backendType`, `atlas.ai.model`
- API keys: macOS Keychain service `com.atlas.apikey.<backend>`

## Session Handoff (docs/ folder)

The `docs/` folder is the persistent knowledge base for agent-to-agent handoffs. Context gets cleared frequently — this folder is how you regain orientation.

**On session start:**
1. Read `docs/STATUS.md` first — it has what was last done, what's next, and files touched.
2. Read any plan file referenced by STATUS.md (e.g., `docs/UX_FIXES_PLAN.md`) if picking up ongoing work.
3. `docs/TODO.md` is the master checklist with all items and their completion state.

**On session end:**
1. Update `docs/STATUS.md` with: what you changed, files modified, and what the next agent should do.
2. If you completed items, check them off in `docs/TODO.md`.
3. If you created a new plan for upcoming work, save it as a new file in `docs/` and reference it from STATUS.md.

**Rules:**
- Keep docs concise — enough for a new agent to pick up, not a novel.
- Plans go in `docs/` as standalone files (e.g., `docs/FEATURE_X_PLAN.md`).
- Never let STATUS.md go stale — it's the first thing the next agent reads.
