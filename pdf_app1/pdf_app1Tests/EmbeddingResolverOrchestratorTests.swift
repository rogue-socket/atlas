import XCTest
@testable import pdf_app1

/// Integration tests for `EmbeddingResolver.resolve(...)` — the async
/// orchestrator that wires embedding cache + backend + LLM adjudication.
/// Uses fake backends; no live API calls. LLM-adjudication path tested
/// end-to-end live via headless harness when stage 4 lands.
final class EmbeddingResolverOrchestratorTests: XCTestCase {

    // MARK: - Fakes

    /// Returns a fixed vector per text via a caller-provided closure.
    /// Tracks `callCount` (number of `embed` invocations — used to assert
    /// cache hits skip the API call).
    final class FakeEmbeddingBackend: AtlasEmbeddingBackend, @unchecked Sendable {
        let displayName = "Fake"
        let modelIdentifier: String
        let vectorDimension: Int
        let isAvailable = true
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
        private let vectorFor: @Sendable (String) -> [Float]

        init(modelID: String = "fake-model",
             dim: Int = 3,
             vectorFor: @escaping @Sendable (String) -> [Float]) {
            self.modelIdentifier = modelID
            self.vectorDimension = dim
            self.vectorFor = vectorFor
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            lock.lock(); _callCount += 1; lock.unlock()
            return texts.map(vectorFor)
        }
    }

    // MARK: - Helpers

    private func anchor(_ path: String) -> SourceAnchor {
        SourceAnchor(documentURL: URL(fileURLWithPath: path),
                     pageIndex: 0, boundingBox: .zero, textSnippet: "")
    }

    private func wipeCacheFile(for projectID: UUID) {
        try? FileManager.default.removeItem(at: EmbeddingCacheStore.fileURL(for: projectID))
    }

    // MARK: - resolve

