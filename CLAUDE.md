# Atlas — macOS PDF Knowledge Map App

## Architecture

3-pane app layout: Sidebar | PDF Viewer | Knowledge Map. The sidebar is rendered by `MultiDocumentView`; `SplitPaneContainer` is the **two-pane** PDF-Viewer / Knowledge-Map split, with a draggable divider (60/40 default, drag-clamped 25–85%). Pane modes: `pdfOnly`, `mapOnly`, `split`.

### Knowledge Graph Model (`Atlas/Models/`)
- `KnowledgeGraph`: `@Observable` class holding `nodes: [UUID: ConceptNode]`, `edges: [UUID: GraphEdge]`, `adjacency` map.
- `ConceptNode`: Has `level: NodeLevel` — one of `.document`, `.chapter`, `.concept`, `.entity` (the 4-level hierarchy). Hierarchy is expressed by `level` plus containment edges, not a parent pointer (`parentConceptID` was dropped in the 4-level migration). Each node has `sourceAnchors` pointing to exact PDF locations (page + bounding box + text snippet).
- 10 `ConceptType`s (concept, definition, theorem, example, claim, person, dataset, method, result, equation). 12 `EdgeType`s: 9 semantic (dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses) + 3 containment (containsChapter, containsConcept, containsEntity).
- 4 semantic zoom levels (`SemanticZoomLevel`), 1:1 with `NodeLevel`: `.document` → `.chapter` → `.concept` → `.entity`. `DensityManager` shows **only** the nodes whose `level` matches the active zoom — each tab is a strict single-level filter, not cumulative.

### Rendering (`Atlas/Renderer/`)
- `KnowledgeMapView`: SwiftUI container with search, zoom controls, detail panel overlay.
- `MapCanvasRenderer`: SwiftUI `Canvas` drawing group backgrounds → edges (quadratic curves) → nodes. Zoom-dependent detail: dots at <0.35x, boxes at 0.35-0.45x, labels at >0.45x, summaries at >0.7x.
- `ForceDirectedLayout`: Fruchterman-Reingold with hierarchical grouping. Entities attracted 3x toward parent concepts. 500 max iterations, temperature annealing, overlap resolution.
- `DensityManager`: Filters visible nodes per `SemanticZoomLevel`.
- `MapInteraction`: Pan, zoom (0.1-5.0x), node drag, hit testing, fit-to-content.

### AI Extraction (`Atlas/AI/`)
- `ExtractionPipeline`: Fast pipeline. Processes PDFs in 5-page batches. Extracts text → sends to LLM → parses JSON response into nodes/edges. Deduplicates across batches.
- `DeepExtractionPipeline`: 3-pass deeper extraction (facts → cluster/dedup → cross-reference). `ExtractionMode` (`.fast` / `.deep`) is stored in `@AppStorage("atlas.extraction.mode")`; the picker lives in `KnowledgeMapView`.
- `PromptTemplates`: Structured prompt requesting concepts (3-8), entities (1-5 per concept), edges, with exact `textSpan` quotes.
- `AIServiceManager`: Multi-backend support (Claude, OpenAI, Gemini, Ollama) via the `AtlasModel` protocol. API keys in Keychain, response caching via SHA256 hash.

### Annotations (`Atlas/Annotations/`)
- `AnnotationGeometry`: Pure-value module for annotation move/resize math. `DragHandle` enum (8 corner/edge handles + `.body`); `translated`, `resized`, and `handle(at:)` hit-test, with page-bounds + min-size clamping. Consumed by `.select` `AnnotationMode` in `PDFViewRepresentable.handleSelectPan` for body-drag-to-translate and corner/edge-drag-to-resize.
- `SelectionChromeOverlay` (embedded in `PDFViewRepresentable.swift`): NSView subview of `pdfView` that draws the 1pt accent outline + 8 filled handles for the current selection. Click-through (`hitTest -> nil`); invalidates on scale/page/scroll notifications.

### PDF-Map Sync (`Atlas/Sync/`)
- `BidirectionalSyncManager`: PDF scroll → updates `activeNodeID` on map. Map node click → jumps PDF to source page via `navigateToPDFPage` callback.
- `ScrollTracker`: Observes PDFKit page change notifications (debounced).
- `HighlightSyncBridge`: Manages Atlas-tagged PDF annotations (`atlas:{nodeID}`). Pulse animation (0.6 alpha, 800ms) on navigation.

### Persistence (`Atlas/Persistence/`)
- `GraphStore`: Per-document JSON in `~/Library/Application Support/Atlas/graphs/` (filename = SHA256 of URL). Debounced saves (1s).
- `GraphMergeEngine`: dormant. Cross-doc merging now goes through `KnowledgeGraph.node(matching:)` baseline plus the SCE/ETR experiments on feature branches. `MergeProposalView` is never instantiated.

### Other Key Files
- `MultiDocumentView.swift`: Tab management, sidebar sections (open docs, projects, recents), comparison mode.
- `ProjectsManager.swift` / `DocumentManager.swift`: Project and multi-tab document state.
- `PDFViewerView.swift`: PDFKit wrapper with annotation tools. Publishes toolbar state/actions via `PDFToolbarBridge` rather than rendering its own toolbar — the sidebar in `MultiDocumentView` reads the bridge and renders the PDF toolbar atop the "OPEN" tabs.
- `Atlas/UI/`: Settings, command palette, chat panel (`ChatPanelView` / `ChatViewModel`), first-run, search views, sidebar panels (`PDFOutlinePanel`, `AnnotationListPanel`). `PDFToolbarBridge` is the `@Observable` bridge between `PDFViewerView` and the sidebar toolbar. `MergeProposalView` and `ProjectCorrelationSidebar` are present but dormant (never instantiated; the `.projectCorrelations` sidebar slot renders `EmptyView()`).

## Build & Run
Xcode project at `pdf_app1/pdf_app1.xcodeproj`. macOS target.
