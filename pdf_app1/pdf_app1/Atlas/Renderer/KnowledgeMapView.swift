//
//  KnowledgeMapView.swift
//  Atlas
//
//  Knowledge map panel with search, filtering, grouping, and PDF source linking.
//

import SwiftUI
import PDFKit
import os.log

private let log = AtlasLogger.ui

private struct LayoutKey: Equatable {
    let nodeCount: Int
    let zoomLevel: SemanticZoomLevel
}

struct KnowledgeMapView: View {
    var graph: KnowledgeGraph
    @Binding var zoomLevel: SemanticZoomLevel
    let documentURL: URL?

    @State private var layout = ForceDirectedLayout()
    @State private var interaction = MapInteraction()
    @State private var densityManager = DensityManager()
    @State private var hasComputedLayout = false
    @Environment(AIServiceManager.self) private var aiService
    @State private var pipeline = ExtractionPipeline()

    // Extraction mode
    @AppStorage("atlas.extraction.mode") private var selectedModeRaw: String = ExtractionMode.fast.rawValue
    @State private var showModePicker = false

    private var selectedMode: ExtractionMode {
        ExtractionMode(rawValue: selectedModeRaw) ?? .fast
    }

    // Search — `searchQuery` is bound to the TextField (immediate).
    // `debouncedSearchQuery` lags by 250ms (or applies instantly when
    // the field is cleared) and drives the actual filter computation.
    // `filteredNodeIDs` is recomputed only when the debounced query
    // or the graph changes, not on every body evaluation.
    @State private var searchQuery = ""
    @State private var debouncedSearchQuery = ""
    @State private var filteredNodeIDs: Set<UUID> = []
    @State private var showSearch = false

    // Node detail popover
    @State private var popoverNodeID: UUID?

    // Cached filtered graph to avoid recomputation on every body evaluation
    @State private var cachedFilteredGraph: KnowledgeGraph?

    // Callback to navigate PDF (set by parent). Source document URL is
    // first so the parent can route to the right tab when the clicked
    // node's source isn't the currently-visible PDF.
    var onNavigateToPage: ((URL, Int, CGRect?, String?) -> Void)?
    // Active node from bidirectional sync (set by parent)
    var activeNodeID: UUID?

    private func rerunSearchFilter() {
        guard !debouncedSearchQuery.isEmpty else {
            if !filteredNodeIDs.isEmpty { filteredNodeIDs = [] }
            return
        }
        let q = debouncedSearchQuery.lowercased()
        filteredNodeIDs = Set(graph.allNodes.filter {
            $0.label.lowercased().contains(q) ||
            ($0.summary?.lowercased().contains(q) ?? false) ||
            $0.type.displayName.lowercased().contains(q)
        }.map(\.id))
    }

    private var visibleNodes: [ConceptNode] {
        densityManager.visibleNodes(from: graph, zoomLevel: zoomLevel)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .controlBackgroundColor)

