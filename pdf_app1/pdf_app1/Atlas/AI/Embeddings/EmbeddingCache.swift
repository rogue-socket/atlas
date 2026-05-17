//
//  EmbeddingCache.swift
//  Atlas
//
//  Project-wide on-disk cache of node embeddings. One JSON file per project
//  (mirrors `GraphStore`'s per-project file pattern). Sits next to the
//  existing `project_<UUID>.json` in `Atlas/graphs/`.
//
//  Keyed by `contentHash` — `sha256(label + ":" + type + ":" + (summary ?? ""))`
//  — not by node UUID. Cache hits survive re-extractions that mint new node
//  UUIDs for unchanged content, and label/type/summary edits correctly miss
//  (the new hash maps to a fresh embed instead of serving a stale vector).
//
//  Invalidation:
//   - Whole-file: top-level `modelIdentifier` / `vectorDimension` mismatch ⇒
//     discard cache. Guards against mixing vectors from different embedding
//     models (different vector spaces, often different dimensions).
//   - Per-entry: re-key by hash makes per-entry invalidation implicit —
//     content change ⇒ new hash ⇒ cache miss ⇒ re-embed.
//

import Foundation
import os.log

struct EmbeddingCache: Codable, Sendable {
    var modelIdentifier: String
    var vectorDimension: Int
    /// Keyed by `contentHash` (see `EmbeddingResolver.contentHash(for:)`).
    var entries: [String: [Float]]

    static func empty(modelIdentifier: String, vectorDimension: Int) -> EmbeddingCache {
        EmbeddingCache(modelIdentifier: modelIdentifier,
                       vectorDimension: vectorDimension,
                       entries: [:])
    }

    func vector(forHash hash: String) -> [Float]? {
        entries[hash]
    }

    mutating func put(contentHash: String, vector: [Float]) {
        entries[contentHash] = vector
    }

    /// Drop entries whose hash isn't in the live set. Run before save to
    /// prevent orphan buildup after re-extractions, merges, or label edits.
    mutating func retain(_ liveHashes: Set<String>) {
        entries = entries.filter { liveHashes.contains($0.key) }
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
    /// Decode failure includes the pre-2026-05-18 UUID-keyed schema —
    /// those files self-replace on the next save.
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
            log.error("[EmbedCache] Failed to load \(url.lastPathComponent) (likely legacy UUID-keyed schema — cold-start, will replace on next save): \(error)")
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
