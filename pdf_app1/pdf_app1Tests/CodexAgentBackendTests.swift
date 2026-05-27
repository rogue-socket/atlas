import XCTest
@testable import pdf_app1

final class CodexAgentBackendTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: AppConstants.aiBackendTypeKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.aiModelKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.codexAgentSidecarURLKey)
        super.tearDown()
    }

    func test_backendTypeMetadata_matchesCodexAgentProvider() {
        XCTAssertEqual(AIBackendType.codexAgent.displayName, "Codex Agent")
        XCTAssertFalse(AIBackendType.codexAgent.requiresAPIKey)
        XCTAssertEqual(AIBackendType.codexAgent.defaultBaseURL, "http://127.0.0.1:8775")
        XCTAssertEqual(AIBackendType.codexAgent.availableModels.first, "gpt-5.5")
    }

    func test_createBackend_returnsCodexAgentWithoutAPIKey() {
        let service = AIServiceManager()
        service.selectedBackendType = .codexAgent
        service.selectedModel = "gpt-5.5"

        let backend = service.createBackend()

        XCTAssertTrue(backend is CodexAgentBackend)
        XCTAssertEqual(backend?.displayName, "Codex Agent")
        XCTAssertEqual(backend?.modelIdentifier, "gpt-5.5")
    }

    func test_savePreferencesMarksCodexAgentConfiguredWithoutAPIKey() {
        let service = AIServiceManager()
        service.selectedBackendType = .codexAgent
        service.selectedModel = "gpt-5.5"

        service.savePreferences()

        XCTAssertTrue(service.isConfigured)
    }

    func test_createEmbeddingBackend_returnsNilForCodexAgent() {
        let service = AIServiceManager()
        service.selectedEmbeddingBackendType = .codexAgent

        XCTAssertFalse(service.isEmbeddingConfigured)
        XCTAssertNil(service.createEmbeddingBackend())
    }

    func test_transportParsesTextResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/extract")
            XCTAssertEqual(request.httpMethod, "POST")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"text":"sidecar response"}"#.utf8)
            )
        }

        let backend = CodexAgentBackend(
            baseURL: "http://codex-agent.test",
            model: "gpt-5.5",
            session: Self.mockSession()
        )

        let response = try await backend.generateRawResponse(prompt: "hello")

        XCTAssertEqual(response, "sidecar response")
    }

    func test_transportMapsNon200ToHTTPError() async {
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"error":"codex failed"}"#.utf8)
            )
        }

        let backend = CodexAgentBackend(
            baseURL: "http://codex-agent.test",
            model: "gpt-5.5",
            session: Self.mockSession()
        )

        do {
            _ = try await backend.generateRawResponse(prompt: "hello")
            XCTFail("Expected HTTP error")
        } catch AIError.httpError(let statusCode, let message) {
            XCTAssertEqual(statusCode, 502)
            XCTAssertTrue(message.contains("codex failed"))
        } catch {
            XCTFail("Expected HTTP error, got \(error)")
        }
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

private final class MockURLProtocol: URLProtocol {
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
