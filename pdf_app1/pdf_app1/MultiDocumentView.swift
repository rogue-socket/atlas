//
//  MultiDocumentView.swift
//  PDFViewer
//
//  Multi-document interface with tabs and comparison
//
//  Provides tabbed interface for multiple PDF documents
//  with side-by-side comparison capabilities.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Vertical Tab Bar View
struct DocumentVerticalTabBar: View {
    @Binding var documents: [PDFDocumentItem]
    @Binding var selectedDocumentID: UUID?
    @ObservedObject var documentManager: DocumentManager
    @EnvironmentObject var projectsManager: ProjectsManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Open Documents")
                    .font(.headline)
                Spacer()
                
                // New tab button
                Button(action: {
                    NotificationCenter.default.post(
                        name: .openNewDocument,
                        object: nil
                    )
                }) {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 20, height: 20)
                .help("New Document (⌘T)")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Vertical tabs list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(documents, id: \.id) { document in
                        DocumentVerticalTabItem(
                            document: document,
                            isSelected: document.id == selectedDocumentID,
                            projectName: document.projectID != nil ? 
                                projectsManager.projects.first { $0.id == document.projectID }?.name : nil,
                            onClose: { documentManager.closeDocument(document) },
                            onSelect: { documentManager.selectDocument(id: document.id) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(minWidth: 200, maxWidth: 250)
    }
}

// MARK: - Vertical Tab Item
struct DocumentVerticalTabItem: View {
    let document: PDFDocumentItem
    let isSelected: Bool
    let projectName: String?
    let onClose: () -> Void
    let onSelect: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // File icon
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .accentColor : .blue)
                .frame(width: 16)
            
            // Document info
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                
                if let projectName = projectName {
                    Text(projectName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Close button
            if isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .frame(width: 16, height: 16)
                .help("Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered in
            if isHovered {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            if let projectName = projectName {
                Text("Project: \(projectName)")
                    .foregroundColor(.secondary)
                Divider()
            }
            
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(document.url.path, inFileViewerRootedAtPath: "")
            }
            
            Button("Close Tab") {
                onClose()
            }
            .keyboardShortcut("w", modifiers: [.command])
            
            Divider()
            
            Button("Close Other Tabs") {
                NotificationCenter.default.post(
                    name: .closeOtherTabs,
                    object: document
                )
            }
            
            Button("Open in New Window") {
                NotificationCenter.default.post(
                    name: .openDocumentInNewWindow,
                    object: document
                )
            }
        }
    }
}

// MARK: - Comparison View
struct DocumentComparisonView: View {
    let leftDocument: PDFDocumentItem?
    let rightDocument: PDFDocumentItem?
    let splitView: ComparisonSplitView
    let onSplitViewChange: (ComparisonSplitView) -> Void
    
    var body: some View {
        Group {
            if let left = leftDocument, let right = rightDocument {
                HStack(spacing: 1) {
                    switch splitView {
                    case .sideBySide:
                        HStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Left Document")
                            Divider()
                            DocumentPanel(document: right, title: "Right Document")
                        }
                    case .vertical:
                        VStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Top Document")
                            Divider()
                            DocumentPanel(document: right, title: "Bottom Document")
                        }
                    case .horizontal:
                        HStack(spacing: 1) {
                            DocumentPanel(document: left, title: "Document 1")
                            Divider()
                            DocumentPanel(document: right, title: "Document 2")
                        }
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Select two documents to compare")
                        .foregroundColor(.secondary)
                        .font(.headline)
                    Text("Drag documents to the left and right panels")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Document Panel for Comparison
struct DocumentPanel: View {
    let document: PDFDocumentItem
    let title: String
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text(document.title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // PDF View
            PDFViewerView(
                pdfDocument: document.document,
                pdfURL: document.url,
                annotationMode: .constant(.none),
                highlightColor: .constant(.yellow),
                notificationManager: NotificationManager(),
                toolbarBridge: PDFToolbarBridge()
            )
        }
    }
}

// MARK: - Main Multi-Document View
struct MultiDocumentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var recentFilesManager: RecentFilesManager
    @StateObject private var alertManager = AlertManager()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var loadingManager = LoadingStateManager()
    @EnvironmentObject var projectsManager: ProjectsManager
    
    @Environment(KnowledgeGraph.self) var knowledgeGraph
    @Environment(AIServiceManager.self) var aiService

    @State private var projectPipeline = ExtractionPipeline()
    @AppStorage("atlas.extraction.mode") private var selectedModeRaw: String = ExtractionMode.fast.rawValue
    private var selectedMode: ExtractionMode {
        ExtractionMode(rawValue: selectedModeRaw) ?? .fast
    }
    @State private var selectedPDF: PDFDocument?
    @State private var selectedPDFURL: URL?
    @State private var annotationMode: AnnotationMode = .none
    @State private var highlightColor: Color = .yellow
    @State private var paneMode: PaneMode = .split
    @State private var mapZoomLevel: SemanticZoomLevel = .concept
    @State private var syncManager = BidirectionalSyncManager()
    @State private var highlightBridge = HighlightSyncBridge()
    @State private var isChatVisible = false
    @State private var chatViewModel: ChatViewModel?
    @State private var showCommandPalette = false
    @State private var sidebarSection: SidebarSection = .projects
    @State private var projectsQuery: String = ""
    @State private var filesQuery: String = ""
    @State private var showingCreateProject = false
    @State private var createProjectName: String = ""
    @State private var createProjectPickedURLs: [URL] = []
    @State private var renamingProjectID: UUID?
    @State private var showingRenameProject = false
    @State private var renameProjectName: String = ""
    @State private var toolbarBridge = PDFToolbarBridge()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainContent
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .topTrailing) {
            let visible = Array(notificationManager.notifications.suffix(AppConstants.maxVisibleNotifications).reversed())
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(visible, id: \.id) { notification in
                    ToastNotificationView(item: notification) {
                    notificationManager.dismiss(notification.id)
                }
                }
            }
            .padding()
        }
        .overlay {
            if showCommandPalette {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showCommandPalette = false }

                VStack {
                    CommandPaletteView(
                        isPresented: $showCommandPalette,
                        graph: knowledgeGraph,
                        onSelectNode: { nodeID in
                            syncManager.navigateToNode(nodeID)
                        },
                        onNavigateToPage: { page in
                            NotificationCenter.default.post(
                                name: .navigateToPage,
                                object: page
                            )
                        }
                    )
                    .padding(.top, 100)
                    Spacer()
                }
            }
        }
        .overlay {
            if let item = alertManager.alertItem {
                CompactAlertView(item: item) {
                    alertManager.alertItem = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .zIndex(100)
                .onAppear {
                    showCommandPalette = false
                }
            }
        }
        .environmentObject(alertManager)
        .environmentObject(notificationManager)
        .environmentObject(loadingManager)
        .onReceive(NotificationCenter.default.publisher(for: .openNewDocument)) { _ in
            // Trigger file picker
            let panel = NSOpenPanel()
            panel.title = "Open PDF Document"
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = [.pdf]
            panel.begin { response in
                if response == .OK {
                    documentManager.openDocuments(panel.urls, projectID: projectsManager.selectedProjectID)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeCurrentTab)) { _ in
            if let document = documentManager.selectedDocument {
                documentManager.closeDocument(document)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeOtherTabs)) { notification in
            if let currentDocument = notification.object as? PDFDocumentItem {
                documentManager.documents.removeAll { $0.id != currentDocument.id }
                documentManager.selectedDocumentID = currentDocument.id
            }
        }
        // Pane mode keyboard shortcuts
        .background(
            Group {
                Button("") { paneMode = .pdfOnly }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("") { paneMode = .mapOnly }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("") { paneMode = .split }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("") { toggleChat() }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("") { showCommandPalette.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        )
        .onChange(of: documentManager.selectedDocumentID) { _, _ in
            if let doc = documentManager.selectedDocument {
                syncManager.setDocumentURL(doc.url)
                syncManager.setGraph(knowledgeGraph)
                loadGraphIfNeeded(for: doc.url)
            }
        }
        .onAppear {
            if let doc = documentManager.selectedDocument {
                syncManager.setDocumentURL(doc.url)
                syncManager.setGraph(knowledgeGraph)
                loadGraphIfNeeded(for: doc.url)
            }
        }
    }
    
    // MARK: - Sidebar Section
    enum SidebarSection: String, CaseIterable {
        case projects = "Projects"
        case recents = "Recents"
    }

    private var pdfAnnotationIcon: String {
        switch annotationMode {
        case .none: return "hand.point.up.left"
        case .select: return "arrow.up.and.down.and.arrow.left.and.right"
        case .highlightText: return "highlighter"
        case .highlightArea: return "rectangle.dashed"
        case .text: return "text.bubble"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .stickyNote: return "note.text"
        case .ink: return "pencil.tip"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.right"
        }
    }

    private var pdfAnnotationUsesColor: Bool {
        switch annotationMode {
        case .none, .select, .text, .stickyNote: return false
        default: return true
        }
    }

    @ViewBuilder
    private var pdfToolbar: some View {
        let bridge = toolbarBridge
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button(action: { bridge.onGoBack() }) { Image(systemName: "chevron.left") }
                    .disabled(!bridge.canGoBack)
                    .help("Previous Page (⌘←)")
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button(action: { bridge.onGoForward() }) { Image(systemName: "chevron.right") }
                    .disabled(!bridge.canGoForward)
                    .help("Next Page (⌘→)")
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Text("\(bridge.currentPageIndex + 1)/\(max(bridge.pageCount, 1))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                Button(action: { bridge.onZoomOut() }) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out")
                Button(action: { bridge.onZoomIn() }) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In")
                Button(action: { bridge.onFitToPage() }) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help("Fit to Page")
            }

            HStack(spacing: 4) {
                Menu {
                    Section("Display Mode") {
                        Button("Single Page") { bridge.onSetDisplayMode(.singlePage) }
                        Button("Continuous") { bridge.onSetDisplayMode(.singlePageContinuous) }
                        Button("Two Pages") { bridge.onSetDisplayMode(.twoUp) }
                        Button("Two Pages Continuous") { bridge.onSetDisplayMode(.twoUpContinuous) }
                    }
                    Section("Rotation") {
                        Button("Rotate Left") { bridge.onRotateCCW() }
                        Button("Rotate Right") { bridge.onRotateCW() }
                    }
                    Section("Reading Mode") {
                        Button("Normal") { bridge.onSetReadingMode(.normal) }
                        Button("Sepia") { bridge.onSetReadingMode(.sepia) }
                        Button("Dark") { bridge.onSetReadingMode(.dark) }
                    }
                } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Display & Reading")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Button(action: { bridge.onToggleSearch() }) { Image(systemName: "magnifyingglass") }
                    .help("Search (⌘F)")
                    .keyboardShortcut("f", modifiers: .command)
                Menu {
                    Section("Markup") {
                        Button("None") { annotationMode = .none }
                        Button("Move / Resize") { annotationMode = .select }
                        Button("Highlight") { annotationMode = .highlightText }
                        Button("Underline") { annotationMode = .underline }
                        Button("Strikethrough") { annotationMode = .strikethrough }
                        Button("Area Highlight") { annotationMode = .highlightArea }
                    }
                    Section("Shapes") {
                        Button("Rectangle") { annotationMode = .rectangle }
                        Button("Circle") { annotationMode = .circle }
                        Button("Line") { annotationMode = .line }
                        Button("Arrow") { annotationMode = .arrow }
                    }
                    Section("Other") {
                        Button("Text") { annotationMode = .text }
                        Button("Sticky Note") { annotationMode = .stickyNote }
                        Button("Ink") { annotationMode = .ink }
                    }
                } label: { Image(systemName: pdfAnnotationIcon) }
                    .help("Annotation")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if pdfAnnotationUsesColor {
                    ColorPicker("", selection: $highlightColor).labelsHidden()
                }
                Spacer(minLength: 0)
                Button(action: { bridge.onUndo() }) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!bridge.canUndo)
                    .help("Undo (⌘Z)")
                    .keyboardShortcut("z", modifiers: .command)
                Button(action: { bridge.onRedo() }) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!bridge.canRedo)
                    .help("Redo (⌘⇧Z)")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            HStack(spacing: 4) {
                Button(action: { bridge.onTogglePanel(.thumbnails) }) { Image(systemName: "square.grid.2x2") }
                    .help("Thumbnails")
                Button(action: { bridge.onTogglePanel(.outline) }) { Image(systemName: "list.bullet") }
                    .help("Table of Contents")
                Button(action: { bridge.onTogglePanel(.annotations) }) { Image(systemName: "note.text") }
                    .help("Annotations")
                Spacer(minLength: 0)
                Button(action: { bridge.onToggleFullscreen() }) {
                    Image(systemName: bridge.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help("Fullscreen (⌘⌃F)")
                .keyboardShortcut("f", modifiers: [.command, .control])
                Menu {
                    Button(bridge.currentPageBookmarked ? "Remove Bookmark" : "Add Bookmark") {
                        bridge.onToggleBookmark()
                    }.disabled(bridge.pageCount == 0)
                    if !bridge.bookmarks.isEmpty {
                        Divider()
                        ForEach(bridge.bookmarks, id: \.self) { idx in
                            Button("Page \(idx + 1)") { bridge.onGoToPage(idx) }
                        }
                        Divider()
                        Button("Clear Bookmarks") { bridge.onClearBookmarks() }
                    }
                } label: { Image(systemName: bridge.currentPageBookmarked ? "bookmark.fill" : "bookmark") }
                    .help("Bookmarks")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                if bridge.hasURL {
                    Button(action: { bridge.onSave() }) {
                        if bridge.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                    }
                    .disabled(bridge.isSaving)
                    .help("Save (⌘S)")
                    .keyboardShortcut("s", modifiers: .command)
                    Menu {
                        Button("Save As...") { bridge.onSaveAs() }
                            .keyboardShortcut("s", modifiers: [.command, .shift])
                        Button("Print...") { bridge.onPrint() }
                            .keyboardShortcut("p", modifiers: .command)
                    } label: { Image(systemName: "ellipsis") }
                        .help("More")
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Sidebar View
    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            pdfToolbar

            Divider()

            // ── Open Tabs (always visible when documents are open) ──
            if !documentManager.documents.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text("Open")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                            .textCase(.uppercase)
                        Spacer()
                        Button(action: {
                            NotificationCenter.default.post(name: .openNewDocument, object: nil)
                        }) {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Open PDF (Cmd+T)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(documentManager.documents, id: \.id) { document in
                                sidebarTabRow(document)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .frame(maxHeight: min(CGFloat(documentManager.documents.count) * 34, 170))
                }

                Divider()
                    .padding(.top, 4)
            }

            // ── Section Picker ──
            Picker("", selection: $sidebarSection) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // ── Section Content ──
            switch sidebarSection {
            case .projects:
                projectsSectionContent
            case .recents:
                recentsSectionContent
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .sheet(isPresented: $showingCreateProject) {
            CreateProjectView(
                projectName: $createProjectName,
                pickedURLs: $createProjectPickedURLs,
                onCreate: { name, urls in
                    projectsManager.createProject(name: name, urls: urls)
                    createProjectName = ""
                    createProjectPickedURLs = []
                }
            )
        }
        .sheet(isPresented: $showingRenameProject) {
            if let projectID = renamingProjectID {
                RenameProjectView(
                    projectID: projectID,
                    currentName: $renameProjectName,
                    onRename: { newName in
                        projectsManager.renameProject(projectID, name: newName)
                        renamingProjectID = nil
                        renameProjectName = ""
                    }
                )
            }
        }
    }

    // MARK: - Open Tab Row
    private func sidebarTabRow(_ document: PDFDocumentItem) -> some View {
        let isSelected = document.id == documentManager.selectedDocumentID
        return HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 14)

            Text(document.title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(1)

            Spacer()

            Button(action: { documentManager.closeDocument(document) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(isSelected ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { documentManager.selectDocument(id: document.id) }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(document.url.path, inFileViewerRootedAtPath: "")
            }
            Button("Close Tab") { documentManager.closeDocument(document) }
            Button("Close Other Tabs") {
                NotificationCenter.default.post(name: .closeOtherTabs, object: document)
            }
        }
    }

    // MARK: - Projects Section
    private var projectsSectionContent: some View {
        VStack(spacing: 0) {
            // Search + New Project
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $projectsQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                Button(action: { showingCreateProject = true }) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("New Project")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Project list
            if filteredProjects.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No projects yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Create Project") { showingCreateProject = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredProjects) { project in
                            sidebarProjectRow(project)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }

            // Project files (when a project is selected)
            if projectsManager.selectedProjectID != nil {
                Divider()
                    .padding(.vertical, 4)
                projectFilesPanel
            }
        }
    }

    // MARK: - Project Row
    private func sidebarProjectRow(_ project: Project) -> some View {
        let isSelected = projectsManager.selectedProjectID == project.id
        return HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .accentColor : .orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Text("\(project.files.count) file\(project.files.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            projectsManager.selectedProjectID = isSelected ? nil : project.id
        }
        .contextMenu {
            Button("Open All Files") {
                let files = projectsManager.files(for: project.id, query: "")
                documentManager.openProjectFiles(project.id, files: files, projectsManager: projectsManager)
            }
            Divider()
            Button("Rename...") {
                renamingProjectID = project.id
                renameProjectName = project.name
                showingRenameProject = true
            }
            Button("Delete", role: .destructive) {
                let openDocsInProject = documentManager.documents.filter { $0.projectID == project.id }
                for doc in openDocsInProject {
                    documentManager.closeDocument(doc)
                }
                projectsManager.deleteProject(project.id)
            }
        }
    }

    // MARK: - Recents Section
    private var recentsSectionContent: some View {
        VStack(spacing: 0) {
            if recentFilesManager.recentFiles.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No recent files")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Open PDF") {
                        NotificationCenter.default.post(name: .openNewDocument, object: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(recentFilesManager.recentFiles.enumerated()), id: \.element.path) { index, url in
                            let isInaccessible = recentFilesManager.inaccessibleFiles.contains(index)
                            HStack(spacing: 6) {
                                Image(systemName: isInaccessible ? "exclamationmark.triangle.fill" : "doc.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(isInaccessible ? .orange : .blue)
                                    .frame(width: 14)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Text(isInaccessible ? "File not accessible" : url.deletingLastPathComponent().lastPathComponent)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .opacity(isInaccessible ? 0.5 : 1.0)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let result = documentManager.openDocument(url)
                                switch result {
                                case .success, .alreadyOpen:
                                    break
                                case .tooManyTabs:
                                    alertManager.showAlert(title: "Too Many Tabs", message: "Close some tabs before opening a new document.")
                                case .fileNotReadable:
                                    alertManager.showAlert(
                                        title: "File Not Accessible",
                                        message: "This file can no longer be accessed. It may have been moved or deleted.",
                                        primaryButton: "Remove from Recents",
                                        secondaryButton: "Cancel",
                                        primaryAction: { recentFilesManager.removeInaccessibleFile(at: index) }
                                    )
                                case .invalidPDF:
                                    alertManager.showAlert(
                                        title: "Invalid PDF",
                                        message: "This file is not a valid PDF document.",
                                        primaryButton: "Remove from Recents",
                                        secondaryButton: "Cancel",
                                        primaryAction: { recentFilesManager.removeInaccessibleFile(at: index) }
                                    )
                                }
                            }
                            .contextMenu {
                                Button("Remove from Recents", role: .destructive) {
                                    recentFilesManager.removeFiles(at: IndexSet(integer: index))
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.clear)
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }
    
    // MARK: - Main Content
    @ViewBuilder
    private var mainContent: some View {
        Group {
            switch documentManager.viewMode {
            case .single:
                if let document = documentManager.selectedDocument {
                    SplitPaneContainer(paneMode: $paneMode) {
                        PDFViewerView(
                            pdfDocument: document.document,
                            pdfURL: document.url,
                            annotationMode: $annotationMode,
                            highlightColor: $highlightColor,
                            notificationManager: notificationManager,
                            toolbarBridge: toolbarBridge
                        )
                        .enhancedDropZone(maxFiles: 10) { urls in
                            documentManager.openDocuments(urls, projectID: projectsManager.selectedProjectID)
                        }
                    } mapContent: {
                        HStack(spacing: 0) {
                            KnowledgeMapView(
                                graph: knowledgeGraph,
                                zoomLevel: $mapZoomLevel,
                                documentURL: document.url,
                                onNavigateToPage: { pageIndex, boundingBox, textSnippet in
                                    var info: [String: Any] = [:]
                                    if let bb = boundingBox { info["boundingBox"] = bb }
                                    if let ts = textSnippet, !ts.isEmpty { info["textSnippet"] = ts }
                                    NotificationCenter.default.post(
                                        name: .navigateToPage,
                                        object: pageIndex,
                                        userInfo: info.isEmpty ? nil : info
                                    )
                                },
                                activeNodeID: syncManager.activeNodeID
                            )
                            if isChatVisible, let vm = chatViewModel {
                                Divider()
                                ChatPanelView(viewModel: vm)
                                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !isChatVisible, let vm = chatViewModel {
                                Button(action: { toggleChat() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "bubble.left.and.text.bubble.right")
                                            .font(.body)
                                        if vm.messages.count > 0 {
                                            Text("\(vm.messages.count)")
                                                .font(.caption)
                                                .monospacedDigit()
                                        }
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.regularMaterial, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("Show chat (⌘4)")
                                .padding(12)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: knowledgeGraph.nodeCount) { _, newCount in
                        // Refresh persistent highlights when graph changes
                        if newCount > 0, let doc = documentManager.selectedDocument {
                            highlightBridge.refreshHighlights(
                                document: doc.document,
                                graph: knowledgeGraph,
                                documentURL: doc.url
                            )
                        }
                    }
                } else {
                    // Empty state when no document is selected
                    emptyStateView
                }
                
            case .comparison(let splitView):
                VStack(spacing: 0) {
                    // Comparison viewer
                    DocumentComparisonView(
                        leftDocument: documentManager.comparisonDocuments.left,
                        rightDocument: documentManager.comparisonDocuments.right,
                        splitView: splitView,
                        onSplitViewChange: documentManager.setComparisonSplitView
                    )
                    .enhancedDropZone(maxFiles: 2) { urls in
                        if urls.count >= 2 {
                            documentManager.startComparison(
                                left: documentManager.documents.first { $0.url == urls[0] },
                                right: documentManager.documents.first { $0.url == urls[1] }
                            )
                        } else if let first = urls.first {
                            documentManager.openDocument(first, projectID: projectsManager.selectedProjectID)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity) // Take full space
                    
                    // Comparison controls
                    HStack {
                        Text("Comparison Mode")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Picker("Split View", selection: Binding(
                            get: {
                                if case .comparison(let sv) = documentManager.viewMode { return sv }
                                return .sideBySide
                            },
                            set: { documentManager.setComparisonSplitView($0) }
                        )) {
                            Text("Side by Side").tag(ComparisonSplitView.sideBySide)
                            Text("Vertical").tag(ComparisonSplitView.vertical)
                            Text("Horizontal").tag(ComparisonSplitView.horizontal)
                        }
                        .pickerStyle(.segmented)
                        
                        Button("Exit Comparison") {
                            documentManager.exitComparisonMode()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color(NSColor.separatorColor)),
                        alignment: .top
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure full space usage
        .background(Color(NSColor.textBackgroundColor)) // Consistent background
    }
    
    // MARK: - Project Files Panel (Left Sidebar)
    @ViewBuilder
    private var projectFilesPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Files")
                    .font(.headline)
                
                Spacer()
                
                // Open all files in project
                Button(action: {
                    if let projectID = projectsManager.selectedProjectID {
                        let projectFiles = projectsManager.files(for: projectID, query: "")
                        documentManager.openProjectFiles(projectID, files: projectFiles, projectsManager: projectsManager)
                    }
                }) {
                    Image(systemName: "doc.text.fill")
                }
                .buttonStyle(.borderless)
                .help("Open All Files in Tabs")
                
                Button(action: {
                    let panel = NSOpenPanel()
                    panel.title = "Add PDFs to Project"
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.pdf]
                    panel.begin { response in
                        if response == .OK {
                            if let project = projectsManager.projects.first(where: { $0.id == projectsManager.selectedProjectID }) {
                                projectsManager.addFiles(to: project.id, urls: panel.urls)
                            }
                        }
                    }
                }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add PDFs to Project")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if aiService.isConfigured && hasUnprocessedFiles {
                HStack {
                    Button(action: analyzeAllUnprocessed) {
                        Label(
                            projectPipeline.isProcessing ? "Analyzing..." : "Analyze All",
                            systemImage: "brain"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(projectPipeline.isProcessing)

                    if projectPipeline.isProcessing {
                        ProgressView(value: projectPipeline.progress)
                            .controlSize(.small)
                    }

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }
            
            Divider()
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search files...", text: $filesQuery)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Files list - vertical layout like Finder
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredProjectFiles, id: \.self) { file in
                        ProjectFileRow(
                            file: file,
                            projectsManager: projectsManager,
                            projectID: projectsManager.selectedProjectID ?? UUID(),
                            processingState: knowledgeGraph.documentProcessingState[file] ?? .unprocessed,
                            canAnalyze: aiService.isConfigured && !projectPipeline.isProcessing,
                            onSelect: { url in
                                documentManager.openDocument(url, projectID: projectsManager.selectedProjectID)
                            },
                            onRemove: { url in
                                if let projectID = projectsManager.selectedProjectID {
                                    let projectFiles = projectsManager.files(for: projectID, query: "")
                                    if let projectFile = projectFiles.first(where: { $0.lastKnownPath == url.path }) {
                                        projectsManager.removeFile(projectID: projectID, fileID: projectFile.id)
                                    }
                                }
                            },
                            onAnalyze: { url in
                                analyzeDocument(at: url)
                            }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(minWidth: 200, maxWidth: 250)
    }
    
    // MARK: - Project File Row (Vertical Layout)
    struct ProjectFileRow: View {
        let file: URL
        let projectsManager: ProjectsManager
        let projectID: UUID
        let processingState: ProcessingState
        let canAnalyze: Bool
        let onSelect: (URL) -> Void
        let onRemove: (URL) -> Void
        let onAnalyze: (URL) -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.blue)
                    .frame(width: 16)

                Button(action: { onSelect(file) }) {
                    HStack {
                        Text(file.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                }
                .buttonStyle(.borderless)

                processingBadge

                if canAnalyze && processingState == .unprocessed {
                    Button(action: { onAnalyze(file) }) {
                        Image(systemName: "brain")
                            .font(.system(size: 11))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Analyze this document")
                }

                Button(action: { onRemove(file) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .opacity(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.clear)
            .onHover { isHovered in
                if isHovered {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }

        private var processingBadge: some View {
            Group {
                switch processingState {
                case .unprocessed:
                    EmptyView()
                case .processing:
                    ProgressView()
                        .controlSize(.mini)
                case .partial:
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundColor(.orange)
                        .font(.caption2)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption2)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.caption2)
                }
            }
        }
    }
    
    // MARK: - Empty State View
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 6) {
                Text("Open a PDF to get started")
                    .font(.title3)
                    .foregroundColor(.primary)

                Text("Drop a file here, open from the sidebar, or use Cmd+T")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 12) {
                Button {
                    NotificationCenter.default.post(name: .openNewDocument, object: nil)
                } label: {
                    Label("Open PDF", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showingCreateProject = true
                } label: {
                    Label("New Project", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
        .enhancedDropZone(maxFiles: 10) { urls in
            documentManager.openDocuments(urls, projectID: projectsManager.selectedProjectID)
        }
    }
    
    // MARK: - Document Extraction

    private var hasUnprocessedFiles: Bool {
        filteredProjectFiles.contains { url in
            let state = knowledgeGraph.documentProcessingState[url] ?? .unprocessed
            return state == .unprocessed || state == .failed
        }
    }

    private func analyzeDocument(at url: URL) {
        guard let document = PDFDocument(url: url) else { return }
        projectPipeline.processFullDocument(
            document: document, documentURL: url,
            graph: knowledgeGraph, aiService: aiService,
            mode: selectedMode
        )
    }

    private func analyzeAllUnprocessed() {
        let unprocessed = filteredProjectFiles.filter { url in
            let state = knowledgeGraph.documentProcessingState[url] ?? .unprocessed
            return state == .unprocessed || state == .failed
        }
        guard !unprocessed.isEmpty else { return }

        Task {
            for url in unprocessed {
                guard let document = PDFDocument(url: url) else { continue }
                projectPipeline.processFullDocument(
                    document: document, documentURL: url,
                    graph: knowledgeGraph, aiService: aiService,
                    mode: selectedMode
                )
                while projectPipeline.isProcessing {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    // MARK: - Graph Persistence

    /// Load the persisted graph for a document, replacing any in-memory graph from a previously-active document.
    private func loadGraphIfNeeded(for documentURL: URL) {
        let alreadyHasNodes = knowledgeGraph.allNodes.contains { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        guard !alreadyHasNodes else { return }

        if let saved = GraphStore.shared.load(for: documentURL) {
            try? knowledgeGraph.decode(from: saved.encode())
        } else {
            knowledgeGraph.clear()
        }
    }

    // MARK: - Computed Properties
    private var filteredProjects: [Project] {
        if projectsQuery.isEmpty {
            return projectsManager.projects
        } else {
            return projectsManager.projects.filter { project in
                project.name.localizedCaseInsensitiveContains(projectsQuery)
            }
        }
    }
    
    private var filteredProjectFiles: [URL] {
        guard let projectID = projectsManager.selectedProjectID else { return [] }
        
        let files = projectsManager.files(for: projectID, query: filesQuery)
        return files.compactMap { file in
            // Try to resolve from bookmark first, fallback to lastKnownPath
            if let url = projectsManager.resolveURL(for: projectID, fileID: file.id) {
                return url
            } else {
                // Fallback to lastKnownPath
                return URL(fileURLWithPath: file.lastKnownPath)
            }
        }
    }

    // MARK: - Chat

    private func toggleChat() {
        if chatViewModel == nil, let backend = aiService.createBackend() {
            let vm = ChatViewModel(
                backend: backend,
                graph: knowledgeGraph,
                documentURL: documentManager.selectedDocument?.url
            )
            if let doc = documentManager.selectedDocument {
                let extractor = TextExtractor()
                let pages = extractor.extractPages(from: doc.document, pageRange: 0..<doc.document.pageCount)
                vm.setPageText(pages.map { (pageIndex: $0.pageIndex, text: $0.fullText) })
            }
            chatViewModel = vm
        }
        isChatVisible.toggle()
        if isChatVisible && paneMode == .pdfOnly {
            paneMode = .split
        }
    }
}
