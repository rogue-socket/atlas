import Foundation
import SwiftUI
import Combine

protocol ProjectBookmarking {
    func createBookmark(for url: URL) -> Data?
    func resolveBookmark(_ data: Data, isStale: inout Bool) -> URL?
    func refreshBookmark(for url: URL) -> Data?
}

struct SecurityScopedProjectBookmarker: ProjectBookmarking {
    func createBookmark(for url: URL) -> Data? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolveBookmark(_ data: Data, isStale: inout Bool) -> URL? {
        try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
    }

    func refreshBookmark(for url: URL) -> Data? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

fileprivate struct ProjectsStorage: Codable {
    var projects: [Project]
    var selectedProjectID: UUID?
    var projectsSortMode: ProjectsSortMode
}

enum ProjectsSortMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case name
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .updated: return "Recently Updated"
        }
    }
}

enum ProjectFilesSortMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case name
    case added

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .added: return "Date Added"
        }
    }
}

struct ProjectFile: Identifiable, Codable, Hashable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var lastKnownPath: String
    var addedAt: Date

    init(id: UUID = UUID(), displayName: String, bookmarkData: Data, lastKnownPath: String, addedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.lastKnownPath = lastKnownPath
        self.addedAt = addedAt
    }
}

struct Project: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var files: [ProjectFile]
    var filesSortMode: ProjectFilesSortMode

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(), files: [ProjectFile] = [], filesSortMode: ProjectFilesSortMode = .manual) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.files = files
        self.filesSortMode = filesSortMode
    }
}

