//
//  KnowledgeMapView.swift
//  Atlas
//
//  Knowledge map panel with search, filtering, grouping, and PDF source linking.
//

import SwiftUI
import AppKit
import PDFKit
import os.log
import UniformTypeIdentifiers

private let log = AtlasLogger.ui

private struct LayoutKey: Equatable {
    let nodeSignatures: [String]
    let edgeSignatures: [String]
    let zoomLevel: SemanticZoomLevel

    var nodeCount: Int { nodeSignatures.count }
}

private struct GuidedTourFocus: Equatable {
    let nodeID: UUID
    let title: String
    let narration: String
    let linearIndex: Int?
}

private struct GuidedTourChoice: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let destination: GuidedTourFocus
}

struct MapLayoutComputationKey: Equatable {
    let nodeSignatures: [String]
    let edgeSignatures: [String]
    let zoomLevel: SemanticZoomLevel
    let canvasBucket: CGSize
    let expansionGeneration: Int
}

struct KnowledgeMapView: View {
    var graph: KnowledgeGraph
    @Binding var zoomLevel: SemanticZoomLevel
    let documentURL: URL?

    @State private var layout = ForceDirectedLayout()
    @State private var interaction = MapInteraction()
    @State private var densityManager = DensityManager()
    @State private var hasComputedLayout = false
    @State private var lastLayoutComputationKey: MapLayoutComputationKey?
    @Environment(AIServiceManager.self) private var aiService
    @State private var pipeline = ExtractionPipeline()

    // Extraction mode
    @AppStorage("atlas.extraction.mode") private var selectedModeRaw: String = ExtractionMode.fast.rawValue
    @State private var showModePicker = false
    @State private var exportErrorMessage: String?

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

