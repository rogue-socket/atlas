# SCE Xcode Manual QA Audit — Source Highlighting, Edges, Direction, Render Ergonomics

Date: 2026-06-06

## Scope

User ran the SCE cross-doc branch from Xcode against several PDFs and reported:

1. Source highlighting sometimes highlights the entire page.
2. There are 0 edges between document nodes.
3. There are only 3 visible edges between chapter nodes.
4. Some edge labels are directional but the map does not make direction clear; example: `aggregated`.
5. Source highlighting appears only on some pages of one document.
6. Switching tabs/rendering is slow.
7. Edge labels float too far from their edges.

Positive observation: graph quality is good, relation labels are useful, and the flows are easy to understand.

## Evidence Inspected

- Latest persisted graph files in the app container:
  - `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/8a77caea81d86430aaca38ee2edb21fc.json`
  - `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/231fcdfcff5bf5488ca7bc4ca15a3bf0.json`
  - `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/280ccd60933850eea57725cf5b1e90fd.json`
  - `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/52008720a539fb9fc4175ccdfd1efd64.json`
- These appear to be the Meridian Biofab sample set from around 15:43-15:49.
- Code paths inspected:
  - `ExtractionPipeline.findSourceAnchor`
  - `HighlightSyncBridge.applyPersistentHighlights`
  - `HighlightSyncBridge.findPassageRects`
  - `PDFViewerView` `.navigateToPage` handler
  - `MultiDocumentView` map source-link routing and highlight refresh
  - `ChapterEdgeAggregation`
  - `KnowledgeMapView.recomputeLayout`
  - `ForceDirectedLayout.computeLayout`
  - `MapCanvasRenderer.drawEdges` / `drawEdgeLabel`

Unified logs did not return useful recent SCE/render lines via `log show`, so this audit is based on persisted graph artifacts plus code inspection.

## Graph Artifact Summary

Across the four latest graph files, de-duplicated by node/edge id:

- Nodes: 163
  - document: 4
  - chapter: 11
  - concept: 30
  - entity: 118
- Edges: 289
  - `containsEntity`: 118
  - `sameTopic`: 46
  - `dependsOn`: 41
  - `containsConcept`: 30
  - `uses`: 17
  - `containsChapter`: 11
  - `extends`: 7
  - `partOf`: 7
  - `attributeOf`: 4
  - `processFor`: 3
  - `defines`: 3
  - `exampleOf`: 2
- Cross-document semantic edges found: 7
- Document-document edges found: 0
- Chapter-chapter edges found: 6 persisted total:
  - `sameTopic "aggregated"` Governance Metrics and Risks -> Compliance Control Programs
  - `sameTopic "aggregated"` Supply Chain And Governance -> Manufacturing Platform Operations
  - `dependsOn "aggregated"` Supply Chain And Governance -> Manufacturing Platform Operations
  - `dependsOn "aggregated"` Manufacturing Platform Operations -> Supply Chain And Governance
  - `sameTopic "aggregated"` Metrics and Operational Controls -> Company and People Profile
  - `uses "aggregated"` Metrics and Operational Controls -> Company and People Profile

Note: the user saw 3 visible chapter edges; the persisted graph has 6. The difference is likely due to zoom-level filtering, overlap, reciprocal edge overlap, label overlap, or selected graph view state.

## Finding 1 — Whole-page source highlights are caused by full-page fallback anchors

Status: confirmed.

The latest graph artifacts contain source anchors with exact full-page boxes:

- 15 zero-ish anchors: width or height is zero.
- 47 large-ish anchors: page-sized, near page-width, or otherwise large.
- 9 anchors are exactly `x=0, y=0, w=612, h=792`.

Examples of full-page anchors:

- `Service separation`
- `Disease foundation or nonprofit`
- `Extreme weather disruption`
- `Data quality inconsistency`
- `Chief Quality Officer authority`
- `Biosafety committees`
- `Continuity safeguards`
- `Meridian Trace fallback`
- `Investigation quality`