final class ProjectsManager: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published var selectedProjectID: UUID?
    @Published var projectsSortMode: ProjectsSortMode = .manual

    private let storageURL: URL
    private let bookmarker: ProjectBookmarking
    private var saveCancellable: AnyCancellable?

    init(storageURL: URL = ProjectsManager.makeStorageURL(), bookmarker: ProjectBookmarking = SecurityScopedProjectBookmarker()) {
        self.storageURL = storageURL
        self.bookmarker = bookmarker
        load()
        // objectWillChange fires on any @Published mutation; debounce coalesces bursts.
        // Replaces a prior CombineLatest3 over $projects/$selectedProjectID/$projectsSortMode
        // that never emitted when projectsSortMode was untouched.
        saveCancellable = objectWillChange
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.save()
            }
    }

    func sortedProjects(query: String) -> [Project] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) }

        switch projectsSortMode {
        case .manual:
            return base
        case .name:
            return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .updated:
            return base.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func files(for projectID: UUID, query: String) -> [ProjectFile] {
        guard let project = projects.first(where: { $0.id == projectID }) else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty ? project.files : project.files.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) || $0.lastKnownPath.localizedCaseInsensitiveContains(q)
        }

        switch project.filesSortMode {
        case .manual:
            return base
        case .name:
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .added:
            return base.sorted { $0.addedAt > $1.addedAt }
        }
    }

    func createProject(name: String, urls: [URL]) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? "Untitled Project" : trimmedName
        let finalName = uniqueProjectName(baseName, excluding: nil)
        let files = urls.compactMap { makeProjectFile(from: $0) }
        let project = Project(name: finalName, files: files)
        projects.insert(project, at: 0)
        selectedProjectID = project.id
    }

    func renameProject(_ projectID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        
        // Check if the name is actually different
        if projects[idx].name == trimmed { return }
        
        // Only use uniqueProjectName if the new name conflicts with other projects
        let newName = uniqueProjectNameForRename(trimmed, excluding: projectID)
        projects[idx].name = newName
        projects[idx].updatedAt = Date()
    }
    
    private func uniqueProjectNameForRename(_ name: String, excluding excludedProjectID: UUID) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "Untitled Project" }

        func isTaken(_ candidate: String) -> Bool {
            projects.contains { p in
                if p.id == excludedProjectID { return false }
                return p.name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }

        if !isTaken(base) { return base }

        var i = 2
        while true {
            let candidate = "\(base) (\(i))"
            if !isTaken(candidate) { return candidate }
            i += 1
        }
    }

    func deleteProject(_ projectID: UUID) {
        if let project = projects.first(where: { $0.id == projectID }) {
            for file in project.files {
                if let url = resolveURL(for: projectID, fileID: file.id) {
                    GraphStore.shared.deleteGraph(for: url)
                }
            }
            GraphStore.shared.deleteProjectGraph(projectID: projectID)
        }
        projects.removeAll { $0.id == projectID }
        if selectedProjectID == projectID {
            selectedProjectID = projects.first?.id
        }
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        guard projectsSortMode == .manual else { return }
        projects.move(fromOffsets: source, toOffset: destination)
    }

    func moveProject(projectID: UUID, toIndex: Int) {
        guard projectsSortMode == .manual else { return }
        guard let fromIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let clamped = max(0, min(toIndex, projects.count - 1))
        if fromIndex == clamped { return }
        let item = projects.remove(at: fromIndex)
        projects.insert(item, at: clamped)
    }

    func setFilesSortMode(_ mode: ProjectFilesSortMode, for projectID: UUID) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].filesSortMode = mode
        projects[idx].updatedAt = Date()
    }

    func addFiles(to projectID: UUID, urls: [URL]) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }

        var existingPaths = Set(projects[idx].files.map { $0.lastKnownPath })
        var addedAny = false

        for url in urls {
            let path = url.path
            if existingPaths.contains(path) { continue }
            guard let file = makeProjectFile(from: url) else { continue }
            projects[idx].files.insert(file, at: 0)
            existingPaths.insert(path)
            addedAny = true
        }

        if addedAny {
            projects[idx].updatedAt = Date()
        }
    }

    func removeFile(projectID: UUID, fileID: UUID) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[pIdx].files.removeAll { $0.id == fileID }
        projects[pIdx].updatedAt = Date()
    }

    func moveFiles(projectID: UUID, from source: IndexSet, to destination: Int) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pIdx].filesSortMode == .manual else { return }
        projects[pIdx].files.move(fromOffsets: source, toOffset: destination)
        projects[pIdx].updatedAt = Date()
    }

    func moveFile(projectID: UUID, fileID: UUID, toIndex: Int) {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard projects[pIdx].filesSortMode == .manual else { return }
        guard let fromIndex = projects[pIdx].files.firstIndex(where: { $0.id == fileID }) else { return }
        let clamped = max(0, min(toIndex, projects[pIdx].files.count - 1))
        if fromIndex == clamped { return }
        let item = projects[pIdx].files.remove(at: fromIndex)
        projects[pIdx].files.insert(item, at: clamped)
        projects[pIdx].updatedAt = Date()
    }

    func resolveURL(for projectID: UUID, fileID: UUID) -> URL? {
        guard let pIdx = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        guard let fIdx = projects[pIdx].files.firstIndex(where: { $0.id == fileID }) else { return nil }

        var isStale = false
        guard let url = bookmarker.resolveBookmark(projects[pIdx].files[fIdx].bookmarkData, isStale: &isStale) else {
            return nil
        }

        if isStale {
            if let refreshed = bookmarker.refreshBookmark(for: url) {
                projects[pIdx].files[fIdx].bookmarkData = refreshed
                projects[pIdx].files[fIdx].lastKnownPath = url.path
                projects[pIdx].files[fIdx].displayName = url.lastPathComponent
                projects[pIdx].updatedAt = Date()
            }
        }

        // Opportunistically upgrade legacy read-only bookmarks to read-write bookmarks.
        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let refreshed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                if refreshed != projects[pIdx].files[fIdx].bookmarkData {
                    projects[pIdx].files[fIdx].bookmarkData = refreshed
                    projects[pIdx].updatedAt = Date()
                }
            }
        }

        return url
    }

    private func makeProjectFile(from url: URL) -> ProjectFile? {
        guard let bookmarkData = bookmarker.createBookmark(for: url) else { return nil }
        return ProjectFile(displayName: url.lastPathComponent, bookmarkData: bookmarkData, lastKnownPath: url.path)
    }

    private func uniqueProjectName(_ name: String, excluding excludedProjectID: UUID?) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "Untitled Project" }

        func isTaken(_ candidate: String) -> Bool {
            projects.contains { p in
                if let excluded = excludedProjectID, p.id == excluded { return false }
                return p.name.compare(candidate, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
        }

        if !isTaken(base) { return base }

        var i = 2
        while true {
            let candidate = "\(base) (\(i))"
            if !isTaken(candidate) { return candidate }
            i += 1
        }
    }

    private func load() {
        let url = storageURL
        DispatchQueue.global(qos: .utility).async {
            // No file (or unreadable) → leave the freshly-initialized defaults in place.
            // Previously this branch overwrote whatever the caller had set between init
            // and the async hop, racing post-init mutations.
            guard let data = try? Data(contentsOf: url),
                  let storage = try? JSONDecoder().decode(ProjectsStorage.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                self.projects = storage.projects
                self.selectedProjectID = storage.selectedProjectID ?? storage.projects.first?.id
                self.projectsSortMode = storage.projectsSortMode
            }
        }
    }

    private func save() {
        let storage = ProjectsStorage(projects: projects, selectedProjectID: selectedProjectID, projectsSortMode: projectsSortMode)
        let url = storageURL

        // Encode on the main actor (project uses MainActor default isolation), then write on a background queue.
        guard let data = try? JSONEncoder().encode(storage) else { return }
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            } catch {
                return
            }
        }
    }

    static func makeStorageURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("PDFViewer", isDirectory: true)
        return dir.appendingPathComponent("projects.json")
    }
}