    func test_resolve_emptyGraph_returnsEmptyPlan() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [0.0, 0.0, 0.0] }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend)
        XCTAssertTrue(plan.decisions.isEmpty)
        XCTAssertEqual(backend.callCount, 0)
    }

    func test_resolve_lessThanTwoEligibleNodes_returnsEmptyPlan_withoutEmbedding() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        // Only document/chapter nodes — not eligible. Plus one concept.
        g.addNode(ConceptNode(label: "d", level: .document))
        g.addNode(ConceptNode(label: "ch", level: .chapter))
        g.addNode(ConceptNode(label: "c1", level: .concept))
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [0.1, 0.2, 0.3] }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend)
        XCTAssertTrue(plan.decisions.isEmpty)
        XCTAssertEqual(backend.callCount, 0, "Single eligible node — no embed needed")
    }

    func test_resolve_exactLabelAcrossDocs_returnsAutoMerge_evenWithOrthogonalVectors() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Helena Vargas", type: .person, summary: "from doc A",
                            sourceAnchors: [anchor("/A.pdf")], level: .entity)
        let b = ConceptNode(label: "helena vargas", type: .person, summary: "from doc B",
                            sourceAnchors: [anchor("/B.pdf")], level: .entity)
        g.addNode(a); g.addNode(b)

        // Vectors are deliberately orthogonal (sim = 0) — exact label match
        // must force-merge regardless.
        let backend = FakeEmbeddingBackend(dim: 3) { text in
            text.contains("from doc A") ? [1, 0, 0] : [0, 1, 0]
        }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend)
        XCTAssertEqual(plan.decisions.count, 1)
        XCTAssertEqual(plan.decisions.first?.reason, .exactLabel)
    }

    func test_resolve_highSimilarityAcrossDocs_returnsHighSimilarity_autoMerge() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Annual Wellness Visit", type: .concept, summary: "preventive checkup",
                            sourceAnchors: [anchor("/A.pdf")], level: .concept)
        let b = ConceptNode(label: "Yearly Health Checkup", type: .concept, summary: "preventive checkup",
                            sourceAnchors: [anchor("/B.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)

        // Identical vectors → sim = 1.0 → auto-merge via highSimilarity branch
        // (not exactLabel, since labels differ).
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [0.5, 0.5, 0.5] }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend)
        XCTAssertEqual(plan.decisions.count, 1)
        XCTAssertEqual(plan.decisions.first?.reason, .highSimilarity)
        XCTAssertEqual(plan.decisions.first?.similarity ?? 0, 1.0, accuracy: 1e-6)
    }

    func test_resolve_lowSimilarity_excludedFromPlan() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Telehealth Platform", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/A.pdf")], level: .concept)
        let b = ConceptNode(label: "Surgical Robotics", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/B.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)

        // Orthogonal vectors → sim = 0 → below 0.85 floor → reject, no
        // decision in the plan. No LLM backend needed because the band
        // classification rejects before adjudication.
        let backend = FakeEmbeddingBackend(dim: 3) { text in
            text.contains("Telehealth") ? [1, 0, 0] : [0, 1, 0]
        }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend)
        XCTAssertTrue(plan.decisions.isEmpty)
    }

    func test_resolve_cacheHit_secondRunSkipsEmbed() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/1.pdf")], level: .concept)
        let b = ConceptNode(label: "B", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/2.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)

        let backend = FakeEmbeddingBackend(dim: 3) { _ in [0.1, 0.2, 0.3] }

        _ = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                embeddingBackend: backend)
        let firstCount = backend.callCount
        XCTAssertGreaterThan(firstCount, 0, "Cold cache should fetch")

        _ = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                embeddingBackend: backend)
        XCTAssertEqual(backend.callCount, firstCount,
                       "Second run should hit on-disk cache and skip the embed call")
    }

    func test_resolve_adjudicationBand_withoutLLM_droppedFromPlan() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "A", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/1.pdf")], level: .concept)
        let b = ConceptNode(label: "B", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/2.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)

        // Two vectors at ~0.90 cosine — in the adjudication band.
        let backend = FakeEmbeddingBackend(dim: 3) { text in
            // Vectors with intentional small angle: cos(angle) ≈ 0.9
            text == "A: concept" ? [1.0, 0.0, 0.0] : [0.9, sqrt(1.0 - 0.81), 0.0]
        }
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend,
                                                       llmBackend: nil)
        // No LLM → adjudication candidates are dropped silently.
        XCTAssertTrue(plan.decisions.isEmpty)
    }

    // MARK: - generateWithRetry

    /// Throws AIError.networkError on the first `failureCount` calls, then
    /// returns `successResponse`. Tracks total call count.
    final class FlakyLLMBackend: AtlasModel, @unchecked Sendable {
        let displayName = "Flaky"
        let modelIdentifier = "flaky-llm"
        let isAvailable = true
        private let lock = NSLock()
        private var _callCount = 0
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return _callCount }
        private let failureCount: Int
        private let successResponse: String
        private let errorToThrow: Error

        init(failureCount: Int,
             successResponse: String = "[]",
             errorToThrow: Error = AIError.networkError(NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]))) {
            self.failureCount = failureCount
            self.successResponse = successResponse
            self.errorToThrow = errorToThrow
        }

        func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] { throw AIError.modelUnavailable("not impl in fake") }
        func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] { throw AIError.modelUnavailable("not impl in fake") }
        func summarizeConcept(_ label: String, sourceText: String) async throws -> String { throw AIError.modelUnavailable("not impl in fake") }
        func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations { throw AIError.modelUnavailable("not impl in fake") }

        func generateRawResponse(prompt: String) async throws -> String {
            lock.lock()
            _callCount += 1
            let n = _callCount
            lock.unlock()
            if n <= failureCount { throw errorToThrow }
            return successResponse
        }
    }

    func test_generateWithRetry_succeedsAfterTransientFailures() async throws {
        let llm = FlakyLLMBackend(failureCount: 2, successResponse: "[true]")
        let result = try await EmbeddingResolver.generateWithRetry(llm: llm, prompt: "x", maxAttempts: 3)
        XCTAssertEqual(result, "[true]")
        XCTAssertEqual(llm.callCount, 3, "Should have called 3 times: 2 failures + 1 success")
    }

    func test_generateWithRetry_throwsAfterExhaustingAttempts() async {
        let llm = FlakyLLMBackend(failureCount: 5)  // more failures than attempts
        do {
            _ = try await EmbeddingResolver.generateWithRetry(llm: llm, prompt: "x", maxAttempts: 3)
            XCTFail("Expected throw after exhausting retries")
        } catch {
            // Expected — any error
        }
        XCTAssertEqual(llm.callCount, 3, "Should have called exactly maxAttempts times")
    }

    func test_generateWithRetry_doesNotRetryOnLogicalError() async {
        // decodingError shouldn't retry — the response is broken in a way
        // retry won't fix.
        let llm = FlakyLLMBackend(failureCount: 5,
                                  errorToThrow: AIError.decodingError("invalid JSON"))
        do {
            _ = try await EmbeddingResolver.generateWithRetry(llm: llm, prompt: "x", maxAttempts: 3)
            XCTFail("Expected throw")
        } catch let error as AIError {
            if case .decodingError = error { /* expected */ } else { XCTFail("Wrong error: \(error)") }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
        XCTAssertEqual(llm.callCount, 1, "decodingError should NOT trigger retry")
    }

    // MARK: - Audit trail

    func test_resolve_writesAuditFile_whenAuditDirProvided() async throws {
        let projectID = UUID()
        let auditDir = FileManager.default.temporaryDirectory.appendingPathComponent("etr-audit-test-\(UUID().uuidString)")
        defer {
            wipeCacheFile(for: projectID)
            try? FileManager.default.removeItem(at: auditDir)
        }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Helena Vargas", type: .person, summary: "ORG",
                            sourceAnchors: [anchor("/org.pdf")], level: .entity)
        let b = ConceptNode(label: "helena vargas", type: .person, summary: "CMP",
                            sourceAnchors: [anchor("/cmp.pdf")], level: .entity)
        g.addNode(a); g.addNode(b)
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [1, 0, 0] }

        _ = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                embeddingBackend: backend,
                                                auditOutputDir: auditDir)

        // Should produce exactly one audit file matching the pattern.
        let files = try FileManager.default.contentsOfDirectory(atPath: auditDir.path)
        let matching = files.filter { $0.hasPrefix("etr_audit_\(projectID.uuidString)") && $0.hasSuffix(".json") }
        XCTAssertEqual(matching.count, 1, "Expected exactly one audit file, got: \(files)")

        // Decode and sanity-check.
        let auditURL = auditDir.appendingPathComponent(matching[0])
        let data = try Data(contentsOf: auditURL)
        let audit = try JSONDecoder().decode(ResolverAudit.self, from: data)
        XCTAssertEqual(audit.eligibleNodeCount, 2)
        XCTAssertEqual(audit.pairsEvaluated, 1)
        XCTAssertEqual(audit.entries.count, 1)
        let entry = audit.entries[0]
        XCTAssertEqual(entry.band, "exactLabel")
        XCTAssertTrue(entry.exactLabelMatch)
        XCTAssertEqual(entry.finalReason, "exactLabel")
        XCTAssertNil(entry.llmVerdict, "Exact-label merge bypasses LLM, so no verdict")
        XCTAssertTrue(entry.aDocs.contains("org.pdf") || entry.bDocs.contains("org.pdf"))
        XCTAssertTrue(entry.aDocs.contains("cmp.pdf") || entry.bDocs.contains("cmp.pdf"))
    }

    func test_resolve_doesNotWriteAuditFile_whenAuditDirNil() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "X", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/a.pdf")], level: .concept)
        let b = ConceptNode(label: "X", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/b.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [1, 0, 0] }

        // Snapshot temp dir contents before. Run resolver with auditOutputDir
        // nil (default). Confirm no new etr_audit_* files appear.
        let tempBefore = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("etr_audit_") } ?? []
        _ = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                embeddingBackend: backend)
        let tempAfter = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("etr_audit_") } ?? []
        XCTAssertEqual(tempBefore, tempAfter, "auditOutputDir nil should produce no audit files")
    }

    func test_resolve_auditCapturesAdjudicationVerdicts() async throws {
        let projectID = UUID()
        let auditDir = FileManager.default.temporaryDirectory.appendingPathComponent("etr-audit-verdict-\(UUID().uuidString)")
        defer {
            wipeCacheFile(for: projectID)
            try? FileManager.default.removeItem(at: auditDir)
        }
        let g = KnowledgeGraph()
        let a = ConceptNode(label: "Telehealth", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/A.pdf")], level: .concept)
        let b = ConceptNode(label: "Virtual Care", type: .concept, summary: nil,
                            sourceAnchors: [anchor("/B.pdf")], level: .concept)
        g.addNode(a); g.addNode(b)
        // Vectors near 0.87 — in 0.80-0.95 adjudication band with default thresholds.
        let backend = FakeEmbeddingBackend(dim: 2) { text in
            text.contains("Telehealth") ? [1, 0] : [0.87, sqrt(1 - 0.87 * 0.87)]
        }
        // LLM approves (returns [true])
        let llm = FlakyLLMBackend(failureCount: 0, successResponse: "[true]")

        _ = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                embeddingBackend: backend,
                                                llmBackend: llm,
                                                auditOutputDir: auditDir)
        let files = try FileManager.default.contentsOfDirectory(atPath: auditDir.path)
            .filter { $0.hasPrefix("etr_audit_") }
        XCTAssertEqual(files.count, 1)
        let audit = try JSONDecoder().decode(
            ResolverAudit.self,
            from: try Data(contentsOf: auditDir.appendingPathComponent(files[0]))
        )
        XCTAssertEqual(audit.entries.count, 1)
        XCTAssertEqual(audit.entries[0].band, "adjudication")
        XCTAssertEqual(audit.entries[0].llmVerdict, "approved")
        XCTAssertEqual(audit.entries[0].finalReason, "llmAdjudicated")
    }

    func test_resolve_logsThresholdsInPlan() async throws {
        let projectID = UUID()
        defer { wipeCacheFile(for: projectID) }
        let g = KnowledgeGraph()
        let backend = FakeEmbeddingBackend(dim: 3) { _ in [0.0, 0.0, 0.0] }
        let custom = ResolverThresholds(autoMerge: 0.92, adjudicationFloor: 0.80, adjudicationBatchSize: 10)
        let plan = try await EmbeddingResolver.resolve(graph: g, projectID: projectID,
                                                       embeddingBackend: backend,
                                                       thresholds: custom)
        XCTAssertEqual(plan.thresholds, custom)
    }
}
