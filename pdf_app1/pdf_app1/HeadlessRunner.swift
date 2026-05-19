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

struct HeadlessRunnerConfig {
    let projectName: String
    let mode: ExtractionMode

    /// Parse `--headless-extract --project <name> [--mode fast|deep]` from CommandLine args.
    /// Returns nil when the headless flag is absent or project name is missing.
    static func parse(from args: [String]) -> HeadlessRunnerConfig? {
        guard args.contains("--headless-extract") else { return nil }
        var projectName: String?
        var mode: ExtractionMode = .fast
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
            i += 1
        }
        guard let name = projectName else {
            AtlasLogger.headless.error("[Headless] --headless-extract requires --project <name>")
            return nil
        }
        return HeadlessRunnerConfig(projectName: name, mode: mode)
    }
}

@MainActor
final class HeadlessRunner {
    private let log = AtlasLogger.headless

    /// Drives sequential per-doc extraction for every file in the named project,
    /// in alphabetical-by-displayName order. Exits the process when complete so
    /// `open --wait-apps` callers can read the resulting graph files.
    func run(config: HeadlessRunnerConfig,
             projectsManager: ProjectsManager,
             aiService: AIServiceManager,
             graph: KnowledgeGraph) async {
        log.info("[Headless] start: project=\(config.projectName, privacy: .public) mode=\(config.mode.rawValue, privacy: .public)")

        // Wait for ProjectsManager to hydrate (async load). Cap at 10s.
        let deadline = Date().addingTimeInterval(10)
        while !projectsManager.didLoadInitialState {
            if Date() > deadline {
                log.error("[Headless] timed out waiting for ProjectsManager (10s)")
                exit(2)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        log.info("[Headless] projects loaded: \(projectsManager.projects.count) project(s)")

        guard let project = projectsManager.projects.first(where: { $0.name == config.projectName }) else {
            let names = projectsManager.projects.map { $0.name }.joined(separator: ", ")
            log.error("[Headless] project not found: \"\(config.projectName, privacy: .public)\" (available: [\(names, privacy: .public)])")
            exit(2)
        }

        let files = project.files.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        log.info("[Headless] project=\(project.name, privacy: .public) files=\(files.count):")
        for (i, f) in files.enumerated() {
            log.info("[Headless]   [\(i + 1)] \(f.displayName)")
        }

        guard aiService.isConfigured else {
            log.error("[Headless] AI service not configured (no API key for \(aiService.selectedBackendType.rawValue))")
            exit(3)
        }

        let pipeline = ExtractionPipeline()
        let runStart = Date()

        for (idx, file) in files.enumerated() {
            let tag = "[\(idx + 1)/\(files.count)]"
            log.info("[Headless] \(tag) resolving bookmark: \(file.displayName, privacy: .public)")

            guard let url = projectsManager.resolveURL(for: project.id, fileID: file.id) else {
                log.error("[Headless] \(tag) bookmark resolve failed: \(file.displayName, privacy: .public) — skipping")
                continue
            }

            let didStart = url.startAccessingSecurityScopedResource()
            if !didStart {
                log.warning("[Headless] \(tag) startAccessingSecurityScopedResource returned false; proceeding anyway")
            }

            guard let pdf = PDFDocument(url: url) else {
                log.error("[Headless] \(tag) PDFDocument(url:) failed for \(file.displayName, privacy: .public) — skipping")
                if didStart { url.stopAccessingSecurityScopedResource() }
                continue
            }

            let docStart = Date()
            log.info("[Headless] \(tag) starting extraction: \(file.displayName, privacy: .public) (\(pdf.pageCount) pages)")
            graph.documentProcessingState[url] = .processing
            await pipeline.processPages(
                document: pdf,
                documentURL: url,
                pageRange: 0..<pdf.pageCount,
                graph: graph,
                aiService: aiService,
                mode: config.mode
            )
            let elapsed = Date().timeIntervalSince(docStart)
            log.info("[Headless] \(tag) DONE in \(String(format: "%.1f", elapsed))s: live graph now \(graph.nodeCount)n/\(graph.edgeCount)e (\(file.displayName, privacy: .public))")

            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Force any pending debounced saves to flush before exit so the harness
        // caller sees on-disk graph files in a stable state.
        GraphStore.shared.flushPendingSave()

        let total = Date().timeIntervalSince(runStart)
        log.info("[Headless] all done in \(String(format: "%.1f", total))s: live graph \(graph.nodeCount)n/\(graph.edgeCount)e — exiting")

        // Brief settle delay so async file writes complete before exit().
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
    }
}
