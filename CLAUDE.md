# Atlas — macOS PDF Knowledge Map App

## Architecture

3-pane layout (`SplitPaneContainer`): Sidebar | PDF Viewer | Knowledge Map, with a draggable divider (60/40 default split). Pane modes: `pdfOnly`, `mapOnly`, `split`.

### Knowledge Graph Model (`Atlas/Models/`)
- `KnowledgeGraph`: Observable class holding `nodes: [UUID: ConceptNode]`, `edges: [UUID: GraphEdge]`, `adjacency` map.
- `ConceptNode`: Has `level: NodeLevel` (`.concept` or `.entity`). Entities link to parent concepts via `parentConceptID`. Each node has `sourceAnchors` pointing to exact PDF locations (page + bounding box + text snippet).
- 10 `ConceptType`s (concept, definition, theorem, example, claim, person, dataset, method, result, equation). 10 `EdgeType`s (dependsOn, contradicts, exampleOf, defines, extends, cites, sameTopic, partOf, uses, containsEntity).
- 4 semantic zoom levels (`SemanticZoomLevel`): `.document` (1 node per PDF) → `.chapter` (concepts only) → `.concept` (concepts + expanded entities) → `.entity` (all nodes).

### Rendering (`Atlas/Renderer/`)
- `KnowledgeMapView`: SwiftUI container with search, zoom controls, detail panel overlay.
- `MapCanvasRenderer`: SwiftUI `Canvas` drawing group backgrounds → edges (quadratic curves) → nodes. Zoom-dependent detail: dots at <0.35x, boxes at 0.35-0.45x, labels at >0.45x, summaries at >0.7x.
- `ForceDirectedLayout`: Fruchterman-Reingold with hierarchical grouping. Entities attracted 3x toward parent concepts. 500 max iterations, temperature annealing, overlap resolution.
- `DensityManager`: Filters visible nodes per `SemanticZoomLevel`.
- `MapInteraction`: Pan, zoom (0.1-5.0x), node drag, hit testing, fit-to-content.

### AI Extraction (`Atlas/AI/`)
- `ExtractionPipeline`: Processes PDFs in 5-page batches. Extracts text → sends to LLM → parses JSON response into nodes/edges. Deduplicates across batches.
- `PromptTemplates`: Structured prompt requesting concepts (3-8), entities (1-5 per concept), edges, with exact `textSpan` quotes.
- `AIServiceManager`: Multi-backend support (Claude, OpenAI, Gemini, Ollama) via `AtlasModelProtocol`. API keys in Keychain, response caching via SHA256 hash.

### PDF-Map Sync (`Atlas/Sync/`)
- `BidirectionalSyncManager`: PDF scroll → updates `activeNodeID` on map. Map node click → jumps PDF to source page via `navigateToPDFPage` callback.
- `ScrollTracker`: Observes PDFKit page change notifications (debounced).
- `HighlightSyncBridge`: Manages Atlas-tagged PDF annotations (`atlas:{nodeID}`). Pulse animation (0.6 alpha, 800ms) on navigation.

### Persistence (`Atlas/Persistence/`)
- `GraphStore`: Per-document JSON in `~/Library/Application Support/Atlas/graphs/` (filename = SHA256 of URL). Debounced saves (1s). Also supports per-project graphs.
- `GraphMergeEngine`: Cross-document dedup via Levenshtein similarity (>0.5 threshold) + optional LLM semantic matching.

### Other Key Files
- `MultiDocumentView.swift`: Tab management, sidebar sections (open docs, projects, recents), comparison mode.
- `ProjectsManager.swift` / `DocumentManager.swift`: Project and multi-tab document state.
- `PDFViewerView.swift`: PDFKit wrapper with annotation tools.
- `Atlas/UI/`: Settings, command palette, merge proposals, first-run, search views.

## Build & Run
Xcode project at `pdf_app1/pdf_app1.xcodeproj`. macOS target.
