import XCTest
@testable import pdf_app1

/// Tests for the on-disk embedding cache used by ETR stage 3.
/// Hash-keyed schema (post-2026-05-18): round-trip + lookup + orphan cleanup.
final class EmbeddingCacheTests: XCTestCase {

    // MARK: - In-memory behavior

    func test_vector_returnsValue_whenHashMatches() {
        var cache = EmbeddingCache.empty(modelIdentifier: "gemini-embedding-2-preview",
                                         vectorDimension: 3)
        cache.put(contentHash: "abc", vector: [0.1, 0.2, 0.3])
        XCTAssertEqual(cache.vector(forHash: "abc"), [0.1, 0.2, 0.3])
    }

    func test_vector_returnsNil_whenHashMissing() {
        let cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 3)
        XCTAssertNil(cache.vector(forHash: "never-inserted"))
    }

    func test_put_overwritesExistingHash() {
        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 1)
        cache.put(contentHash: "h", vector: [1.0])
        cache.put(contentHash: "h", vector: [2.0])
        XCTAssertEqual(cache.vector(forHash: "h"), [2.0])
    }

    func test_retain_dropsEntriesNotInLiveSet() {
        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 1)
        cache.put(contentHash: "k", vector: [1.0])
        cache.put(contentHash: "d", vector: [2.0])
        cache.retain(["k"])
        XCTAssertEqual(cache.entries.count, 1)
        XCTAssertNotNil(cache.vector(forHash: "k"))
        XCTAssertNil(cache.vector(forHash: "d"))
    }

    func test_retain_keepsSharedHash_acrossMultipleLiveNodes() {
        // Two live nodes happen to share the same content (same label/type/summary)
        // — the cache holds one vector for both. retain() must keep it.
        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 1)
        cache.put(contentHash: "shared", vector: [9.0])
        cache.retain(["shared"]) // single set entry covers any number of live nodes
        XCTAssertEqual(cache.vector(forHash: "shared"), [9.0])
    }

    // MARK: - Round-trip Codable

    func test_codable_roundTrip_preservesAllFields() throws {
        var cache = EmbeddingCache.empty(modelIdentifier: "gemini-embedding-2-preview",
                                         vectorDimension: 3072)
        cache.put(contentHash: "h", vector: [Float](repeating: 0.5, count: 4))

        let data = try JSONEncoder().encode(cache)
        let restored = try JSONDecoder().decode(EmbeddingCache.self, from: data)

        XCTAssertEqual(restored.modelIdentifier, "gemini-embedding-2-preview")
        XCTAssertEqual(restored.vectorDimension, 3072)
        XCTAssertEqual(restored.entries["h"], [0.5, 0.5, 0.5, 0.5])
    }

    func test_codable_decode_failsOn_legacyUUIDKeyedSchema() {
        // Pre-2026-05-18 on-disk shape: values were `{contentHash, vector}`
        // structs, not bare vectors. Must fail to decode so the store treats
        // it as cold-start and replaces it on next save.
        let legacyJSON = """
        {
          "modelIdentifier": "m",
          "vectorDimension": 2,
          "entries": {
            "\(UUID().uuidString)": {"contentHash": "h", "vector": [0.1, 0.9]}
          }
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(EmbeddingCache.self, from: legacyJSON))
    }

    // MARK: - On-disk store

    func test_store_loadReturnsNil_whenNoFile() {
        let throwawayProjectID = UUID()
        // Best-effort cleanup in case a prior run left a file behind.
        try? FileManager.default.removeItem(at: EmbeddingCacheStore.fileURL(for: throwawayProjectID))
        XCTAssertNil(EmbeddingCacheStore.load(for: throwawayProjectID))
    }

    func test_store_saveThenLoad_roundTripsCache() throws {
        let throwawayProjectID = UUID()
        defer {
            try? FileManager.default.removeItem(at: EmbeddingCacheStore.fileURL(for: throwawayProjectID))
        }

        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 2)
        cache.put(contentHash: "h", vector: [0.1, 0.9])
        try EmbeddingCacheStore.save(cache, for: throwawayProjectID)

        let loaded = EmbeddingCacheStore.load(for: throwawayProjectID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.entries["h"], [0.1, 0.9])
    }

    func test_store_legacyFileOnDisk_loadsAsNil_andSaveOverwrites() throws {
        // Writes a pre-2026-05-18 legacy-format JSON to disk, confirms load()
        // returns nil (treating it as cold-start), then writes a new cache and
        // confirms the file is replaced with the hash-keyed schema.
        let pid = UUID()
        let url = EmbeddingCacheStore.fileURL(for: pid)
        defer { try? FileManager.default.removeItem(at: url) }

        let legacyJSON = """
        {
          "modelIdentifier": "m",
          "vectorDimension": 2,
          "entries": {
            "\(UUID().uuidString)": {"contentHash": "h", "vector": [0.1, 0.9]}
          }
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try legacyJSON.write(to: url, options: .atomic)

        XCTAssertNil(EmbeddingCacheStore.load(for: pid), "Legacy schema must not decode")

        var fresh = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 2)
        fresh.put(contentHash: "new", vector: [1.0, 0.0])
        try EmbeddingCacheStore.save(fresh, for: pid)

        let reloaded = EmbeddingCacheStore.load(for: pid)
        XCTAssertEqual(reloaded?.entries["new"], [1.0, 0.0])
    }

    func test_store_fileURL_isUnderGraphsDirectory_andNamedByProjectID() {
        let pid = UUID()
        let url = EmbeddingCacheStore.fileURL(for: pid)
        XCTAssertEqual(url.lastPathComponent, "embeddings_\(pid.uuidString).json")
        XCTAssertTrue(url.path.contains("Atlas/graphs/"))
    }
}