The root cause is explicit in `ExtractionPipeline.findSourceAnchor`: after exact block match and 30-character prefix block match fail, it searches page text; if the prefix is found anywhere on a page, it stores `page.bounds(for: .mediaBox)` as the source anchor bounding box. That persisted full-page box is then used directly by `HighlightSyncBridge.applyPersistentHighlights`, creating full-page persistent highlights.

Recommendation:

1. Stop persisting full-page bounds as a source anchor for text citations.
2. In the page-text fallback, use `HighlightSyncBridge.findPassageRects` or equivalent PDF selection logic to derive line-level rects.
3. If no rect can be derived, either:
   - store a source anchor with text/page only and no highlightable bounds, or
   - store a small page-top/source badge target, not the full media box.
4. Add a guard in persistent highlight application to skip zero-area and page-sized anchors unless the source type is explicitly page-level.

## Finding 2 — Source highlights appearing only in one document is likely a refresh-lifecycle gap

Status: likely, based on code.

`MultiDocumentView` refreshes persistent highlights only in this path:

- `.onChange(of: knowledgeGraph.nodeCount)`
- only for `documentManager.selectedDocument`

That means highlights are refreshed for whichever PDF is selected when graph node count changes. Already-open non-selected tabs may not receive persistent highlights when their source anchors arrive. A tab selected later may show no persistent highlights unless another node-count change or explicit refresh occurs.

The temporary source-link pulse path is better routed: `KnowledgeMapView` passes `sourceDocumentURL`, `MultiDocumentView` opens/selects the tab if needed, and `PDFViewerView` ignores navigation notifications for other documents. But persistent highlights are still selected-document-only.

Recommendation:

1. Refresh persistent highlights when a PDF tab becomes selected.
2. Refresh persistent highlights when a graph is loaded/merged for a document, not only when total node count changes.
3. Consider maintaining per-document highlight bridge state or explicitly refreshing every open document after extraction completes.
4. Add diagnostics: for each refresh, log document URL, nodes-in-doc, anchors-in-doc, skipped invalid anchors, added annotations, removed annotations.

## Finding 3 — 0 document-document edges is expected in the current model, but likely not what users expect

Status: confirmed by data and code.

The current four-level model creates document nodes and connects them to chapter nodes using `containsChapter`. There is no current pass that synthesizes document-document relationship edges. SCE typed edges connect current concepts/entities to prior concepts/entities via `instanceOf`, `attributeOf`, or `processFor`; they do not promote those relationships to document-level edges.

The persisted graph confirms:

- 4 document nodes
- 11 `containsChapter` edges
- 0 document-document edges
- 7 cross-document semantic edges, all below document level

Recommendation:

1. Treat this as a product/design gap, not an extraction failure.
2. Add a document-level aggregation pass that summarizes cross-document semantic edges:
   - Source document A -> target document B
   - Edge label based on dominant underlying relation, e.g. `shares manufacturing controls`, `depends on quality controls`, or `related via 7 concepts`
   - Store provenance count and sample child edges for drilldown.
3. Keep document-document edges visually subtle at Document zoom to avoid implying that the LLM directly extracted a document-level relation.

## Finding 4 — Low chapter edge count is partly by design and partly an aggregation limitation

Status: confirmed.

`ChapterEdgeAggregation` only synthesizes chapter edges from non-containment concept-to-concept edges. It ignores:

- entity-entity edges,
- entity-concept edges,
- concept-entity edges,
- SCE typed edges that are below concept level,
- any relationship whose concepts are not attached to chapters.

In the inspected graph:

- There are 46 `sameTopic` edges and 41 `dependsOn` edges overall.
- Many useful relations are entity-entity or entity-concept.
- Only 6 chapter-chapter edges persisted.

This explains why the Chapter tab can still feel under-connected even though the concept/entity graph is good.

Recommendation:

1. Expand chapter aggregation to include entity-level relationships by walking entity -> parent concept -> parent chapter.
2. Aggregate edge counts and sample labels per chapter pair.
3. Prefer stronger chapter labels than the generic `"aggregated"`, such as:
   - `aggregates 4 manufacturing dependencies`
   - `rolls up: depends on`
   - `from 3 concept/entity links`
4. Add a chapter-edge inspector/drilldown showing the child edges that caused the aggregate.

## Finding 5 — Direction is present technically, but weak visually and semantically

