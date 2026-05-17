import XCTest
@testable import pdf_app1

/// Guards `GraphStore.sweepOrphans` against deleting non–per-doc-graph
/// files. The sweep walks `Atlas/graphs/` and historically assumed every
/// `.json` that wasn't `project_*` was a per-doc graph keyed by
/// `sha256HexPrefix16(documentURL)`. As new subsystems started writing
/// peer files into the same directory (`embeddings_<projectID>.json`,
/// `etr_audit_<projectID>_<timestamp>.json`), those got silently swept on
/// every launch — the embedding cache's "warm across runs" claim broke
/// for exactly this reason.
final class GraphStoreSweepTests: XCTestCase {
    func test_perDocHashFile_isSweepable() {
        XCTAssertTrue(GraphStore.isSweepablePerDocGraphFile(named: "ae612f9448904b34.json"))
        XCTAssertTrue(GraphStore.isSweepablePerDocGraphFile(named: "b7b3b96e1e929ffe.json"))
    }

    /// Legacy artifact of the retired write-only project-graph pipeline.
    /// No live writer remains; every `project_*.json` on disk is orphan.
    func test_legacyProjectGraph_isSweepable() {
        XCTAssertTrue(GraphStore.isSweepablePerDocGraphFile(named: "project_ABE6D4F9-7F9E-4BD8-B977-57D541824DF3.json"))
    }

    func test_embeddingsCache_isNotSweepable() {
        XCTAssertFalse(GraphStore.isSweepablePerDocGraphFile(named: "embeddings_ABE6D4F9-7F9E-4BD8-B977-57D541824DF3.json"))
    }

    func test_etrAuditSidecar_isNotSweepable() {
        XCTAssertFalse(GraphStore.isSweepablePerDocGraphFile(named: "etr_audit_ABE6D4F9_2026-05-16T22-59-00Z.json"))
    }

    func test_nonJSON_isNotSweepable() {
        XCTAssertFalse(GraphStore.isSweepablePerDocGraphFile(named: "ae612f9448904b34.txt"))
        XCTAssertFalse(GraphStore.isSweepablePerDocGraphFile(named: ".DS_Store"))
    }
}
