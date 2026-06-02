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

    // MARK: - OpenAI-compatible LAN gateway

    func test_openAICompatibleEmbeddingBackend_emptyInput_returnsEmptyOutput() async throws {
        let backend = OpenAICompatibleEmbeddingBackend(apiKey: "none")
        let result = try await backend.embed([])
        XCTAssertTrue(result.isEmpty)
    }

    func test_openAICompatibleEmbeddingBackend_metadata_matchesConfiguredModel() {
        let backend = OpenAICompatibleEmbeddingBackend(
            apiKey: "none",
            model: "all-minilm-l6-v2",
            baseURL: "http://gateway.test/v1"
        )
        XCTAssertEqual(backend.displayName, "LAN Embedding Gateway")
        XCTAssertEqual(backend.modelIdentifier, "all-minilm-l6-v2")
        XCTAssertEqual(backend.vectorDimension, 384)
        XCTAssertTrue(backend.isAvailable)
    }

    func test_openAICompatibleEmbeddingBackend_postsOpenAICompatibleRequest() async throws {
        EmbeddingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://gateway.test/v1/embeddings")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try requestBodyData(from: request)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["model"] as? String, "bge-base-en-v1.5")
            XCTAssertEqual(json?["input"] as? [String], ["alpha", "beta"])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":[{"index":1,"embedding":[0.0,1.0]},{"index":0,"embedding":[1.0,0.0]}]}"#.utf8)
            )
        }
        defer { EmbeddingMockURLProtocol.handler = nil }

        let backend = OpenAICompatibleEmbeddingBackend(
            apiKey: "none",
            model: "bge-base-en-v1.5",
            vectorDimension: 2,
            baseURL: "http://gateway.test/v1",
            session: Self.embeddingMockSession()
        )

        let vectors = try await backend.embed(["alpha", "beta"])

        XCTAssertEqual(vectors, [[1.0, 0.0], [0.0, 1.0]])
    }

    func test_openAICompatibleEmbeddingBackend_dimensionMismatchThrowsInvalidResponse() async {
        EmbeddingMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":[{"index":0,"embedding":[1.0,0.0,0.5]}]}"#.utf8)
            )
        }
        defer { EmbeddingMockURLProtocol.handler = nil }

        let backend = OpenAICompatibleEmbeddingBackend(
            apiKey: "secret",
            model: "bge-base-en-v1.5",
            vectorDimension: 2,
            baseURL: "http://gateway.test/v1",
            session: Self.embeddingMockSession()
        )

        do {
            _ = try await backend.embed(["alpha"])
            XCTFail("Expected invalidResponse")
        } catch AIError.invalidResponse {
            // expected
        } catch {
            XCTFail("Expected invalidResponse, got \(error)")
        }
    }

    func test_aiServiceCreatesEmbeddingGatewayBackendWithoutAPIKey() {
        UserDefaults.standard.set("http://gateway.test/v1", forKey: AppConstants.aiEmbeddingGatewayBaseURLKey)
        UserDefaults.standard.set("none", forKey: AppConstants.aiEmbeddingGatewayAPIKeyKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppConstants.aiEmbeddingGatewayBaseURLKey)
            UserDefaults.standard.removeObject(forKey: AppConstants.aiEmbeddingGatewayAPIKeyKey)
        }

        let service = AIServiceManager()
        service.selectedEmbeddingBackendType = .embeddingGateway
        service.selectedEmbeddingModel = "all-minilm-l6-v2"

        let backend = service.createEmbeddingBackend()

        XCTAssertTrue(service.isEmbeddingConfigured)
        XCTAssertTrue(backend is OpenAICompatibleEmbeddingBackend)
        XCTAssertEqual(backend?.modelIdentifier, "all-minilm-l6-v2")
        XCTAssertEqual(backend?.vectorDimension, 384)
    }

    private static func embeddingMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbeddingMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class EmbeddingMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}

private func requestBodyData(from request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else {
        throw NSError(domain: "EmbeddingTests", code: 1)
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? NSError(domain: "EmbeddingTests", code: 2)
        }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
