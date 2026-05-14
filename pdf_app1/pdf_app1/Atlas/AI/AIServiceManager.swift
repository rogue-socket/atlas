//
//  AIServiceManager.swift
//  Atlas
//
//  Manages AI backend selection, API keys, caching, and cost tracking
//

import Foundation
import Security
import CryptoKit
import Observation
import os.log

private let log = AtlasLogger.ai

// MARK: - AI Service Manager

@Observable
class AIServiceManager {
    var selectedBackendType: AIBackendType = .claude
    var selectedModel: String = "claude-sonnet-4-5-20250514"
    var isConfigured: Bool = false
    var totalTokensUsed: Int = 0

    private var responseCache: [String: String] = [:]
    private let cacheDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDirectory = appSupport.appendingPathComponent("Atlas/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        loadPreferences()
    }

    // MARK: - Backend Creation

    func createBackend() -> (any AtlasModel)? {
        let apiKey = getAPIKey(for: selectedBackendType) ?? ""
        log.info("[AIService] createBackend: type=\(self.selectedBackendType.rawValue), model=\(self.selectedModel), hasKey=\(!apiKey.isEmpty)")

        switch selectedBackendType {
        case .claude:
            guard !apiKey.isEmpty else {
                log.warning("[AIService] No API key for Claude")
                return nil
            }
            return ClaudeBackend(apiKey: apiKey, model: selectedModel)
        case .openai:
            guard !apiKey.isEmpty else {
                log.warning("[AIService] No API key for OpenAI")
                return nil
            }
            return OpenAIBackend(apiKey: apiKey, model: selectedModel)
        case .gemini:
            guard !apiKey.isEmpty else {
                log.warning("[AIService] No API key for Gemini")
                return nil
            }
            return GeminiBackend(apiKey: apiKey, model: selectedModel)
        case .ollama:
            let baseURL = UserDefaults.standard.string(forKey: AppConstants.ollamaBaseURLKey) ?? "http://localhost:11434"
            log.info("[AIService] Using Ollama at \(baseURL)")
            return OpenAIBackend(apiKey: "", model: selectedModel, baseURL: baseURL + "/v1", displayName: "Ollama")
        }
    }

    // MARK: - API Key Management (Keychain)

    func setAPIKey(_ key: String, for backend: AIBackendType) {
        let service = "com.atlas.apikey.\(backend.rawValue)"
        let data = key.data(using: .utf8)!

        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new
        guard !key.isEmpty else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)

        updateConfiguredState()
    }

    func getAPIKey(for backend: AIBackendType) -> String? {
        let service = "com.atlas.apikey.\(backend.rawValue)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Response Caching

    func cachedResponse(for prompt: String, model: String) -> String? {
        let key = cacheKey(prompt: prompt, model: model)
        if let cached = responseCache[key] { return cached }

        // Try disk cache
        let fileURL = cacheDirectory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        responseCache[key] = text
        return text
    }

    func cacheResponse(_ response: String, for prompt: String, model: String) {
        let key = cacheKey(prompt: prompt, model: model)
        responseCache[key] = response

        // Write to disk
        let fileURL = cacheDirectory.appendingPathComponent(key + ".json")
        try? response.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    private func cacheKey(prompt: String, model: String) -> String {
        let input = "\(model):\(prompt)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Preferences Persistence

    private func loadPreferences() {
        if let type = UserDefaults.standard.string(forKey: AppConstants.aiBackendTypeKey),
           let backendType = AIBackendType(rawValue: type) {
            selectedBackendType = backendType
        }
        if let model = UserDefaults.standard.string(forKey: AppConstants.aiModelKey) {
            selectedModel = model
        }
        updateConfiguredState()
    }

    func savePreferences() {
        UserDefaults.standard.set(selectedBackendType.rawValue, forKey: AppConstants.aiBackendTypeKey)
        UserDefaults.standard.set(selectedModel, forKey: AppConstants.aiModelKey)
    }

    private func updateConfiguredState() {
        if selectedBackendType == .ollama {
            isConfigured = true
        } else {
            isConfigured = getAPIKey(for: selectedBackendType) != nil
        }
    }
}
