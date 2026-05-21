import XCTest
@testable import pdf_app1

/// Foundational tests for ETR step 1 — pure vector math + the
/// `AtlasEmbeddingBackend` protocol shape. No live API calls; live integration
/// is exercised end-to-end via the headless harness when ETR stages 3-4 land.
final class EmbeddingTests: XCTestCase {

    // MARK: - cosineSimilarity

    func test_cosineSimilarity_identicalVectors_returnsOne() {
        let a: [Float] = [1, 2, 3, 4]
        let sim = EmbeddingMath.cosineSimilarity(a, a)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_oppositeVectors_returnsMinusOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_orthogonalVectors_returnsZero() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_zeroVector_returnsZero() {
        // Degenerate input: zero magnitude → division-by-zero would normally
        // produce nan/inf. Spec says return 0 ("no signal").
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 1, 1]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0)
        XCTAssertFalse(sim.isNaN)
    }

    func test_cosineSimilarity_scaledVectors_returnsOne() {
        // Cosine is scale-invariant; magnitude shouldn't change the result.
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [10, 20, 30]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-6)
    }

    func test_cosineSimilarity_knownAngle_returnsExpected() {
        // 45° between two 2D vectors → cos(45°) ≈ 0.7071
        let a: [Float] = [1, 0]
        let b: [Float] = [1, 1]
        let sim = EmbeddingMath.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.7071, accuracy: 1e-4)
    }

    // MARK: - GeminiEmbeddingBackend protocol shape

    func test_geminiEmbeddingBackend_emptyInput_returnsEmptyOutput() async throws {
        // No API key required to short-circuit empty input.
        let backend = GeminiEmbeddingBackend(apiKey: "")
        let result = try await backend.embed([])
        XCTAssertTrue(result.isEmpty)
    }

    func test_geminiEmbeddingBackend_nonEmptyInputWithoutKey_throwsNoAPIKey() async {
        let backend = GeminiEmbeddingBackend(apiKey: "")
        do {
            _ = try await backend.embed(["hello"])
            XCTFail("Expected AIError.noAPIKey")
        } catch AIError.noAPIKey {
            // expected
        } catch {
            XCTFail("Expected AIError.noAPIKey, got \(error)")
        }
    }

    func test_geminiEmbeddingBackend_metadata_matchesConfiguredValues() {
        let backend = GeminiEmbeddingBackend(
            apiKey: "dummy",
            model: "gemini-embedding-001",
            vectorDimension: 768
        )
        XCTAssertEqual(backend.modelIdentifier, "gemini-embedding-001")
        XCTAssertEqual(backend.vectorDimension, 768)
        XCTAssertTrue(backend.isAvailable)
        XCTAssertEqual(backend.displayName, "Google Gemini Embeddings")
    }
}
