//
//  MultiDocumentView+MainContent.swift
//  PDFViewer
//
//  Main document, map, comparison, and project-file panes.
//

import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

extension MultiDocumentView {
    @ViewBuilder
    var mainContent: some View {
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
                                onNavigateToPage: { sourceURL, pageIndex, boundingBox, textSnippet in
                                    var info: [String: Any] = ["sourceDocumentURL": sourceURL]
                                    if let bb = boundingBox { info["boundingBox"] = bb }
                                    if let ts = textSnippet, !ts.isEmpty { info["textSnippet"] = ts }
                                    let post = {
                                        NotificationCenter.default.post(
                                            name: .navigateToPage,
                                            object: pageIndex,
                                            userInfo: info
                                        )
                                    }

                                    // Same tab — scroll immediately.
                                    if sourceURL == documentManager.selectedDocument?.url {
                                        post()
                                        return
                                    }

                                    // Different tab or not yet open. openDocument
                                    // handles both: returns .alreadyOpen (and
                                    // selects) for an open tab, .success for a
                                    // new one. Dispatch the post on the next
                                    // runloop so the destination PDFViewerView
                                    // has mounted + subscribed to the
                                    // notification.
                                    let result = documentManager.openDocument(
                                        sourceURL,
                                        projectID: projectsManager.selectedProjectID
                                    )
                                    switch result {
                                    case .success, .alreadyOpen:
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                            post()
                                        }
                                    case .tooManyTabs:
                                        alertManager.showAlert(
                                            title: "Too Many Tabs",
                                            message: "Close a tab to follow the source link to \(sourceURL.lastPathComponent)."
                                        )
                                    case .fileNotReadable, .invalidPDF:
                                        alertManager.showAlert(
                                            title: "Source Unavailable",
                                            message: "The source PDF '\(sourceURL.lastPathComponent)' is no longer accessible."
                                        )
                                    }
                                },
                                activeNodeID: syncManager.activeNodeID
                            )
                            if isChatVisible, let vm = chatViewModel {
                                ZStack {
                                    Rectangle()
                                        .fill(Color(nsColor: .separatorColor))
                                        .frame(width: 1)
                                    Button(action: { toggleChat() }) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 14, height: 36)
                                            .background(.regularMaterial, in: Capsule())
                                            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Hide chat (⌘4)")
                                }
                                .frame(width: 16)
                                ChatPanelView(viewModel: vm)
                                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !isChatVisible && aiService.isConfigured {
                                Button(action: { toggleChat() }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "bubble.left.and.text.bubble.right")
                                            .font(.body)
                                        if let vm = chatViewModel, vm.messages.count > 0 {
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
                    .onChange(of: PersistentHighlightGraphKey(nodeCount: knowledgeGraph.nodeCount, edgeCount: knowledgeGraph.edgeCount)) { _, newKey in
                        if newKey.nodeCount > 0 {
                            refreshPersistentHighlightsForOpenDocuments(reason: "graph-change")
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

    @ViewBuilder
    var projectFilesPanel: some View {
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
                TextField("Search files...", text: $sidebarState.filesQuery)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Files list - vertical layout like Finder
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(cachedProjectFiles, id: \.self) { file in
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

    @ViewBuilder
    var emptyStateView: some View {
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
                    createProjectSheet.isPresented = true
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
}