    @State private var cachedRenderCache: MapCanvasRenderer.RenderCache = .empty
    @State private var isTourVisible = false
    @State private var isTourIntroVisible = false
    @State private var tourStopIndex = 0
    @State private var tourFocus: GuidedTourFocus?
    @State private var tourBackStack: [GuidedTourFocus] = []
    @State private var speechSynthesizer = NSSpeechSynthesizer()
    @AppStorage("atlas.guidedTour.voice.enabled") private var isTourVoiceEnabled = true

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
        filteredNodeIDs = Set(Self.searchResults(in: graph, query: debouncedSearchQuery).map(\.id))
    }

    private var visibleNodes: [ConceptNode] {
        densityManager.visibleNodesIncludingRelationshipContext(from: graph, zoomLevel: zoomLevel)
    }

    private var visibleSearchResults: [ConceptNode] {
        Self.searchResults(in: graph, query: searchQuery)
    }

    private var activeTour: GuidedTour? {
        graph.guidedTour(for: documentURL)
    }

    private var activeTourFocus: GuidedTourFocus? {
        if let tourFocus {
            return tourFocus
        }
        guard let tour = activeTour,
              tour.stops.indices.contains(tourStopIndex) else { return nil }
        return Self.focus(for: tour.stops[tourStopIndex], index: tourStopIndex)
    }

    private var highlightedNodeIDs: Set<UUID> {
        var ids = filteredNodeIDs
        if isTourVisible, !isTourIntroVisible, let focus = activeTourFocus {
            ids.insert(focus.nodeID)
        }
        return ids
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
                        layout: layout,
                        zoomLevel: $zoomLevel,
                        selectedNodeID: $interaction.selectedNodeID,
                        activeNodeID: activeNodeID,
                        highlightedNodeIDs: highlightedNodeIDs,
                        viewScale: interaction.viewScale,
                        viewOffset: interaction.viewOffset,
                        renderCache: cachedRenderCache
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
                    topBar(canvasSize: geometry.size)
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
                } else if isTourVisible, let tour = activeTour {
                    if isTourIntroVisible {
                        guidedTourIntroOverlay(tour: tour, canvasSize: geometry.size)
                            .padding(8)
                    } else if let focus = activeTourFocus {
                        guidedTourOverlay(tour: tour, focus: focus, canvasSize: geometry.size)
                            .padding(8)
                    }
                } else if pipeline.scannedPDFDetected && graph.nodeCount == 0 {
                    scannedPDFBanner
                        .padding(8)
                }
            }
            // Bottom-left: selected node detail
            .overlay(alignment: .bottomLeading) {
                if !isTourVisible,
                   let nodeID = interaction.selectedNodeID,
                   let node = graph.node(for: nodeID) {
                    selectedNodeDetail(node)
                        .padding(8)
                }
            }
            // Single onChange keyed on graph shape + zoom so a simultaneous
            // graph/zoom change triggers one layout recompute, not multiple
            // back-to-back calls. The recompute path has its own canvas-aware
            // cache key and skips unchanged layouts.
            // `fitToContent` only runs when zoom actually changed (matches
            // the prior split-handler behavior).
            .onChange(of: layoutKey(zoomLevel: zoomLevel)) { oldKey, newKey in
                log.info("[MapView] layout key changed: nodeCount=\(newKey.nodeCount), edgeCount=\(newKey.edgeSignatures.count), zoomLevel=\(String(describing: newKey.zoomLevel))")
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
                if oldKey.nodeSignatures != newKey.nodeSignatures && !debouncedSearchQuery.isEmpty {
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
            .onChange(of: activeTour?.id) { _, newID in
                if newID == nil {
                    finishTour()
                }
            }
            .onChange(of: isTourVoiceEnabled) { _, enabled in
                if enabled {
                    speakCurrentTourText()
                } else {
                    stopTourSpeech()
                }
            }
            .alert("Export Failed", isPresented: exportErrorPresented) {
                Button("OK", role: .cancel) { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
        }
    }

    private func filteredGraph(for nodes: [ConceptNode]) -> KnowledgeGraph {
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

    private func layoutKey(zoomLevel: SemanticZoomLevel) -> LayoutKey {
        LayoutKey(
            nodeSignatures: graph.allNodes.map { Self.nodeSignature($0) }.sorted(),
            edgeSignatures: graph.allEdges.map { Self.edgeSignature($0) }.sorted(),
            zoomLevel: zoomLevel
        )
    }

    private func recomputeLayout(canvasSize: CGSize, zoomOverride: SemanticZoomLevel? = nil) {
        let startedAt = Date()
        let effectiveZoomLevel = zoomOverride ?? zoomLevel
        let nodes = densityManager.visibleNodesIncludingRelationshipContext(from: graph, zoomLevel: effectiveZoomLevel)
        let nodeIDs = Set(nodes.map(\.id))
        let edges = graph.allEdges.filter { nodeIDs.contains($0.sourceNodeID) && nodeIDs.contains($0.targetNodeID) }
        let key = Self.layoutComputationKey(
            nodes: nodes,
            edges: edges,
            zoomLevel: effectiveZoomLevel,
            canvasSize: canvasSize,
            expansionGeneration: graph.expansionGeneration
        )
        if hasComputedLayout && lastLayoutComputationKey == key {
            log.debug("[MapView] recomputeLayout skipped unchanged key nodes=\(nodes.count) edges=\(edges.count) zoom=\(String(describing: effectiveZoomLevel)) bucket=\(Int(key.canvasBucket.width))x\(Int(key.canvasBucket.height))")
            return
        }

        // `validNodeIDs` is the FULL graph's node IDs so FDL doesn't evict
        // positions for off-tab nodes — tab switches restore the prior
        // layout instead of reshuffling from a fresh seed.
        let allIDs = Set(graph.allNodes.map(\.id))
        layout.computeLayout(nodes: nodes, edges: edges, canvasSize: canvasSize, validNodeIDs: allIDs)
        lastLayoutComputationKey = key

        cachedRenderCache = MapCanvasRenderer.makeRenderCache(for: filteredGraph(for: nodes))

        if !hasComputedLayout {
            interaction.fitToContent(layout: layout, canvasSize: canvasSize, visibleIDs: nodeIDs)
            hasComputedLayout = true
        }
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        log.info("[MapView] recomputeLayout completed nodes=\(nodes.count) edges=\(edges.count) zoom=\(String(describing: effectiveZoomLevel)) bucket=\(Int(key.canvasBucket.width))x\(Int(key.canvasBucket.height)) iterations=\(self.layout.iteration) elapsed_ms=\(elapsedMS)")
    }

    static func layoutComputationKey(
        nodes: [ConceptNode],
        edges: [GraphEdge],
        zoomLevel: SemanticZoomLevel,
        canvasSize: CGSize,
        expansionGeneration: Int
    ) -> MapLayoutComputationKey {
        MapLayoutComputationKey(
            nodeSignatures: nodes.map { Self.nodeSignature($0) }.sorted(),
            edgeSignatures: edges.map { Self.edgeSignature($0) }.sorted(),
            zoomLevel: zoomLevel,
            canvasBucket: canvasBucket(for: canvasSize),
            expansionGeneration: expansionGeneration
        )
    }

    static func layoutComputationKey(
        nodeIDs: Set<UUID>,
        edges: [GraphEdge],
        zoomLevel: SemanticZoomLevel,
        canvasSize: CGSize,
        expansionGeneration: Int
    ) -> MapLayoutComputationKey {
        MapLayoutComputationKey(
            nodeSignatures: nodeIDs.map(\.uuidString).sorted(),
            edgeSignatures: edges.map { Self.edgeSignature($0) }.sorted(),
            zoomLevel: zoomLevel,
            canvasBucket: canvasBucket(for: canvasSize),
            expansionGeneration: expansionGeneration
        )
    }

    static func nodeSignature(_ node: ConceptNode) -> String {
        [
            node.id.uuidString,
            node.level.rawValue
        ].joined(separator: "|")
    }

    static func searchResults(in graph: KnowledgeGraph, query: String, limit: Int = 8) -> [ConceptNode] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        return graph.allNodes.compactMap { node -> (node: ConceptNode, rank: Int)? in
            let label = node.label.lowercased()
            let summary = node.summary?.lowercased() ?? ""
            let type = node.type.displayName.lowercased()

            if label == q { return (node, 0) }
            if label.hasPrefix(q) { return (node, 1) }
            if label.contains(q) { return (node, 2) }
            if type.contains(q) { return (node, 3) }
            if summary.contains(q) { return (node, 4) }
            return nil
        }
        .sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return $0.node.label.localizedStandardCompare($1.node.label) == .orderedAscending
        }
        .prefix(limit)
        .map(\.node)
    }

    static func zoomLevel(for nodeLevel: NodeLevel) -> SemanticZoomLevel {
        switch nodeLevel {
        case .document: return .document
        case .chapter: return .chapter
        case .concept: return .concept
        case .entity: return .entity
        }
    }

    static func edgeSignature(_ edge: GraphEdge) -> String {
        [
            edge.id.uuidString,
            edge.sourceNodeID.uuidString,
            edge.targetNodeID.uuidString,
            edge.type.rawValue,
            edge.label ?? ""
        ].joined(separator: "|")
    }

    static func canvasBucket(for canvasSize: CGSize) -> CGSize {
        let bucketSize: CGFloat = 64
        return CGSize(
            width: (canvasSize.width / bucketSize).rounded() * bucketSize,
            height: (canvasSize.height / bucketSize).rounded() * bucketSize
        )
    }

    // MARK: - Top Bar (search + zoom levels)

    private func topBar(canvasSize: CGSize) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Search concepts...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit {
                            if let first = visibleSearchResults.first {
                                selectSearchResult(first, canvasSize: canvasSize)
                            }
                        }
                    if !searchQuery.isEmpty {
                        Button(action: {
                            searchQuery = ""
                            debouncedSearchQuery = ""
                            filteredNodeIDs = []
                        }) {
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
                .frame(width: 200)

                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResultsList(canvasSize: canvasSize)
                }
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

    private func searchResultsList(canvasSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if visibleSearchResults.isEmpty {
                Text("No matches")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(visibleSearchResults, id: \.id) { node in
                    Button {
                        selectSearchResult(node, canvasSize: canvasSize)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: node.type.icon)
                                .font(.caption2)
                                .foregroundColor(node.type.color)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                                Text(node.level.rawValue.capitalized)
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
    }

    private func selectSearchResult(_ node: ConceptNode, canvasSize: CGSize) {
        graph.expandAncestors(of: node.id)
        let targetZoomLevel = Self.zoomLevel(for: node.level)
        zoomLevel = targetZoomLevel
        recomputeLayout(canvasSize: canvasSize, zoomOverride: targetZoomLevel)
        interaction.center(on: node.id, layout: layout, canvasSize: canvasSize)
        filteredNodeIDs = [node.id]
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

            Divider().frame(width: 16)
            Menu {
                Button("Obsidian") { exportGraph(format: .obsidian) }
                Button("Markdown") { exportGraph(format: .markdown) }
                Button("JSON") { exportGraph(format: .json) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .help("Export Knowledge Map")

            if documentURL != nil && aiService.isConfigured {
                Divider().frame(width: 16)
                Button(action: { showModePicker.toggle() }) { Image(systemName: "brain") }
                    .help("Analyze Document")
                    .disabled(pipeline.isProcessing)
                    .popover(isPresented: $showModePicker, arrowEdge: .leading) {
                        modePickerPopover
                    }
            }

            if let tour = activeTour, !tour.stops.isEmpty {
                Divider().frame(width: 16)
                Button(action: { startTour(canvasSize: canvasSize) }) {
                    Image(systemName: isTourVisible ? "arrow.clockwise.circle" : "play.circle")
                }
                .help(isTourVisible ? "Replay Guided Tour" : "Start Guided Tour")
            }
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.ultraThinMaterial))
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )
    }

    private var exportProjectName: String {
        let name = documentURL?.deletingPathExtension().lastPathComponent ?? "Atlas Export"
        return name.isEmpty ? "Atlas Export" : name
    }

    private func exportGraph(format: ExportManager.ExportFormat) {
        let content = ExportManager().export(graph: graph, format: format, projectName: exportProjectName)
        let panel = NSSavePanel()
        panel.title = "Export Knowledge Map"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(exportProjectName).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("[MapView] export failed: \(error.localizedDescription)")
                exportErrorMessage = "Could not write \(url.lastPathComponent)."
            }
        }
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

            // Connected edges — only relational (non-containment) so the
            // panel matches the canvas, which deliberately skips containment
            // edges (those are implicit in the level-fold + cluster bbox).
            let allEdges = graph.edges(for: node.id)
            let relational = allEdges.filter { !$0.type.isContainment }
            let outgoingRelational = relational.filter { $0.sourceNodeID == node.id }
            let incomingRelational = relational.filter { $0.targetNodeID == node.id }
            let containment = allEdges.filter { $0.type.isContainment }

            if !relational.isEmpty {
                Divider()
                Text("Connections (\(relational.count))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                relationshipRows(
                    title: "Outgoing",
                    edges: outgoingRelational,
                    isOutgoing: true
                )
                relationshipRows(
                    title: "Incoming",
                    edges: incomingRelational,
                    isOutgoing: false
                )
            }

            // Hierarchy — containment edges surface here, labeled by
            // direction so users can see the fold relationships even
            // though they're not drawn as lines on the canvas.
            if !containment.isEmpty {
                Divider()
                Text("Hierarchy (\(containment.count))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(containment.prefix(5)) { edge in
                    let isOutgoing = edge.sourceNodeID == node.id
                    let otherID = isOutgoing ? edge.targetNodeID : edge.sourceNodeID
                    if let other = graph.node(for: otherID) {
                        HStack(spacing: 4) {
                            Image(systemName: isOutgoing ? "arrow.down.right" : "arrow.up.left")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(isOutgoing ? "Contains" : "In")
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

    @ViewBuilder
    private func relationshipRows(
        title: String,
        edges: [GraphEdge],
        isOutgoing: Bool
    ) -> some View {
        if !edges.isEmpty {
            Text("\(title) (\(edges.count))")
                .font(.caption2)
                .foregroundColor(.secondary)

            ForEach(edges.prefix(5)) { edge in
                let otherID = isOutgoing ? edge.targetNodeID : edge.sourceNodeID
                if let other = graph.node(for: otherID) {
                    HStack(spacing: 4) {
                        Image(systemName: isOutgoing ? "arrow.right" : "arrow.left")
                            .font(.caption2)
                            .foregroundColor(edge.type.color)
                        Text(edgeDisplayText(edge))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Text(isOutgoing ? "to" : "from")
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

    private func edgeDisplayText(_ edge: GraphEdge) -> String {
        edge.displayText()
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

    // MARK: - Guided Tour

    private func startTour(canvasSize: CGSize) {
        guard let tour = activeTour, !tour.stops.isEmpty else { return }
        stopTourSpeech()
        tourStopIndex = 0
        tourFocus = nil
        tourBackStack = []
        isTourIntroVisible = true
        isTourVisible = true
        interaction.selectedNodeID = nil
        speakTourText(tourIntroduction(tour))
    }

    private func beginTourStops(tour: GuidedTour, canvasSize: CGSize) {
        guard let firstStop = tour.stops.first else { return }
        let focus = Self.focus(for: firstStop, index: 0)
        tourBackStack = []
        applyTourFocus(focus, canvasSize: canvasSize)
    }

    private func applyTourFocus(_ focus: GuidedTourFocus, canvasSize: CGSize) {
        guard let node = graph.node(for: focus.nodeID) else { return }
        isTourIntroVisible = false
        tourFocus = focus
        if let index = focus.linearIndex {
            tourStopIndex = index
        }
        graph.expandAncestors(of: node.id)
        let targetZoomLevel = Self.zoomLevel(for: node.level)
        zoomLevel = targetZoomLevel
        withAnimation(.easeInOut(duration: 0.35)) {
            recomputeLayout(canvasSize: canvasSize, zoomOverride: targetZoomLevel)
            interaction.center(on: node.id, layout: layout, canvasSize: canvasSize)
            interaction.selectedNodeID = node.id
        }
        speakTourText(focus.narration)
    }

    private func chooseTourDestination(_ destination: GuidedTourFocus, canvasSize: CGSize) {
        if let current = activeTourFocus {
            tourBackStack.append(current)
        }
        applyTourFocus(destination, canvasSize: canvasSize)
    }

    private func moveTourBack(canvasSize: CGSize) {
        guard let previous = tourBackStack.popLast() else { return }
        applyTourFocus(previous, canvasSize: canvasSize)
    }

    private func finishTour() {
        isTourVisible = false
        isTourIntroVisible = false
        tourStopIndex = 0
        tourFocus = nil
        tourBackStack = []
        stopTourSpeech()
    }

    private func guidedTourIntroOverlay(tour: GuidedTour, canvasSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided Tour")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Start Here")
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer()

                voiceToggle
            }

            Text(tourIntroduction(tour))
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Start Tour") {
                    beginTourStops(tour: tour, canvasSize: canvasSize)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Skip") {
                    finishTour()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: tourOverlayWidth(canvasSize))
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }

    private func guidedTourOverlay(tour: GuidedTour, focus: GuidedTourFocus, canvasSize: CGSize) -> some View {
        let choices = tourChoices(for: focus, in: tour)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Guided Tour")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(focus.title)
                        .font(.headline)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(progressText(for: focus, in: tour))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                    voiceToggle
                }
            }

            Text(focus.narration)
                .font(.callout)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !choices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(choices) { choice in
                        Button {
                            chooseTourDestination(choice.destination, canvasSize: canvasSize)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(choice.subtitle)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Button("Previous") {
                    moveTourBack(canvasSize: canvasSize)
                }
                .disabled(tourBackStack.isEmpty)

                Spacer()

                Button(choices.isEmpty ? "Done" : "Skip") {
                    finishTour()
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: tourOverlayWidth(canvasSize))
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
    }

    private var voiceToggle: some View {
        Button {
            isTourVoiceEnabled.toggle()
        } label: {
            Image(systemName: isTourVoiceEnabled ? "speaker.wave.2" : "speaker.slash")
        }
        .buttonStyle(.borderless)
        .help(isTourVoiceEnabled ? "Turn Tour Voice Off" : "Turn Tour Voice On")
    }

    private func tourChoices(for focus: GuidedTourFocus, in tour: GuidedTour) -> [GuidedTourChoice] {
        var choices: [GuidedTourChoice] = []
        var excluded = Set(tourBackStack.map(\.nodeID))
        excluded.insert(focus.nodeID)

        if let next = nextLogicalFocus(after: focus, in: tour) {
            choices.append(GuidedTourChoice(
                id: "next-\(next.nodeID.uuidString)",
                title: "Next logical step",
                subtitle: "Continue the generated learning path to \(next.title).",
                destination: next
            ))
            excluded.insert(next.nodeID)
        }

        let related = relatedTourDestinations(from: focus, excluding: excluded)
        for (offset, destination) in related.prefix(2).enumerated() {
            let label = offset == 0 ? "Explore A" : "Explore B"
            choices.append(GuidedTourChoice(
                id: "explore-\(offset)-\(destination.nodeID.uuidString)",
                title: "\(label): \(destination.title)",
                subtitle: destination.narration,
                destination: destination
            ))
        }

        return choices
    }

    private func nextLogicalFocus(after focus: GuidedTourFocus, in tour: GuidedTour) -> GuidedTourFocus? {
        let currentIndex = focus.linearIndex ?? tourStopIndex
        let nextIndex = currentIndex + 1
        guard tour.stops.indices.contains(nextIndex) else { return nil }
        return Self.focus(for: tour.stops[nextIndex], index: nextIndex)
    }

    private func relatedTourDestinations(
        from focus: GuidedTourFocus,
        excluding excluded: Set<UUID>
    ) -> [GuidedTourFocus] {
        graph.edges(for: focus.nodeID)
            .compactMap { edge -> (ConceptNode, GraphEdge)? in
                let otherID = edge.sourceNodeID == focus.nodeID ? edge.targetNodeID : edge.sourceNodeID
                guard !excluded.contains(otherID), let node = graph.node(for: otherID) else { return nil }
                return (node, edge)
            }
            .sorted { lhs, rhs in
                if lhs.1.type.isContainment != rhs.1.type.isContainment {
                    return !lhs.1.type.isContainment
                }
                if lhs.0.level != rhs.0.level {
                    return Self.tourSortRank(lhs.0.level) < Self.tourSortRank(rhs.0.level)
                }
                let leftDegree = graph.degree(of: lhs.0.id)
                let rightDegree = graph.degree(of: rhs.0.id)
                if leftDegree != rightDegree { return leftDegree > rightDegree }
                return lhs.0.label.localizedCaseInsensitiveCompare(rhs.0.label) == .orderedAscending
            }
            .reduce(into: [GuidedTourFocus]()) { result, pair in
                guard !result.contains(where: { $0.nodeID == pair.0.id }) else { return }
                result.append(exploreFocus(from: focus, to: pair.0, edge: pair.1))
            }
    }

    private func exploreFocus(from focus: GuidedTourFocus, to node: ConceptNode, edge: GraphEdge) -> GuidedTourFocus {
        let relationship = edge.displayText()
        let direction = edge.sourceNodeID == focus.nodeID ? "via \(relationship)" : "through incoming \(relationship)"
        let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let context = summary.isEmpty ? "" : " \(summary)"
        return GuidedTourFocus(
            nodeID: node.id,
            title: node.label,
            narration: "Explore \(node.label) \(direction) from \(focus.title).\(context)",
            linearIndex: nil
        )
    }

    private func progressText(for focus: GuidedTourFocus, in tour: GuidedTour) -> String {
        guard let index = focus.linearIndex else { return "Explore" }
        return "\(index + 1)/\(tour.stops.count)"
    }

    private func tourIntroduction(_ tour: GuidedTour) -> String {
        let introduction = tour.introduction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !introduction.isEmpty { return introduction }
        if let firstStop = tour.stops.first {
            return "This guided tour starts with \(firstStop.title), then branches through the document's main ideas. \(firstStop.narration)"
        }
        return "This guided tour introduces the main ideas in \(tour.documentURL.lastPathComponent). Start with the recommended path, or branch into related nodes when you want more context."
    }

    private func tourOverlayWidth(_ canvasSize: CGSize) -> CGFloat {
        min(500, max(320, canvasSize.width - 16))
    }

    private func speakCurrentTourText() {
        guard isTourVisible, let tour = activeTour else { return }
        if isTourIntroVisible {
            speakTourText(tourIntroduction(tour))
        } else if let focus = activeTourFocus {
            speakTourText(focus.narration)
        }
    }

    private func speakTourText(_ text: String) {
        guard isTourVoiceEnabled else { return }
        stopTourSpeech()
        speechSynthesizer.startSpeaking(text)
    }

    private func stopTourSpeech() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking()
        }
    }

    private static func focus(for stop: GuidedTourStop, index: Int) -> GuidedTourFocus {
        GuidedTourFocus(
            nodeID: stop.nodeID,
            title: stop.title,
            narration: stop.narration,
            linearIndex: index
        )
    }

    private static func tourSortRank(_ level: NodeLevel) -> Int {
        switch level {
        case .document: return 0
        case .chapter: return 1
        case .concept: return 2
        case .entity: return 3
        }
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
