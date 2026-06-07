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

struct PersistentHighlightGraphKey: Equatable {
    let nodeCount: Int
    let edgeCount: Int
}

// MARK: - Main Multi-Document View
struct MultiDocumentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var recentFilesManager: RecentFilesManager
    @StateObject var alertManager = AlertManager()
    @StateObject var notificationManager = NotificationManager()
    @EnvironmentObject var projectsManager: ProjectsManager

    @Environment(KnowledgeGraph.self) var knowledgeGraph
    @Environment(AIServiceManager.self) var aiService

    @State var projectPipeline = ExtractionPipeline()
    @AppStorage("atlas.extraction.mode") var selectedModeRaw: String = ExtractionMode.fast.rawValue
    var selectedMode: ExtractionMode {
        ExtractionMode(rawValue: selectedModeRaw) ?? .fast
    }
    @State var selectedPDF: PDFDocument?
    @State var selectedPDFURL: URL?
    @State var annotationMode: AnnotationMode = .none
    @State var highlightColor: Color = .yellow
    @State var paneMode: PaneMode = .split
    @State var mapZoomLevel: SemanticZoomLevel = .concept
    @State var syncManager = BidirectionalSyncManager()
    @State var highlightBridge = HighlightSyncBridge()
    @State var isChatVisible = false
    @State var chatViewModel: ChatViewModel?
    @State var showCommandPalette = false
    @State var sidebarState = SidebarState()
    @State var createProjectSheet = CreateProjectSheetState()
    @State var renameProjectSheet = RenameProjectSheetState()
    @State var toolbarBridge = PDFToolbarBridge()
    // Cached file list for the projects sidebar. Rebuilt only when the
    // selected project, project count, or the debounced search query
    // changes — not on every body re-render. `filteredProjectFiles`
    // (the old computed property) resolved a security-scoped bookmark
    // per file per render, with two body consumers, so a project with
    // N files ran 2N filesystem syscalls per render during extraction.
    @State var cachedProjectFiles: [URL] = []
    @State var debouncedFilesQuery: String = ""

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
                prepareSelectedDocument(doc)
            }
        }
        .onAppear {
            if let doc = documentManager.selectedDocument {
                prepareSelectedDocument(doc)
            }
        }
    }

    // MARK: - Sidebar Section
    enum SidebarSection: String, CaseIterable {
        case projects = "Projects"
        case recents = "Recents"
    }

    // MARK: - State Bundles
    struct SidebarState {
        var section: SidebarSection = .projects
        var projectsQuery: String = ""
        var filesQuery: String = ""
    }

    struct CreateProjectSheetState {
        var isPresented: Bool = false
        var name: String = ""
        var pickedURLs: [URL] = []
    }

    struct RenameProjectSheetState {
        var isPresented: Bool = false
        var projectID: UUID?
        var newName: String = ""
    }
}