                if graph.nodeCount == 0 {
                    emptyState
                } else {
                    // Map canvas
                    MapCanvasRenderer(
                        graph: cachedFilteredGraph ?? graph,
                        layout: layout,
                        zoomLevel: $zoomLevel,
                        selectedNodeID: $interaction.selectedNodeID,
                        activeNodeID: activeNodeID,
                        highlightedNodeIDs: filteredNodeIDs,
                        viewScale: interaction.viewScale,
                        viewOffset: interaction.viewOffset
                    )
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                interaction.handleMagnificationChanged(value.magnification)
                            }
                            .onEnded { _ in
                                interaction.handleMagnificationEnded()
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if !interaction.isDragging {
                                    interaction.handleDragStart(at: value.startLocation, layout: layout, graph: graph)
                                }
                                interaction.handleDragChanged(translation: value.translation, layout: layout)
                            }
                            .onEnded { _ in
                                interaction.handleDragEnded()
                            }
                    )
                    .overlay {
                        ScrollWheelOverlay { deltaY, location in
                            interaction.handleScrollWheel(deltaY: deltaY, cursorLocation: location)
                        }
                    }
                    .onTapGesture { location in
                        interaction.handleClick(at: location, layout: layout, graph: graph)
                    }
                }
            }
            // Top: search + zoom levels
            .overlay(alignment: .top) {
                if graph.nodeCount > 0 {
                    topBar
                        .padding(8)
                }
            }
            // Right: zoom controls
            .overlay(alignment: .topTrailing) {
                if graph.nodeCount > 0 {
                    actionControls(canvasSize: geometry.size)
                        .padding(.top, 44)
                        .padding(.trailing, 8)
                }
            }
            // Bottom: processing indicator or scanned PDF banner
            .overlay(alignment: .bottom) {
                if pipeline.isProcessing {
                    processingIndicator
                        .padding(8)
                } else if pipeline.scannedPDFDetected && graph.nodeCount == 0 {
                    scannedPDFBanner
                        .padding(8)
                }
            }
            // Bottom-left: selected node detail
            .overlay(alignment: .bottomLeading) {
                if let nodeID = interaction.selectedNodeID, let node = graph.node(for: nodeID) {
                    selectedNodeDetail(node)
                        .padding(8)
                }
            }
            // Single onChange keyed on (nodeCount, zoomLevel) so a simultaneous
            // change of both — e.g. user taps zoom while extraction adds
            // nodes — triggers one layout recompute, not two back-to-back.
            // `fitToContent` only runs when zoom actually changed (matches
            // the prior split-handler behavior).
            .onChange(of: LayoutKey(nodeCount: graph.nodeCount, zoomLevel: zoomLevel)) { oldKey, newKey in
                log.info("[MapView] layout key changed: nodeCount=\(newKey.nodeCount), zoomLevel=\(String(describing: newKey.zoomLevel))")
                if newKey.nodeCount > 0 && !interaction.isDragging {
                    recomputeLayout(canvasSize: geometry.size)
                    if oldKey.zoomLevel != newKey.zoomLevel {
                        interaction.fitToContent(
                            layout: layout,
                            canvasSize: geometry.size,
                            visibleIDs: Set(visibleNodes.map(\.id))
                        )
                    }
                }
                if oldKey.nodeCount != newKey.nodeCount && !debouncedSearchQuery.isEmpty {
                    rerunSearchFilter()
                }
            }
            .task(id: searchQuery) {
                if searchQuery.isEmpty {
                    debouncedSearchQuery = ""
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedSearchQuery = searchQuery
            }
            .onChange(of: debouncedSearchQuery) { _, _ in
                rerunSearchFilter()
            }
            .onChange(of: graph.expansionGeneration) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    recomputeLayout(canvasSize: geometry.size)
                }
            }
            .onAppear {
                if graph.nodeCount > 0 {
                    recomputeLayout(canvasSize: geometry.size)
                }
            }
        }
    }

    /// Build a filtered graph based on the current zoom level
    private var graphForCurrentZoom: KnowledgeGraph {
        let nodes = visibleNodes
        if nodes.count == graph.nodeCount { return graph }

        let filtered = KnowledgeGraph()
        let nodeIDs = Set(nodes.map(\.id))
        for node in nodes { filtered.addNode(node) }
        for edge in graph.allEdges {
            if nodeIDs.contains(edge.sourceNodeID) && nodeIDs.contains(edge.targetNodeID) {
                filtered.addEdge(edge)
            }
        }
        return filtered
    }

    private func recomputeLayout(canvasSize: CGSize) {
        let nodes = visibleNodes
        let nodeIDs = Set(nodes.map(\.id))
        let edges = graph.allEdges.filter { nodeIDs.contains($0.sourceNodeID) && nodeIDs.contains($0.targetNodeID) }
        // `validNodeIDs` is the FULL graph's node IDs so FDL doesn't evict
        // positions for off-tab nodes — tab switches restore the prior
        // layout instead of reshuffling from a fresh seed.
        let allIDs = Set(graph.allNodes.map(\.id))
        layout.computeLayout(nodes: nodes, edges: edges, canvasSize: canvasSize, validNodeIDs: allIDs)

        cachedFilteredGraph = graphForCurrentZoom

        if !hasComputedLayout {
            interaction.fitToContent(layout: layout, canvasSize: canvasSize, visibleIDs: nodeIDs)
            hasComputedLayout = true
        }
    }

    // MARK: - Top Bar (search + zoom levels)

    private var topBar: some View {
        HStack(spacing: 6) {
            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Search concepts...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .frame(maxWidth: 200)

            if !searchQuery.isEmpty && !filteredNodeIDs.isEmpty {
                Text("\(filteredNodeIDs.count) found")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Zoom levels
            ForEach(SemanticZoomLevel.allCases, id: \.self) { level in
                Button(action: { zoomLevel = level }) {
                    Text(level.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(zoomLevel == level ? Color.accentColor.opacity(0.2) : Color.clear)
                        )
                        .foregroundColor(zoomLevel == level ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
    }

    // MARK: - Action Controls

    private func actionControls(canvasSize: CGSize) -> some View {
        VStack(spacing: 4) {
            Button(action: { interaction.zoomIn() }) { Image(systemName: "plus.magnifyingglass") }
            Button(action: { interaction.zoomOut() }) { Image(systemName: "minus.magnifyingglass") }
            Button(action: {
                interaction.fitToContent(
                    layout: layout,
                    canvasSize: canvasSize,
                    visibleIDs: Set(visibleNodes.map(\.id))
                )
            }) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Fit All")

            Divider().frame(width: 16)
            Button(action: {
                graph.expandAll()
                if let geo = NSApplication.shared.keyWindow?.contentView?.bounds.size {
                    recomputeLayout(canvasSize: geo)
                }
            }) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .help("Expand All")
            Button(action: {
                graph.collapseAll()
                if let geo = NSApplication.shared.keyWindow?.contentView?.bounds.size {
                    recomputeLayout(canvasSize: geo)
                }
            }) { Image(systemName: "arrow.up.left.and.arrow.down.right.circle") }
                .help("Collapse All")

            if documentURL != nil && aiService.isConfigured {
                Divider().frame(width: 16)
                Button(action: { showModePicker.toggle() }) { Image(systemName: "brain") }
                    .help("Analyze Document")
                    .disabled(pipeline.isProcessing)
                    .popover(isPresented: $showModePicker, arrowEdge: .leading) {
                        modePickerPopover
                    }
            }
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
    }

    // MARK: - Selected Node Detail Panel

    private func selectedNodeDetail(_ node: ConceptNode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(node.type.color)
                    .frame(width: 3, height: 16)
                Text(node.label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(node.type.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(node.type.color.opacity(0.15)))
                    .foregroundColor(node.type.color)

                Button(action: { interaction.selectedNodeID = nil }) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Summary
            if let summary = node.summary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            // Source links
            if !node.sourceAnchors.isEmpty {
                Divider()
                Text("Sources")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(node.sourceAnchors.prefix(3)) { anchor in
                    Button(action: {
                        log.info("[MapView] Navigate to page \(anchor.pageIndex + 1)")
                        onNavigateToPage?(anchor.documentURL, anchor.pageIndex, anchor.boundingBox, anchor.textSnippet)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.doc")
                                .font(.caption2)
                                .foregroundColor(.blue)
                            Text("\(anchor.documentURL.lastPathComponent) — Page \(anchor.pageIndex + 1)")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Connected edges
            let edges = graph.edges(for: node.id)
            if !edges.isEmpty {
                Divider()
                Text("Connections (\(edges.count))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(edges.prefix(5)) { edge in
                    let otherID = edge.sourceNodeID == node.id ? edge.targetNodeID : edge.sourceNodeID
                    if let other = graph.node(for: otherID) {
                        HStack(spacing: 4) {
                            Circle().fill(edge.type.color).frame(width: 5, height: 5)
                            Text(edge.type.displayName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(other.label)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 300)
        .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThickMaterial))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Knowledge Map")
                .font(.title2)
                .foregroundColor(.secondary)
            if documentURL != nil {
                if aiService.isConfigured {
                    Text("Click \"Analyze Document\" to extract concepts.")
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("Analyze Document") { showModePicker.toggle() }
                        .buttonStyle(.borderedProminent)
                        .popover(isPresented: $showModePicker, arrowEdge: .bottom) {
                            modePickerPopover
                        }
                } else {
                    Text("Configure an AI backend in Settings > AI to analyze documents.")
                        .font(.callout)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    SettingsLink {
                        Text("Open Settings")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Open a PDF to see its knowledge map.")
                    .font(.callout)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }

    // MARK: - Processing Indicator

    private var processingIndicator: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: pipeline.progress)
                    .frame(width: 200)

                HStack {
                    Text(pipeline.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if pipeline.totalPages > 0 {
                        Text("\(pipeline.currentPage + 1)/\(pipeline.totalPages) pages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Button("Cancel") {
                pipeline.cancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    // MARK: - Scanned PDF Banner

    private var scannedPDFBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title3)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Scanned PDF Detected")
                    .font(.caption.bold())
                Text("This PDF appears to be scanned or image-only. No text could be extracted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Run OCR") {
                startExtraction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
    }

    // MARK: - Mode Picker

    private var modePickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extraction Mode")
                .font(.headline)

            ForEach(ExtractionMode.allCases, id: \.self) { mode in
                Button(action: {
                    selectedModeRaw = mode.rawValue
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedMode == mode ? .accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(mode.displayName)
                                    .fontWeight(.medium)
                                if !mode.isAvailable {
                                    Text("Coming Soon")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(.secondary.opacity(0.2)))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Text(mode.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!mode.isAvailable)
            }

            Divider()

            Button(action: {
                showModePicker = false
                startExtraction()
            }) {
                Text("Analyze")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!selectedMode.isAvailable)
        }
        .padding(12)
        .frame(width: 240)
    }

    // MARK: - Actions

    private func startExtraction() {
        guard let url = documentURL else { return }
        guard let document = PDFDocument(url: url) else { return }
        log.info("[MapView] startExtraction: \(url.lastPathComponent), \(document.pageCount) pages, mode=\(selectedMode.rawValue)")
        pipeline.processFullDocument(document: document, documentURL: url, graph: graph, aiService: aiService, mode: selectedMode)
    }
}
