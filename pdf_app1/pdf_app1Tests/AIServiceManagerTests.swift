import XCTest
@testable import pdf_app1

/// Tests for `Atlas/AI/AIServiceManager.swift` covering the parts that
/// don't require Keychain access (the manager hard-guards Keychain off
/// under XCTest):
///   - response cache: in-memory + disk hit
///   - `savePreferences` writes to UserDefaults under stable keys
///   - `setAPIKey`/`getAPIKey` are no-ops under XCTest (no Keychain prompt)
///   - `createBackend()` returns nil when no key is available for a
///     remote backend, but returns an Ollama backend regardless
final class AIServiceManagerTests: XCTestCase {

    // MARK: - Response cache

    func test_cache_storesAndRetrievesByPromptAndModel() {
        let mgr = AIServiceManager()
        let prompt = "explain rotation curves"
        let model = "test-model-\(UUID().uuidString.prefix(8))"
        XCTAssertNil(mgr.cachedResponse(for: prompt, model: model))

        mgr.cacheResponse("cached answer body", for: prompt, model: model)
        XCTAssertEqual(mgr.cachedResponse(for: prompt, model: model), "cached answer body")

        // Different model → different key → cache miss.
        XCTAssertNil(mgr.cachedResponse(for: prompt, model: model + "-other"))
    }

    func test_cache_persistsOnDiskAcrossManagerInstances() {
        let prompt = "persist me"
        let model = "test-disk-\(UUID().uuidString.prefix(8))"

        let mgr1 = AIServiceManager()
        mgr1.cacheResponse("on disk", for: prompt, model: model)

        // New instance: in-memory cache empty, but disk should still serve.
        let mgr2 = AIServiceManager()
        XCTAssertEqual(mgr2.cachedResponse(for: prompt, model: model), "on disk")
    }

    // MARK: - Preferences

    func test_savePreferences_writesUnderStableKeys() {
        let mgr = AIServiceManager()
        mgr.selectedBackendType = .openai
        mgr.selectedModel = "gpt-4o-mini"
        mgr.savePreferences()

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AppConstants.aiBackendTypeKey),
            "OpenAI"
        )
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: AppConstants.aiModelKey),
            "gpt-4o-mini"
        )
    }

    // MARK: - Keychain hard-guard under XCTest

    func test_setAPIKey_underXCTest_isNoOp_andGetReturnsNil() {
        let mgr = AIServiceManager()
        // Without a dev-keys file or env var, even after calling setAPIKey
        // the getter should return nil because we never write to Keychain
        // under XCTest.
        let backend = AIBackendType.claude
        let envName = "ATLAS_\(backend.rawValue.uppercased())_API_KEY"
        let priorEnv = ProcessInfo.processInfo.environment[envName]

        // If the env var is set, the dev-mode env-var path overrides Keychain;
        // skip this test in that case to avoid false negatives.
        try? XCTSkipIf(priorEnv != nil, "Skipping; \(envName) is set in the environment")

        mgr.setAPIKey("should-be-ignored-under-xctest", for: backend)
        XCTAssertNil(mgr.getAPIKey(for: backend),
                     "setAPIKey must be a no-op under XCTest to avoid keychain prompts")
    }

    // MARK: - createBackend without keys

    func test_createBackend_returnsNilForRemoteWithoutKey() {
        let mgr = AIServiceManager()
        // Under XCTest there's no Keychain access; assume no env-var set.
        // For backends that require keys, expect nil.
        for backend in [AIBackendType.claude, .openai, .gemini] {
            let envName = "ATLAS_\(backend.rawValue.uppercased())_API_KEY"
            guard ProcessInfo.processInfo.environment[envName] == nil else { continue }
            mgr.selectedBackendType = backend
            mgr.selectedModel = backend.availableModels.first ?? "any"
            XCTAssertNil(mgr.createBackend(),
                         "\(backend) without an API key should yield nil backend")
        }
    }

    func test_createBackend_ollamaAlwaysReturnsSomething() {
        let mgr = AIServiceManager()
        mgr.selectedBackendType = .ollama
        mgr.selectedModel = "llama3.1"
        XCTAssertNotNil(mgr.createBackend(), "Ollama backend should never require an API key")
    }

    // MARK: - AIBackendType helpers

    func test_aiBackendType_requiresAPIKey_partition() {
        XCTAssertTrue(AIBackendType.claude.requiresAPIKey)
        XCTAssertTrue(AIBackendType.openai.requiresAPIKey)
        XCTAssertTrue(AIBackendType.gemini.requiresAPIKey)
        XCTAssertFalse(AIBackendType.ollama.requiresAPIKey)
    }

    func test_aiBackendType_defaultBaseURL_isAbsolute() {
        for b in AIBackendType.allCases {
            let url = URL(string: b.defaultBaseURL)
            XCTAssertNotNil(url, "\(b) baseURL should parse")
            XCTAssertNotNil(url?.scheme)
        }
    }

    func test_aiBackendType_availableModels_nonEmpty() {
        for b in AIBackendType.allCases {
            XCTAssertFalse(b.availableModels.isEmpty, "\(b) has no available models")
        }
    }

    func test_aiBackendType_codableRoundTrip() throws {
        for b in AIBackendType.allCases {
            let data = try JSONEncoder().encode(b)
            let decoded = try JSONDecoder().decode(AIBackendType.self, from: data)
            XCTAssertEqual(decoded, b)
        }
    }

    // MARK: - AIError messages

    func test_aiError_localizedDescriptionsArePresent() {
        let errs: [AIError] = [
            .noAPIKey,
            .invalidResponse,
            .httpError(statusCode: 500, message: "boom"),
            .decodingError("bad JSON"),
            .networkError(NSError(domain: "test", code: 1)),
            .modelUnavailable("test-model")
        ]
        for e in errs {
            XCTAssertNotNil(e.errorDescription)
            XCTAssertFalse(e.errorDescription!.isEmpty)
        }
    }
}
