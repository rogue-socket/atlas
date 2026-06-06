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
//   - Namespace: cache filename includes modelIdentifier + vectorDimension, so
//     vectors from different embedding spaces never mix.
//   - Per-entry: re-key by hash makes per-entry invalidation implicit —
//     content change ⇒ new hash ⇒ cache miss ⇒ re-embed.
//

import Foundation
import os.log

struct EmbeddingCacheEntry: Codable, Sendable {
    var vector: [Float]
    var modelIdentifier: String
    var vectorDimension: Int
    var sourceID: String
    var sourcePath: String?
    var chunkID: String
    var chunkText: String
}

struct EmbeddingCache: Codable, Sendable {
    var modelIdentifier: String
    var vectorDimension: Int
    /// Keyed by `contentHash` (see `EmbeddingResolver.contentHash(for:)`).
    var entries: [String: EmbeddingCacheEntry]

    static func empty(modelIdentifier: String, vectorDimension: Int) -> EmbeddingCache {
        EmbeddingCache(modelIdentifier: modelIdentifier,
                       vectorDimension: vectorDimension,
                       entries: [:])
    }

    func vector(forHash hash: String) -> [Float]? {
        entries[hash]?.vector
    }

    mutating func put(
        contentHash: String,
        vector: [Float],
        sourceID: String,
        sourcePath: String?,
        chunkID: String,
        chunkText: String
    ) {
        entries[contentHash] = EmbeddingCacheEntry(
            vector: vector,
            modelIdentifier: modelIdentifier,
            vectorDimension: vectorDimension,
            sourceID: sourceID,
            sourcePath: sourcePath,
            chunkID: chunkID,
            chunkText: chunkText
        )
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

    static func fileURL(for projectID: UUID, modelIdentifier: String, vectorDimension: Int) -> URL {
        let namespace = namespace(modelIdentifier: modelIdentifier, vectorDimension: vectorDimension)
        return graphsDirectory.appendingPathComponent("embeddings_\(projectID.uuidString)_\(namespace).json")
    }

    private static func namespace(modelIdentifier: String, vectorDimension: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeModel = modelIdentifier.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return "\(safeModel)_\(vectorDimension)d"
    }

    /// Load the cache for the given project. Returns nil when the file
    /// doesn't exist or fails to decode (caller treats nil as cold-start).
    /// Decode failure includes the pre-2026-05-18 UUID-keyed schema —
    /// those files self-replace on the next save.
    static func load(for projectID: UUID, modelIdentifier: String, vectorDimension: Int) -> EmbeddingCache? {
        let url = fileURL(for: projectID, modelIdentifier: modelIdentifier, vectorDimension: vectorDimension)
        guard fileManager.fileExists(atPath: url.path) else {
            log.info("[EmbedCache] No cache for project \(projectID.uuidString) model=\(modelIdentifier) dim=\(vectorDimension)")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let cache = try JSONDecoder().decode(EmbeddingCache.self, from: data)
            guard cache.modelIdentifier == modelIdentifier, cache.vectorDimension == vectorDimension else {
                log.error("[EmbedCache] Cache namespace mismatch in \(url.lastPathComponent)")
                return nil
            }
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
        let url = fileURL(for: projectID, modelIdentifier: cache.modelIdentifier, vectorDimension: cache.vectorDimension)
        let data = try JSONEncoder().encode(cache)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        try data.write(to: url, options: .atomic)
        log.info("[EmbedCache] Saved \(cache.entries.count) entries (\(data.count) bytes) to \(url.lastPathComponent)")
    }
}
