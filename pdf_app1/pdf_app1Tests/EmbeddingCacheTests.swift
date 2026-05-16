import XCTest
@testable import pdf_app1

/// Tests for the on-disk embedding cache used by ETR stage 3.
/// Round-trip + per-entry invalidation + orphan cleanup.
final class EmbeddingCacheTests: XCTestCase {

    // MARK: - In-memory behavior

    func test_vector_returnsValue_whenHashMatches() {
        var cache = EmbeddingCache.empty(modelIdentifier: "gemini-embedding-2-preview",
                                         vectorDimension: 3)
        let id = UUID()
        cache.put(nodeID: id, contentHash: "abc", vector: [0.1, 0.2, 0.3])
        XCTAssertEqual(cache.vector(for: id, expectedHash: "abc"), [0.1, 0.2, 0.3])
    }

    func test_vector_returnsNil_whenHashDiffers() {
        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 3)
        let id = UUID()
        cache.put(nodeID: id, contentHash: "old", vector: [0.1, 0.2, 0.3])
        XCTAssertNil(cache.vector(for: id, expectedHash: "new"))
    }

    func test_vector_returnsNil_whenIDMissing() {
        let cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 3)
        XCTAssertNil(cache.vector(for: UUID(), expectedHash: "h"))
    }

    func test_retain_dropsEntriesNotInLiveSet() {
        var cache = EmbeddingCache.empty(modelIdentifier: "m", vectorDimension: 1)
        let keep = UUID()
        let drop = UUID()
        cache.put(nodeID: keep, contentHash: "k", vector: [1.0])
        cache.put(nodeID: drop, contentHash: "d", vector: [2.0])
        cache.retain([keep])
        XCTAssertEqual(cache.entries.count, 1)
        XCTAssertNotNil(cache.vector(for: keep, expectedHash: "k"))
        XCTAssertNil(cache.vector(for: drop, expectedHash: "d"))
    }

    // MARK: - Round-trip Codable

    func test_codable_roundTrip_preservesAllFields() throws {
        var cache = EmbeddingCache.empty(modelIdentifier: "gemini-embedding-2-preview",
                                         vectorDimension: 3072)
        let id = UUID()
        cache.put(nodeID: id, contentHash: "h", vector: [Float](repeating: 0.5, count: 4))

        let data = try JSONEncoder().encode(cache)
        let restored = try JSONDecoder().decode(EmbeddingCache.self, from: data)

        XCTAssertEqual(restored.modelIdentifier, "gemini-embedding-2-preview")
        XCTAssertEqual(restored.vectorDimension, 3072)
        XCTAssertEqual(restored.entries[id.uuidString]?.contentHash, "h")
        XCTAssertEqual(restored.entries[id.uuidString]?.vector, [0.5, 0.5, 0.5, 0.5])
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
        let id = UUID()
        cache.put(nodeID: id, contentHash: "h", vector: [0.1, 0.9])
        try EmbeddingCacheStore.save(cache, for: throwawayProjectID)

        let loaded = EmbeddingCacheStore.load(for: throwawayProjectID)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.entries[id.uuidString]?.vector, [0.1, 0.9])
    }

    func test_store_fileURL_isUnderGraphsDirectory_andNamedByProjectID() {
        let pid = UUID()
        let url = EmbeddingCacheStore.fileURL(for: pid)
        XCTAssertEqual(url.lastPathComponent, "embeddings_\(pid.uuidString).json")
        XCTAssertTrue(url.path.contains("Atlas/graphs/"))
    }
}
