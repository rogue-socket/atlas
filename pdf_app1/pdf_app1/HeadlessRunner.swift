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
    /// When true, run ETR (Extract-Then-Resolve) after all per-doc extraction
    /// completes. Triggers `EmbeddingResolver.resolve(...)` + `EmbeddingMergeApplier.apply(...)`
    /// on the project-wide graph. Requires an embedding backend configured
    /// in `AIServiceManager.selectedEmbeddingBackendType`.
    let runETR: Bool
    /// When true, skip per-doc extraction and run ETR against the existing
    /// project graph on disk. Implies `runETR = true`. Designed for the
    /// threshold-tuning loop: change a flag, re-run, embedding cache hits,
    /// only resolver + applier execute (~seconds vs minutes for full extract).
    let etrOnly: Bool
    /// Optional threshold overrides. `nil` = use `ResolverThresholds.default`.
    let etrThresholds: ResolverThresholds?

    /// Parse `--headless-extract --project <name> [--mode fast|deep] [--etr]
    /// [--auto-merge N] [--adj-floor N] [--adj-batch N]` from CommandLine args.
    /// Returns nil when the headless flag is absent or project name is missing.
    static func parse(from args: [String]) -> HeadlessRunnerConfig? {
        guard args.contains("--headless-extract") else { return nil }
        var projectName: String?
        var mode: ExtractionMode = .fast
        var runETR = false
        var etrOnly = false
        var autoMerge: Float?
        var adjFloor: Float?
        var adjBatch: Int?
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--project", i + 1 < args.count {
                projectName = args[i + 1]; i += 2; continue
            }
            if a == "--mode", i + 1 < args.count {
                mode = ExtractionMode(rawValue: args[i + 1]) ?? .fast
                i += 2; continue
            }
            if a == "--etr" {
                runETR = true; i += 1; continue
            }
            if a == "--etr-only" {
                runETR = true; etrOnly = true; i += 1; continue
            }
            if a == "--auto-merge", i + 1 < args.count {
                autoMerge = Float(args[i + 1]); i += 2; continue
            }
            if a == "--adj-floor", i + 1 < args.count {
                adjFloor = Float(args[i + 1]); i += 2; continue
            }
            if a == "--adj-batch", i + 1 < args.count {
                adjBatch = Int(args[i + 1]); i += 2; continue
            }
            i += 1
        }
        guard let name = projectName else {
            AtlasLogger.headless.error("[Headless] --headless-extract requires --project <name>")
            return nil
        }
        let thresholds: ResolverThresholds? = (autoMerge != nil || adjFloor != nil || adjBatch != nil)
            ? ResolverThresholds(
                autoMerge: autoMerge ?? ResolverThresholds.default.autoMerge,
                adjudicationFloor: adjFloor ?? ResolverThresholds.default.adjudicationFloor,
                adjudicationBatchSize: adjBatch ?? ResolverThresholds.default.adjudicationBatchSize
            )
            : nil
        return HeadlessRunnerConfig(projectName: name, mode: mode,
                                    runETR: runETR, etrOnly: etrOnly,
                                    etrThresholds: thresholds)
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

        let runStart = Date()

        // --etr-only: skip extraction. Load existing project graph into the
        // injected `graph` (which started empty) so ETR runs against the
        // prior extraction without re-spending the LLM extract budget.
        if config.etrOnly {
            log.info("[Headless] --etr-only: skipping per-doc extraction; loading existing project graph")
            if let loaded = GraphStore.shared.loadProjectGraph(projectID: project.id) {
                graph.merge(from: loaded)
                log.info("[Headless] --etr-only: loaded \(graph.nodeCount)n/\(graph.edgeCount)e from project graph")
            } else {
                log.error("[Headless] --etr-only: no project graph on disk for \(project.id.uuidString.prefix(8)) — nothing to resolve")
                exit(4)
            }
            await runETR(config: config, aiService: aiService, graph: graph, projectID: project.id)
            GraphStore.shared.saveProjectGraph(graph, projectID: project.id)
            GraphStore.shared.flushPendingSave()
            let total = Date().timeIntervalSince(runStart)
            log.info("[Headless] --etr-only done in \(String(format: "%.1f", total))s — exiting")
            try? await Task.sleep(for: .milliseconds(500))
            exit(0)
        }

        let pipeline = ExtractionPipeline()

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
                projectID: project.id,
                mode: config.mode
            )
            let elapsed = Date().timeIntervalSince(docStart)
            log.info("[Headless] \(tag) DONE in \(String(format: "%.1f", elapsed))s: live graph now \(graph.nodeCount)n/\(graph.edgeCount)e (\(file.displayName, privacy: .public))")

            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Save project graph before ETR so the on-disk state matches in-memory
        // (ETR mutates `graph` in place; we want a snapshot of the pre-ETR
        // graph for diff/audit purposes).
        GraphStore.shared.saveProjectGraph(graph, projectID: project.id)
        GraphStore.shared.flushPendingSave()

        if config.runETR {
            await runETR(config: config, aiService: aiService, graph: graph, projectID: project.id)
            // Re-save after ETR mutates the graph.
            GraphStore.shared.saveProjectGraph(graph, projectID: project.id)
            GraphStore.shared.flushPendingSave()
        }

        let total = Date().timeIntervalSince(runStart)
        log.info("[Headless] all done in \(String(format: "%.1f", total))s: live graph \(graph.nodeCount)n/\(graph.edgeCount)e — exiting")

        // Brief settle delay so async file writes complete before exit().
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
    }

    /// Run ETR stages 3 + 4 against the project-wide graph. Logs counts at
    /// each step; non-fatal on any embedding/LLM failure (logs + continues
    /// so the post-extraction graph still saves cleanly).
    private func runETR(config: HeadlessRunnerConfig,
                        aiService: AIServiceManager,
                        graph: KnowledgeGraph,
                        projectID: UUID) async {
        guard let embeddingBackend = aiService.createEmbeddingBackend() else {
            log.error("[Headless] --etr: no embedding backend configured; skipping ETR")
            return
        }
        let llmBackend = aiService.createBackend()
        if llmBackend == nil {
            log.warning("[Headless] --etr: no LLM backend; adjudication band will be dropped")
        }

        let thresholds = config.etrThresholds ?? .default
        let etrStart = Date()
        log.info("[Headless] ETR start: embed=\(embeddingBackend.modelIdentifier, privacy: .public) dim=\(embeddingBackend.vectorDimension) pre-graph=\(graph.nodeCount)n/\(graph.edgeCount)e")

        let plan: MergePlan
        do {
            plan = try await EmbeddingResolver.resolve(
                graph: graph,
                projectID: projectID,
                embeddingBackend: embeddingBackend,
                llmBackend: llmBackend,
                thresholds: thresholds
            )
        } catch {
            log.error("[Headless] ETR resolve failed: \(error.localizedDescription, privacy: .public) — skipping apply")
            return
        }

        let result = EmbeddingMergeApplier.apply(plan, to: graph)
        let etrElapsed = Date().timeIntervalSince(etrStart)
        log.info("[Headless] ETR done in \(String(format: "%.1f", etrElapsed))s: plan=\(plan.decisions.count) decisions; applied=\(result.groupsApplied) groups, removed=\(result.nodesRemoved) nodes, rewrote=\(result.edgesRewritten) edges, deduped=\(result.edgesDeduplicated); post-graph=\(graph.nodeCount)n/\(graph.edgeCount)e")
    }
}
