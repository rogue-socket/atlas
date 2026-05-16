//
//  EmbeddingCache.swift
//  Atlas
//
//  Project-wide on-disk cache of node embeddings. One JSON file per project
//  (mirrors `GraphStore`'s per-project file pattern). Sits next to the
//  existing `project_<UUID>.json` in `Atlas/graphs/`.
//
//  Invalidation has two layers:
//   1. Whole-file: top-level `modelIdentifier` mismatch ⇒ discard cache.
//      Guards against mixing vectors from different embedding models
//      (different vector spaces and often different dimensions).
//   2. Per-entry: `contentHash` is `sha256(label + ":" + type + ":" + (summary ?? ""))`.
//      Mismatch ⇒ re-embed just that node. Resolver handles this layer.
//

import Foundation
import os.log

struct EmbeddingCache: Codable, Sendable {
    var modelIdentifier: String
    var vectorDimension: Int
    /// Keyed by `ConceptNode.id.uuidString`. JSONEncoder rejects UUID-keyed
    /// dictionaries, hence the string indirection.
    var entries: [String: Entry]

    struct Entry: Codable, Sendable {
        let contentHash: String
        let vector: [Float]
    }

    static func empty(modelIdentifier: String, vectorDimension: Int) -> EmbeddingCache {
        EmbeddingCache(modelIdentifier: modelIdentifier,
                       vectorDimension: vectorDimension,
                       entries: [:])
    }

    func vector(for nodeID: UUID, expectedHash: String) -> [Float]? {
        guard let entry = entries[nodeID.uuidString] else { return nil }
        return entry.contentHash == expectedHash ? entry.vector : nil
    }

    mutating func put(nodeID: UUID, contentHash: String, vector: [Float]) {
        entries[nodeID.uuidString] = Entry(contentHash: contentHash, vector: vector)
    }

    /// Drop entries for node IDs no longer present in the live set. Run
    /// before save to prevent orphan buildup after merges.
    mutating func retain(_ liveIDs: Set<UUID>) {
        let liveStrings = Set(liveIDs.map { $0.uuidString })
        entries = entries.filter { liveStrings.contains($0.key) }
    }
}

private let log = AtlasLogger.embedding

enum EmbeddingCacheStore {
    private static let fileManager = FileManager.default

    private static var graphsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Atlas/graphs", isDirectory: true)
    }

    static func fileURL(for projectID: UUID) -> URL {
        graphsDirectory.appendingPathComponent("embeddings_\(projectID.uuidString).json")
    }

    /// Load the cache for the given project. Returns nil when the file
    /// doesn't exist or fails to decode (caller treats nil as cold-start).
    static func load(for projectID: UUID) -> EmbeddingCache? {
        let url = fileURL(for: projectID)
        guard fileManager.fileExists(atPath: url.path) else {
            log.info("[EmbedCache] No cache for project \(projectID.uuidString)")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let cache = try JSONDecoder().decode(EmbeddingCache.self, from: data)
            log.info("[EmbedCache] Loaded \(cache.entries.count) entries (model=\(cache.modelIdentifier), dim=\(cache.vectorDimension))")
            return cache
        } catch {
            log.error("[EmbedCache] Failed to load \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Atomic write of the cache. Creates the graphs directory if needed.
    static func save(_ cache: EmbeddingCache, for projectID: UUID) throws {
        try fileManager.createDirectory(at: graphsDirectory, withIntermediateDirectories: true)
        let url = fileURL(for: projectID)
        let data = try JSONEncoder().encode(cache)
        try data.write(to: url, options: .atomic)
        log.info("[EmbedCache] Saved \(cache.entries.count) entries (\(data.count) bytes) to \(url.lastPathComponent)")
    }
}
