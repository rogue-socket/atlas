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
    /// When set, ignore extraction/ETR entirely: load the graph JSON at this
    /// path and score it against the vitacare quality rubric (see `RubricScorer`).
    let scoreRubricPath: String?
    /// When set, ignore extraction: load every per-doc graph JSON in this
    /// directory, merge them, and run the hybrid resolver against the merged
    /// graph. Self-contained — needs no project or security-scoped bookmarks.
    let hybridResolveDir: String?

    init(projectName: String, mode: ExtractionMode, runETR: Bool, etrOnly: Bool,
         etrThresholds: ResolverThresholds?, scoreRubricPath: String?,
         hybridResolveDir: String? = nil) {
        self.projectName = projectName
        self.mode = mode
        self.runETR = runETR
        self.etrOnly = etrOnly
        self.etrThresholds = etrThresholds
        self.scoreRubricPath = scoreRubricPath
        self.hybridResolveDir = hybridResolveDir
    }

    /// Parse `--headless-extract --project <name> [--mode fast|deep] [--etr]
    /// [--auto-merge N] [--adj-floor N] [--adj-batch N]
    /// [--adj-floor-cc N] [--adj-floor-ee N] [--adj-floor-cl N]
    /// [--auto-merge-cc N] [--auto-merge-ee N] [--auto-merge-cl N]`
    /// from CommandLine args. Per-kind overrides (`-cc`/`-ee`/`-cl` suffixes)
    /// map to `ResolverThresholds.{auto-merge,adjudicationFloor}PerKind` and
    /// fall back to the flat field when absent.
    ///
    /// `--score-rubric <path>` is a standalone mode: it scores the graph JSON
    /// at `<path>` against the quality rubric and needs no `--project`.
    ///
    /// Returns nil when the headless flag is absent, or when neither
    /// `--project` nor `--score-rubric` is given.
    static func parse(from args: [String]) -> HeadlessRunnerConfig? {
        guard args.contains("--headless-extract") else { return nil }
        var projectName: String?
        var mode: ExtractionMode = .fast
        var runETR = false
        var etrOnly = false
        var scoreRubricPath: String?
        var hybridResolveDir: String?
        var autoMerge: Float?
        var adjFloor: Float?
        var adjBatch: Int?
        var autoMergePerKind: [EmbeddingResolver.PairKind: Float] = [:]
        var adjFloorPerKind: [EmbeddingResolver.PairKind: Float] = [:]
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
            if a == "--score-rubric", i + 1 < args.count {
                scoreRubricPath = args[i + 1]; i += 2; continue
            }
            if a == "--hybrid-resolve", i + 1 < args.count {
                hybridResolveDir = args[i + 1]; i += 2; continue
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
            if let kind = perKindFlag(prefix: "--auto-merge", a),
               i + 1 < args.count, let v = Float(args[i + 1]) {
                autoMergePerKind[kind] = v; i += 2; continue
            }
            if let kind = perKindFlag(prefix: "--adj-floor", a),
               i + 1 < args.count, let v = Float(args[i + 1]) {
                adjFloorPerKind[kind] = v; i += 2; continue
            }
            i += 1
        }
        // --score-rubric scores a graph file and needs no project; every
        // other mode requires --project <name>.
        let resolvedName: String?
        if let projectName {
            resolvedName = projectName
        } else if scoreRubricPath != nil || hybridResolveDir != nil {
            resolvedName = ""
        } else {
            resolvedName = nil
        }
        guard let name = resolvedName else {
            AtlasLogger.headless.error("[Headless] --headless-extract requires --project <name> (or --score-rubric <path>)")
            return nil
        }
        let anyThresholdFlag = autoMerge != nil || adjFloor != nil || adjBatch != nil
            || !autoMergePerKind.isEmpty || !adjFloorPerKind.isEmpty
        let thresholds: ResolverThresholds? = anyThresholdFlag
            ? ResolverThresholds(
                autoMerge: autoMerge ?? ResolverThresholds.default.autoMerge,
                adjudicationFloor: adjFloor ?? ResolverThresholds.default.adjudicationFloor,
                adjudicationBatchSize: adjBatch ?? ResolverThresholds.default.adjudicationBatchSize,
                autoMergePerKind: autoMergePerKind,
                adjudicationFloorPerKind: adjFloorPerKind
            )
            : nil
        return HeadlessRunnerConfig(projectName: name, mode: mode,
                                    runETR: runETR, etrOnly: etrOnly,
                                    etrThresholds: thresholds,
                                    scoreRubricPath: scoreRubricPath,
                                    hybridResolveDir: hybridResolveDir)
    }

    /// Map a `--<prefix>-{cc|ee|cl}` suffix to its `PairKind`. Returns nil
    /// for any string that doesn't match exactly so unrelated flags pass
    /// through the parser untouched.
    private static func perKindFlag(prefix: String, _ arg: String) -> EmbeddingResolver.PairKind? {
        switch arg {
        case "\(prefix)-cc": return .conceptConcept
        case "\(prefix)-ee": return .entityEntity
        case "\(prefix)-cl": return .crossLevel
        default: return nil
        }
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
        // --score-rubric: score an existing graph file against the quality
        // rubric; needs neither a project nor extraction. RubricScorer exits.
        if let rubricPath = config.scoreRubricPath {
            await RubricScorer.run(graphPath: rubricPath, aiService: aiService, graph: graph)
            return
        }

        if let hybridDir = config.hybridResolveDir {
            await runHybridResolve(dir: hybridDir, aiService: aiService, graph: graph)
            return
        }

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

        if let proOverride = ProcessInfo.processInfo.environment["ATLAS_GEMINI_MODEL"], !proOverride.isEmpty {
            log.info("[Headless] ATLAS_GEMINI_MODEL override: \(proOverride, privacy: .public)")
            aiService.selectedModel = proOverride
        }

        let runStart = Date()

        // Resolve every file's URL up front. Used by --etr-only's project-wide
        // load and by the post-extraction per-doc save loop. Files whose
        // bookmark fails to resolve are dropped here with a warning.
        let projectURLs: [URL] = files.compactMap { file in
            guard let url = projectsManager.resolveURL(for: project.id, fileID: file.id) else {
                log.error("[Headless] bookmark resolve failed up-front: \(file.displayName, privacy: .public) — file will be skipped")
                return nil
            }
            return url
        }

        // --etr-only: skip extraction. Load existing per-doc graphs into the
        // injected `graph` (which started empty) so ETR runs against the
        // prior extraction without re-spending the LLM extract budget.
        if config.etrOnly {
            log.info("[Headless] --etr-only: skipping per-doc extraction; loading existing per-doc graphs")
            let loaded = GraphStore.shared.loadProjectWideGraph(documentURLs: projectURLs)
            guard loaded.nodeCount > 0 else {
                log.error("[Headless] --etr-only: no per-doc graphs on disk for \(project.name, privacy: .public) — nothing to resolve")
                exit(4)
            }
            graph.merge(from: loaded)
            log.info("[Headless] --etr-only: loaded \(graph.nodeCount)n/\(graph.edgeCount)e from per-doc graphs")
            await runETR(config: config, aiService: aiService, graph: graph, projectID: project.id)
            for url in projectURLs { GraphStore.shared.scheduleSave(graph, for: url) }
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
                mode: config.mode
            )
            let elapsed = Date().timeIntervalSince(docStart)
            log.info("[Headless] \(tag) DONE in \(String(format: "%.1f", elapsed))s: live graph now \(graph.nodeCount)n/\(graph.edgeCount)e (\(file.displayName, privacy: .public))")

            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Save per-doc graphs before ETR so the on-disk state matches in-memory
        // (ETR mutates `graph` in place; we want a snapshot of the pre-ETR
        // graph for diff/audit purposes). scheduleSave scopes via
        // encodeSubgraph(for: documentURL) so each file holds only its own
        // anchored nodes + edges between them.
        for url in projectURLs { GraphStore.shared.scheduleSave(graph, for: url) }
        GraphStore.shared.flushPendingSave()

        if config.runETR {
            await runETR(config: config, aiService: aiService, graph: graph, projectID: project.id)
            // Re-save after ETR mutates the graph.
            for url in projectURLs { GraphStore.shared.scheduleSave(graph, for: url) }
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
            let auditDir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Atlas/graphs", isDirectory: true)
            plan = try await EmbeddingResolver.resolve(
                graph: graph,
                projectID: projectID,
                embeddingBackend: embeddingBackend,
                llmBackend: llmBackend,
                thresholds: thresholds,
                auditOutputDir: auditDir
            )
        } catch {
            log.error("[Headless] ETR resolve failed: \(error.localizedDescription, privacy: .public) — skipping apply")
            return
        }

        let result = EmbeddingMergeApplier.apply(plan, to: graph)
        let etrElapsed = Date().timeIntervalSince(etrStart)
        log.info("[Headless] ETR done in \(String(format: "%.1f", etrElapsed))s: plan=\(plan.decisions.count) merges + \(plan.relations.count) relations; applied=\(result.groupsApplied) groups, removed=\(result.nodesRemoved) nodes, rewrote=\(result.edgesRewritten) edges, deduped=\(result.edgesDeduplicated), relations=\(result.relationsAdded); post-graph=\(graph.nodeCount)n/\(graph.edgeCount)e")
    }

    /// `--hybrid-resolve <dir>`: load every per-doc graph JSON in `dir`, merge
    /// them, and run the hybrid resolver (ETR backbone + SCE typed-relation
    /// adjudication) against the merged graph. Self-contained end-to-end
    /// exercise of the hybrid pipeline — needs no project or bookmarks, so it
    /// runs anywhere the graph files and the configured backends are present.
    private func runHybridResolve(dir: String,
                                  aiService: AIServiceManager,
                                  graph: KnowledgeGraph) async {
        let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil) else {
            log.error("[Hybrid] cannot read directory: \(dir, privacy: .public)")
            exit(4)
        }
        // Per-doc graph files only — skip embedding caches, audit sidecars,
        // and legacy project-wide files.
        let graphFiles = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasSuffix(".json")
                && !name.hasPrefix("embeddings_")
                && !name.hasPrefix("etr_audit_")
                && !name.hasPrefix("project_")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !graphFiles.isEmpty else {
            log.error("[Hybrid] no per-doc graph JSON files in \(dir, privacy: .public)")
            exit(4)
        }
        log.info("[Hybrid] loading \(graphFiles.count) graph file(s) from \(dir, privacy: .public)")

        struct StoredEnvelope: Decodable { let payload: Data }
        var loadedDocs = 0
        for file in graphFiles {
            guard let fileData = try? Data(contentsOf: file) else {
                log.warning("[Hybrid] skip unreadable: \(file.lastPathComponent, privacy: .public)")
                continue
            }
            // A GraphStore file is a StoredGraph envelope whose `payload` holds
            // the CodableRepresentation; a bare export is the representation
            // itself. Try the envelope first, fall back to the whole file.
            let payload = (try? JSONDecoder().decode(StoredEnvelope.self, from: fileData))?.payload ?? fileData
            let docGraph = KnowledgeGraph()
            do {
                try docGraph.decode(from: payload)
            } catch {
                log.warning("[Hybrid] skip undecodable \(file.lastPathComponent, privacy: .public): \(error.localizedDescription)")
                continue
            }
            graph.merge(from: docGraph)
            loadedDocs += 1
            log.info("[Hybrid]   + \(file.lastPathComponent, privacy: .public): \(docGraph.nodeCount)n/\(docGraph.edgeCount)e → merged total \(graph.nodeCount)n/\(graph.edgeCount)e")
        }
        guard loadedDocs > 0, graph.nodeCount > 0 else {
            log.error("[Hybrid] nothing loaded — no decodable graphs")
            exit(4)
        }

        let projectID = UUID()
        log.info("[Hybrid] merged \(loadedDocs) doc(s) → \(graph.nodeCount)n/\(graph.edgeCount)e; synthetic projectID=\(projectID.uuidString, privacy: .public)")
        let cfg = HeadlessRunnerConfig(projectName: "", mode: .fast,
                                       runETR: true, etrOnly: true,
                                       etrThresholds: nil, scoreRubricPath: nil)
        await runETR(config: cfg, aiService: aiService, graph: graph, projectID: projectID)
        log.info("[Hybrid] done — resolved graph: \(graph.nodeCount)n/\(graph.edgeCount)e")
        try? await Task.sleep(for: .milliseconds(500))
        exit(0)
    }
}
