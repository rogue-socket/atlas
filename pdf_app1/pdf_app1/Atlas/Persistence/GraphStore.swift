//
//  GraphStore.swift
//  Atlas
//
//  Persistent storage for knowledge graphs
//  Stores one graph file per document, keyed by URL hash
//

import Foundation
import os.log

private let log = AtlasLogger.graph

class GraphStore {
    static let shared = GraphStore()

    private let fileManager = FileManager.default
    private let saveDebouncer = Debouncer(delay: 1.0, queue: .global(qos: .utility))

    private var graphsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Atlas/graphs", isDirectory: true)
    }

    init() {
        try? fileManager.createDirectory(at: graphsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - File Path Helpers

    private func graphFileURL(for documentURL: URL) -> URL {
        graphsDirectory.appendingPathComponent("\(documentURL.absoluteString.sha256HexPrefix16).json")
    }

    private func projectGraphFileURL(for projectID: UUID) -> URL {
        graphsDirectory.appendingPathComponent("project_\(projectID.uuidString).json")
    }

    // MARK: - Save / Load per Document

    private struct StoredGraph: Codable {
        let mtime: TimeInterval?
        let size: Int?
        let payload: Data
    }

    private func currentMtimeAndSize(for documentURL: URL) -> (TimeInterval?, Int?) {
        guard let attrs = try? fileManager.attributesOfItem(atPath: documentURL.path) else {
            return (nil, nil)
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
        let size = attrs[.size] as? Int
        return (mtime, size)
    }

    // Writes already-encoded graph bytes to disk. Used by the debounced
    // save path so the work item can run on a background queue without
    // touching `KnowledgeGraph` state (which is not thread-safe).
    private func writeStoredGraph(payload: Data, nodeCount: Int, edgeCount: Int, for documentURL: URL) {
        do {
            let (mtime, size) = currentMtimeAndSize(for: documentURL)
            let stored = StoredGraph(mtime: mtime, size: size, payload: payload)
            let data = try JSONEncoder().encode(stored)
            let fileURL = graphFileURL(for: documentURL)
            try data.write(to: fileURL, options: .atomic)
            log.info("[GraphStore] Saved graph for \(documentURL.lastPathComponent): \(nodeCount) nodes, \(edgeCount) edges (\(data.count) bytes)")
        } catch {
            log.error("[GraphStore] Failed to save graph for \(documentURL.lastPathComponent): \(error)")
        }
    }

    /// Returns the raw graph payload bytes for the given document URL — the
    /// same bytes that should be passed to `KnowledgeGraph.decode(from:)`. Nil
    /// if no fresh graph exists or the cached file is stale. Lets callers that
    /// already hold a `KnowledgeGraph` (e.g. an `@Environment`-injected one)
    /// decode directly, avoiding the decode-then-encode-then-decode round trip
    /// that an intermediate `KnowledgeGraph` would require.
    func loadPayload(for documentURL: URL) -> Data? {
        let fileURL = graphFileURL(for: documentURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            log.info("[GraphStore] No saved graph for \(documentURL.lastPathComponent)")
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("[GraphStore] Failed to read graph file for \(documentURL.lastPathComponent): \(error)")
            return nil
        }

        // New format: invalidate when source mtime or size changed since save.
        if let stored = try? JSONDecoder().decode(StoredGraph.self, from: data) {
            let (currentMtime, currentSize) = currentMtimeAndSize(for: documentURL)
            if let saved = stored.mtime, let cur = currentMtime, abs(saved - cur) > 1.0 {
                log.info("[GraphStore] Stale graph (mtime changed) for \(documentURL.lastPathComponent), invalidating")
                return nil
            }
            if let saved = stored.size, let cur = currentSize, saved != cur {
                log.info("[GraphStore] Stale graph (size changed) for \(documentURL.lastPathComponent), invalidating")
                return nil
            }
            return stored.payload
        }

        // Legacy format (pre-StoredGraph): the file IS the payload.
        return data
    }

    func load(for documentURL: URL) -> KnowledgeGraph? {
        guard let payload = loadPayload(for: documentURL) else { return nil }
        let graph = KnowledgeGraph()
        do {
            try graph.decode(from: payload)
            log.info("[GraphStore] Loaded graph for \(documentURL.lastPathComponent): \(graph.nodeCount) nodes, \(graph.edgeCount) edges")
            return graph
        } catch {
            log.error("[GraphStore] Failed to decode graph for \(documentURL.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: - Project-Wide Load (multi-anchor reconciliation)

    /// Loads every per-document graph for the given URLs and merges them
    /// into one `KnowledgeGraph`. On UUID collision (the same node appears
    /// in multiple per-doc files because cross-doc merging has shared
    /// entities across documents), the entry with the latest
    /// `lastModified` stamp wins — see `KnowledgeGraph.merge(from:)`.
    /// Edges are deduped by tuple identity.
    ///
    /// Used by callers that want the full project graph in memory rather
    /// than one doc at a time (e.g. the future Document tab that shows
    /// cross-doc connections).
    func loadProjectWideGraph(documentURLs: [URL]) -> KnowledgeGraph {
        let merged = KnowledgeGraph()
        var loaded = 0
        var skipped = 0
        for url in documentURLs {
            guard let payload = loadPayload(for: url) else {
                skipped += 1
                continue
            }
            do {
                // Scope to nodes anchored in `url` to defensively strip
                // cross-doc bloat from legacy per-doc files written before
                // B4's save-side filter.
                try merged.mergeSubgraph(from: payload, scopedTo: url)
                loaded += 1
            } catch {
                log.error("[GraphStore] loadProjectWideGraph: decode failed for \(url.lastPathComponent): \(error)")
                skipped += 1
            }
        }
        log.info("[GraphStore] loadProjectWideGraph: merged \(loaded)/\(documentURLs.count) doc graph(s), \(skipped) skipped → \(merged.nodeCount) nodes, \(merged.edgeCount) edges")
        return merged
    }

    // MARK: - Save / Load per Project

    func saveProjectGraph(_ graph: KnowledgeGraph, projectID: UUID) {
        do {
            let data = try graph.encode()
            let fileURL = projectGraphFileURL(for: projectID)
            try data.write(to: fileURL, options: .atomic)
            log.info("[GraphStore] Saved project graph \(projectID.uuidString.prefix(8)): \(graph.nodeCount) nodes, \(graph.edgeCount) edges (\(data.count) bytes)")
        } catch {
            log.error("[GraphStore] Failed to save project graph \(projectID): \(error)")
        }
    }

    func loadProjectGraph(projectID: UUID) -> KnowledgeGraph? {
        let fileURL = projectGraphFileURL(for: projectID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            log.info("[GraphStore] No saved project graph for \(projectID.uuidString.prefix(8))")
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let graph = KnowledgeGraph()
            try graph.decode(from: data)
            log.info("[GraphStore] Loaded project graph \(projectID.uuidString.prefix(8)): \(graph.nodeCount) nodes, \(graph.edgeCount) edges")
            return graph
        } catch {
            log.error("[GraphStore] Failed to load project graph \(projectID): \(error)")
            return nil
        }
    }

    // MARK: - Debounced Save

    func scheduleSave(_ graph: KnowledgeGraph, for documentURL: URL) {
        // Encode synchronously on the caller's thread so the work item
        // only captures a value-type payload (Data). Previously the work
        // item held the KnowledgeGraph reference and called encode() on
        // the background queue, racing against ongoing mutations to
        // nodes/edges from the actor that owns the graph.
        //
        // Filtered to this document's anchored nodes (+ edges between
        // them) so per-doc files don't denormalize the whole project
        // graph under the 4-level multi-doc memory model.
        let payload: Data
        let nodeCount: Int
        let edgeCount: Int
        do {
            let snapshot = try graph.encodeSubgraph(for: documentURL)
            payload = snapshot.data
            nodeCount = snapshot.nodeCount
            edgeCount = snapshot.edgeCount
        } catch {
            log.error("[GraphStore] Failed to encode subgraph for \(documentURL.lastPathComponent): \(error)")
            return
        }

        saveDebouncer.schedule { [weak self] in
            self?.writeStoredGraph(
                payload: payload,
                nodeCount: nodeCount,
                edgeCount: edgeCount,
                for: documentURL
            )
        }
    }

    // MARK: - Flush

    /// Immediately executes any pending debounced save. Call on app termination.
    func flushPendingSave() {
        saveDebouncer.flush()
    }

    // MARK: - Delete

    func deleteGraph(for documentURL: URL) {
        let fileURL = graphFileURL(for: documentURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            log.info("[GraphStore] deleteGraph: no graph on disk for \(documentURL.lastPathComponent)")
            return
        }
        do {
            try fileManager.removeItem(at: fileURL)
            log.info("[GraphStore] deleteGraph: removed \(fileURL.lastPathComponent) for \(documentURL.lastPathComponent)")
        } catch {
            log.error("[GraphStore] deleteGraph: failed for \(documentURL.lastPathComponent): \(error)")
        }
    }

    func deleteProjectGraph(projectID: UUID) {
        let fileURL = projectGraphFileURL(for: projectID)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            log.info("[GraphStore] deleteProjectGraph: no graph on disk for project \(projectID.uuidString.prefix(8))")
            return
        }
        do {
            try fileManager.removeItem(at: fileURL)
            log.info("[GraphStore] deleteProjectGraph: removed graph for project \(projectID.uuidString.prefix(8))")
        } catch {
            log.error("[GraphStore] deleteProjectGraph: failed for project \(projectID): \(error)")
        }
    }

    // MARK: - Query

    func hasGraph(for documentURL: URL) -> Bool {
        fileManager.fileExists(atPath: graphFileURL(for: documentURL).path)
    }

    // MARK: - Orphan Sweep

    /// Per-doc graph files are named `<sha256HexPrefix16(url)>.json`. The
    /// sweep is only authorized to delete that family. Every other JSON file
    /// in `Atlas/graphs/` is owned by a different subsystem and must be left
    /// alone: `project_*` (project-wide graphs, separate lifecycle),
    /// `embeddings_*` (`EmbeddingCacheStore`), `etr_audit_*` (resolver audit
    /// sidecars). Forgetting one here means silent data loss on next launch.
    static func isSweepablePerDocGraphFile(named name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        if name.hasPrefix("project_") { return false }
        if name.hasPrefix("embeddings_") { return false }
        if name.hasPrefix("etr_audit_") { return false }
        return true
    }

    /// Deletes per-document graph files whose URL hash is not in `aliveURLs`.
    /// Project graphs (`project_*.json`) are skipped — those have their own
    /// lifecycle tied to `ProjectsManager.deleteProject`.
    /// Returns the number of files deleted.
    @discardableResult
    func sweepOrphans(aliveURLs: Set<URL>) -> Int {
        let aliveHashes = Set(aliveURLs.map { $0.absoluteString.sha256HexPrefix16 })
        log.info("[GraphStore] sweepOrphans: \(aliveURLs.count) alive URL(s) → \(aliveHashes.count) unique hash(es)")

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: graphsDirectory, includingPropertiesForKeys: [.fileSizeKey])
        } catch {
            log.error("[GraphStore] sweepOrphans: failed to list \(self.graphsDirectory.path): \(error)")
            return 0
        }

        var scanned = 0
        var deleted = 0
        var freedBytes: Int = 0
        var keptCount = 0
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard Self.isSweepablePerDocGraphFile(named: name) else { continue }
            scanned += 1

            let hash = String(name.dropLast(".json".count))
            if aliveHashes.contains(hash) {
                keptCount += 1
                continue
            }

            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try fileManager.removeItem(at: fileURL)
                deleted += 1
                freedBytes += size
                log.info("[GraphStore] sweepOrphans: deleted orphan \(name) (\(size) bytes)")
            } catch {
                log.error("[GraphStore] sweepOrphans: failed to delete \(name): \(error)")
            }
        }
        log.info("[GraphStore] sweepOrphans: scanned=\(scanned) kept=\(keptCount) deleted=\(deleted) freedBytes=\(freedBytes)")
        return deleted
    }
}
