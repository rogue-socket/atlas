//
//  MultiDocumentView+Sidebar.swift
//  PDFViewer
//
//  Sidebar sections for open tabs, projects, project files, and recents.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension MultiDocumentView {
    @ViewBuilder
    var sidebar: some View {
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
            Picker("", selection: $sidebarState.section) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // ── Section Content ──
            switch sidebarState.section {
            case .projects:
                projectsSectionContent
            case .recents:
                recentsSectionContent
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .sheet(isPresented: $createProjectSheet.isPresented) {
            CreateProjectView(
                projectName: $createProjectSheet.name,
                pickedURLs: $createProjectSheet.pickedURLs,
                onCreate: { name, urls in
                    projectsManager.createProject(name: name, urls: urls)
                    createProjectSheet.name = ""
                    createProjectSheet.pickedURLs = []
                }
            )
        }
        .sheet(isPresented: $renameProjectSheet.isPresented) {
            if let projectID = renameProjectSheet.projectID {
                RenameProjectView(
                    projectID: projectID,
                    currentName: $renameProjectSheet.newName,
                    onRename: { newName in
                        projectsManager.renameProject(projectID, name: newName)
                        renameProjectSheet.projectID = nil
                        renameProjectSheet.newName = ""
                    }
                )
            }
        }
        // Project-files cache invalidation. The cache rebuilds when the
        // selected project, total project count, or debounced search query
        // changes. File renames inside a project don't trigger a rebuild
        // (count unchanged) — accepted lag.
        .task(id: sidebarState.filesQuery) {
            if sidebarState.filesQuery.isEmpty {
                debouncedFilesQuery = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            debouncedFilesQuery = sidebarState.filesQuery
        }
        .onChange(of: debouncedFilesQuery) { _, _ in
            recomputeProjectFilesCache()
        }
        .onChange(of: projectsManager.selectedProjectID) { _, _ in
            recomputeProjectFilesCache()
        }
        .onChange(of: projectsManager.projects.count) { _, _ in
            recomputeProjectFilesCache()
        }
        .onAppear {
            recomputeProjectFilesCache()
        }
    }

    func sidebarTabRow(_ document: PDFDocumentItem) -> some View {
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

    var projectsSectionContent: some View {
        VStack(spacing: 0) {
            // Search + New Project
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Search...", text: $sidebarState.projectsQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                Button(action: { createProjectSheet.isPresented = true }) {
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
                    Button("Create Project") { createProjectSheet.isPresented = true }
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

    func sidebarProjectRow(_ project: Project) -> some View {
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
                renameProjectSheet.projectID = project.id
                renameProjectSheet.newName = project.name
                renameProjectSheet.isPresented = true
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

    var recentsSectionContent: some View {
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
                                            message: "This file can no longer be accessed. It may have been moved or its access revoked.",
                                            primaryButton: "Locate…",
                                            secondaryButton: "Remove from Recents",
                                            primaryAction: { locateInaccessibleRecent(at: index, originalURL: url) },
                                            secondaryAction: { recentFilesManager.removeInaccessibleFile(at: index) }
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

                                if isInaccessible {
                                    Button("Locate…") {
                                        locateInaccessibleRecent(at: index, originalURL: url)
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("Re-grant access to this file")
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
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

    func locateInaccessibleRecent(at index: Int, originalURL: URL) {
        let panel = NSOpenPanel()
        panel.title = "Locate \(originalURL.lastPathComponent)"
        panel.message = "Re-grant access to “\(originalURL.lastPathComponent)”"
        panel.prompt = "Grant Access"
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = originalURL.deletingLastPathComponent()
        panel.nameFieldStringValue = originalURL.lastPathComponent
        panel.begin { response in
            guard response == .OK, let pickedURL = panel.url else { return }
            // Index may have shifted if other recents mutated while the panel
            // was open; look the URL up again rather than trusting `index`.
            let currentIndex = recentFilesManager.recentFiles.firstIndex(of: originalURL) ?? index
            guard recentFilesManager.replaceBookmark(at: currentIndex, with: pickedURL) else {
                alertManager.showAlert(
                    title: "Couldn't Save Bookmark",
                    message: "Failed to create a security-scoped bookmark for the selected file."
                )
                return
            }
            let result = documentManager.openDocument(pickedURL)
            switch result {
            case .success, .alreadyOpen:
                break
            case .tooManyTabs:
                alertManager.showAlert(title: "Too Many Tabs", message: "Close some tabs before opening a new document.")
            case .fileNotReadable:
                alertManager.showAlert(title: "File Not Accessible", message: "Couldn't open the file after locating it.")
            case .invalidPDF:
                alertManager.showAlert(title: "Invalid PDF", message: "This file is not a valid PDF document.")
            }
        }
    }

    var filteredProjects: [Project] {
        if sidebarState.projectsQuery.isEmpty {
            return projectsManager.projects
        } else {
            return projectsManager.projects.filter { project in
                project.name.localizedCaseInsensitiveContains(sidebarState.projectsQuery)
            }
        }
    }

    func recomputeProjectFilesCache() {
        guard let projectID = projectsManager.selectedProjectID else {
            cachedProjectFiles = []
            return
        }

        let files = projectsManager.files(for: projectID, query: debouncedFilesQuery)
        cachedProjectFiles = files.compactMap { file in
            // Try to resolve from bookmark first, fallback to lastKnownPath.
            // `resolveURL` self-heals stale bookmarks — that side-effect now
            // runs only at cache-rebuild time, not on every body re-render.
            if let url = projectsManager.resolveURL(for: projectID, fileID: file.id) {
                return url
            } else {
                return URL(fileURLWithPath: file.lastKnownPath)
            }
        }
    }
}