Status: confirmed.

`MapCanvasRenderer` draws arrowheads from source to target. However:

- Edge labels show only `edge.displayText`, not source/target direction.
- The selected-node Connections panel lists relation text plus the other node label, but does not show whether the selected node is source or target.
- Aggregated chapter edges all use label `"aggregated"`, which is not semantically directional.
- Reciprocal edges can exist, e.g. `dependsOn "aggregated"` in both directions between the same chapter pair, which makes direction harder to interpret.

Recommendation:

1. In the side panel, show direction explicitly:
   - outgoing: `This node -> requires -> Other`
   - incoming: `Other -> requires -> This node`
2. In edge labels, use compact directional rendering at high zoom/selection:
   - `A -> requires -> B`
   - or `requires ->` / `<- requires` relative to selected node.
3. Replace generic aggregate labels with directional summaries.
4. For reciprocal edges, offset curves and labels differently, or collapse reciprocal aggregate edges into a bidirectional presentation with two relation chips.

## Finding 6 — Edge labels float away because labels are drawn at the curve control point

Status: confirmed.

`MapCanvasRenderer.drawEdges` computes a quadratic curve with a control point:

- `ctrl = midpoint + perpendicular offset`

Then it draws the edge label at `ctrl`.

For a quadratic Bezier, the curve does not pass through the control point. At t=0.5, the actual curve point is halfway between the line midpoint and the control point. Therefore, drawing the label at `ctrl` places the label outside the actual curve, especially for long or highly curved edges.

Recommendation:

1. Place labels at the actual Bezier midpoint:
   - `B(0.5) = 0.25 * src + 0.5 * ctrl + 0.25 * tgt`
2. Offset the label slightly normal to the curve only enough to avoid covering the line.
3. Draw a small leader/tick from label to curve for dense views.
4. Hide most labels at lower zoom; show labels for selected/hovered edges and nearby edges.

## Finding 7 — Slow tab switching/rendering is plausibly caused by synchronous layout recomputation

Status: likely, based on code; needs profiling.

`KnowledgeMapView.recomputeLayout` runs synchronously in SwiftUI view update paths. It calls `ForceDirectedLayout.computeLayout`, which can run up to `AppConstants.layoutMaxIterations = 500` iterations. It is triggered by:

- `onAppear`
- node-count / zoom-level changes
- graph expansion changes
- expand/collapse-all buttons

The layout preserves positions for known nodes, which helps tab switches, but it still resets convergence and runs the force loop. For a graph of this size, even with Barnes-Hut above 100 nodes, this can be noticeable during tab switches or zoom changes.

Recommendation:

1. Add timing logs around `recomputeLayout` and `computeLayout` first.
2. Skip recompute on tab switch if:
   - node IDs are unchanged,
   - zoom level unchanged,
   - canvas size approximately unchanged,
   - expansion generation unchanged.
3. Cache layout by `(visible node IDs, zoom level, canvas bucket, expansion generation)`.
4. Consider lowering iterations for recompute-after-tab-switch or doing incremental relaxation only.
5. Move heavy layout computation off the main actor if feasible, then publish positions back.

## Priority Order

Recommended implementation order:

1. Source highlight correctness:
   - stop full-page fallback anchors,
   - skip invalid/page-sized persistent anchors,
   - refresh highlights on tab selection.
2. Edge label placement:
   - use actual curve midpoint,
   - add selected-edge direction in panel.
3. Chapter/document aggregation semantics:
   - add document-document rollup edges,
   - improve chapter aggregation from entity-level relations,
   - replace generic `"aggregated"` label.
4. Render performance:
   - instrument first,
   - cache/skip redundant recompute,
   - then optimize layout loop if profiling confirms it.

## Open Questions

- Was the run performed in Fast or Deep extraction mode? This affects whether `ChapterEdgeAggregation.synthesize` was called in the same way.
- Were all four source PDFs open as tabs when highlights appeared only in one document?
- Did the user observe missing persistent highlights, missing temporary pulse highlights after clicking Sources, or both?
- Which zoom level showed only 3 chapter edges? Persisted graph has 6 chapter-chapter edges, so the view state matters.
