//
//  HeadlessRunner.swift
//  pdf_app1
//
//  Hidden launch path for end-to-end extraction without UI interaction.
//  Triggered by `--headless-extract --project <name> [--mode fast|deep]`.
//  Used to validate SCE / cross-doc behavior reproducibly.
//

import Foundation
import PDFKit
import os.log
import Darwin

struct HeadlessRunnerConfig {
    let projectName: String
    let mode: ExtractionMode
    /// `nil` = alphabetical by displayName. `"reverse"` flips that order.
    /// Any other value is a comma-separated list of displayName values.
    let docOrder: String?
    /// Optional directory for headless graph writes. Use this for disposable
    /// verification runs instead of the app's real persisted graph store.
    let graphsOutputDirectory: URL?
    /// Optional projects.json path for disposable verification runs.
    let projectStorageURL: URL?
    /// Optional cap for smoke runs that only need the first N ordered files.
    let docLimit: Int?

    init(projectName: String,
         mode: ExtractionMode,
         docOrder: String?,
         graphsOutputDirectory: URL? = nil,
         projectStorageURL: URL? = nil,
         docLimit: Int? = nil) {
        self.projectName = projectName
        self.mode = mode
        self.docOrder = docOrder
        self.graphsOutputDirectory = graphsOutputDirectory
        self.projectStorageURL = projectStorageURL
        self.docLimit = docLimit
    }

    /// Parse `--headless-extract --project <name> [--mode fast|deep] [--doc-order alpha|reverse|name1,name2,...] [--graphs-output <dir>] [--project-storage <projects.json>] [--doc-limit <n>]`.
    /// Returns nil when the headless flag is absent or project name is missing.
    static func parse(from args: [String]) -> HeadlessRunnerConfig? {
        guard args.contains("--headless-extract") else { return nil }
        var projectName: String?
        var mode: ExtractionMode = .fast
        var docOrder: String?
        var graphsOutputDirectory: URL?
        var projectStorageURL: URL?
        var docLimit: Int?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--project", i + 1 < args.count {
                projectName = args[i + 1]
                i += 2
                continue
            }
            if a == "--mode", i + 1 < args.count {
                mode = ExtractionMode(rawValue: args[i + 1]) ?? .fast
                i += 2
                continue
            }
            if a == "--doc-order", i + 1 < args.count {
                docOrder = args[i + 1]
                i += 2
                continue
            }
            if a == "--graphs-output", i + 1 < args.count {
                let path = (args[i + 1] as NSString).expandingTildeInPath
                graphsOutputDirectory = URL(fileURLWithPath: path)
                i += 2
                continue
            }
            if a == "--project-storage", i + 1 < args.count {
                let path = (args[i + 1] as NSString).expandingTildeInPath
                projectStorageURL = URL(fileURLWithPath: path)
                i += 2
                continue
            }
            if a == "--doc-limit", i + 1 < args.count {
                if let limit = Int(args[i + 1]), limit > 0 {
                    docLimit = limit
                }
                i += 2
                continue
            }
            i += 1
        }
        guard let name = projectName else {
            AtlasLogger.headless.error("[Headless] --headless-extract requires --project <name>")
            return nil
        }
        return HeadlessRunnerConfig(
            projectName: name,
            mode: mode,
            docOrder: docOrder,
            graphsOutputDirectory: graphsOutputDirectory,
            projectStorageURL: projectStorageURL,
            docLimit: docLimit
        )
    }

    func orderedFiles(from project: Project) -> [ProjectFile] {
        let alpha = project.files.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        guard let docOrder, docOrder != "alpha" else { return alpha }
        if docOrder == "reverse" { return alpha.reversed() }
        let names = docOrder.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let byName = Dictionary(uniqueKeysWithValues: alpha.map { ($0.displayName, $0) })
        var ordered: [ProjectFile] = []
        for name in names {
            guard let file = byName[name] else { continue }
            ordered.append(file)
        }
        let picked = Set(ordered.map(\.id))
        for file in alpha where !picked.contains(file.id) {
            ordered.append(file)
        }
        return ordered
    }
}

@MainActor
final class HeadlessRunner {
    private let log = AtlasLogger.headless

    private func info(_ message: String) {
        log.info("\(message, privacy: .public)")
        print(message)
        fflush(stdout)
    }

    private func warning(_ message: String) {
        log.warning("\(message, privacy: .public)")
        print(message)
        fflush(stdout)
    }

    private func error(_ message: String) {
        log.error("\(message, privacy: .public)")
        fputs("\(message)\n", stderr)
        fflush(stderr)
    }

