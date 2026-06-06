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
        XCTAssertEqual(AIBackendType.codexAgent.availableModels.first, "gpt-5.3-codex-spark")
    }

    func test_backendDefaultModel_usesSpark() {
        let backend = CodexAgentBackend()

        XCTAssertEqual(backend.modelIdentifier, "gpt-5.3-codex-spark")
    }

    func test_createBackend_returnsCodexAgentWithoutAPIKey() {
        let service = AIServiceManager()
        service.selectedBackendType = .codexAgent
        service.selectedModel = "gpt-5.3-codex-spark"

        let backend = service.createBackend()

        XCTAssertTrue(backend is CodexAgentBackend)
        XCTAssertEqual(backend?.displayName, "Codex Agent")
        XCTAssertEqual(backend?.modelIdentifier, "gpt-5.3-codex-spark")
    }

    func test_savePreferencesMarksCodexAgentConfiguredWithoutAPIKey() {
        let service = AIServiceManager()
        service.selectedBackendType = .codexAgent
        service.selectedModel = "gpt-5.3-codex-spark"

        service.savePreferences()

        XCTAssertTrue(service.isConfigured)
    }

    func test_transportParsesTextResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/extract")
            XCTAssertEqual(request.httpMethod, "POST")
            if let bodyData = request.httpBody ?? request.httpBodyDataFromStream,
               let payload = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any] {
                XCTAssertEqual(payload["model"] as? String, "gpt-5.3-codex-spark")
                XCTAssertNil(payload["reasoning_effort"])
            } else {
                XCTFail("Expected JSON payload")
            }
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
            model: "gpt-5.3-codex-spark",
            session: Self.mockSession()
        )

        let response = try await backend.generateRawResponse(prompt: "hello")

        XCTAssertEqual(response, "sidecar response")
    }

    func test_transportIncludesReasoningEffortWhenConfigured() async throws {
        MockURLProtocol.handler = { request in
            if let bodyData = request.httpBody ?? request.httpBodyDataFromStream,
               let payload = try? JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any] {
                XCTAssertEqual(payload["reasoning_effort"] as? String, "high")
            } else {
                XCTFail("Expected JSON payload")
            }

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
            model: "gpt-5.3-codex-spark",
            reasoningEffort: "high",
            session: Self.mockSession()
        )

        _ = try await backend.generateRawResponse(prompt: "hello")
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
            model: "gpt-5.3-codex-spark",
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

private extension URLRequest {
    var httpBodyDataFromStream: Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()

        while stream.hasBytesAvailable {
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }

        return data
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