    /// Drives sequential per-doc extraction for every file in the named project,
    /// in alphabetical-by-displayName order. Exits the process when complete so
    /// `open --wait-apps` callers can read the resulting graph files.
    func run(config: HeadlessRunnerConfig,
             projectsManager: ProjectsManager,
             aiService: AIServiceManager,
             graph: KnowledgeGraph) async {
        info("[Headless] start: project=\(config.projectName) mode=\(config.mode.rawValue)")
        if let directory = config.graphsOutputDirectory {
            GraphStore.shared.useGraphsDirectory(directory)
            info("[Headless] graphs_output=\(directory.path)")
        } else {
            warning("[Headless] graphs_output=<default app graph store>")
        }
        ExtractionPipeline.mirrorsSCETelemetryToStdout = true

        // Wait for ProjectsManager to hydrate (async load). Cap at 10s.
        let deadline = Date().addingTimeInterval(10)
        while !projectsManager.didLoadInitialState {
            if Date() > deadline {
                error("[Headless] timed out waiting for ProjectsManager (10s)")
                exit(2)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        info("[Headless] projects loaded: \(projectsManager.projects.count) project(s)")

        guard let project = projectsManager.projects.first(where: { $0.name == config.projectName }) else {
            let names = projectsManager.projects.map { $0.name }.joined(separator: ", ")
            error("[Headless] project not found: \"\(config.projectName)\" (available: [\(names)])")
            exit(2)
        }

        let orderedFiles = config.orderedFiles(from: project)
        let files = config.docLimit.map { Array(orderedFiles.prefix($0)) } ?? orderedFiles
        let orderLabel = config.docOrder ?? "alpha"
        let limitLabel = config.docLimit.map(String.init) ?? "all"
        info("[Headless] project=\(project.name) doc_order=\(orderLabel) doc_limit=\(limitLabel) files=\(files.count)/\(orderedFiles.count):")
        for (i, f) in files.enumerated() {
            info("[Headless]   [\(i + 1)] \(f.displayName)")
        }

        guard aiService.isConfigured else {
            error("[Headless] AI service not configured (no API key for \(aiService.selectedBackendType.rawValue))")
            exit(3)
        }

        let pipeline = ExtractionPipeline()
        let runStart = Date()

        var failedFiles: [String] = []
        for (idx, file) in files.enumerated() {
            let tag = "[\(idx + 1)/\(files.count)]"
            info("[Headless] \(tag) resolving bookmark: \(file.displayName)")

            let url: URL
            if let resolved = projectsManager.resolveURL(for: project.id, fileID: file.id) {
                url = resolved
            } else if FileManager.default.fileExists(atPath: file.lastKnownPath) {
                url = URL(fileURLWithPath: file.lastKnownPath)
                warning("[Headless] \(tag) bookmark resolve failed; using lastKnownPath for \(file.displayName)")
            } else {
                error("[Headless] \(tag) bookmark resolve failed: \(file.displayName) - skipping")
                continue
            }

            let didStart = url.startAccessingSecurityScopedResource()
            if !didStart {
                warning("[Headless] \(tag) startAccessingSecurityScopedResource returned false; proceeding anyway")
            }

            guard let pdf = PDFDocument(url: url) else {
                error("[Headless] \(tag) PDFDocument(url:) failed for \(file.displayName) - skipping")
                if didStart { url.stopAccessingSecurityScopedResource() }
                continue
            }

            let docStart = Date()
            info("[Headless] \(tag) starting extraction: \(file.displayName) (\(pdf.pageCount) pages)")
            graph.documentProcessingState[url] = .processing
            let succeeded = await pipeline.processPages(
                document: pdf,
                documentURL: url,
                pageRange: 0..<pdf.pageCount,
                graph: graph,
                aiService: aiService,
                mode: config.mode
            )
            let elapsed = Date().timeIntervalSince(docStart)
            if succeeded {
                info("[Headless] \(tag) DONE in \(String(format: "%.1f", elapsed))s: live graph now \(graph.nodeCount)n/\(graph.edgeCount)e (\(file.displayName))")
            } else {
                failedFiles.append(file.displayName)
                error("[Headless] \(tag) FAILED in \(String(format: "%.1f", elapsed))s: live graph now \(graph.nodeCount)n/\(graph.edgeCount)e (\(file.displayName))")
            }

            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Force any pending debounced saves to flush before exit so the harness
        // caller sees on-disk graph files in a stable state.
        GraphStore.shared.flushPendingSave()

        let total = Date().timeIntervalSince(runStart)
        if !failedFiles.isEmpty {
            error("[Headless] failed \(failedFiles.count)/\(files.count) file(s): \(failedFiles.joined(separator: ", "))")
            exit(4)
        }
        info("[Headless] all done in \(String(format: "%.1f", total))s: live graph \(graph.nodeCount)n/\(graph.edgeCount)e - exiting")

        // Brief settle delay so async file writes complete before exit().
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
    }
}
