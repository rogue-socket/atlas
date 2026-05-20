//
//  ClaudeSidecarBackend.swift
//  Atlas
//
//  Talks to the local claude-sidecar HTTP server (atlas/claude-sidecar/),
//  which runs Claude headlessly via the user's Claude subscription. No API key.
//

import Foundation
import os.log

private let log = AtlasLogger.ai

final class ClaudeSidecarBackend: LLMBackend, @unchecked Sendable {
    let displayName = "Claude (Subscription)"
    let modelIdentifier: String
    let logTag = "ClaudeSidecar"
    private let baseURL: String
    private let session: URLSession

    // The sidecar is a separate local process — whether it's actually running
    // only surfaces at transport() time as a networkError.
    var isAvailable: Bool { true }

    init(baseURL: String = "http://127.0.0.1:8765", model: String = "opus") {
        self.baseURL = baseURL
        self.modelIdentifier = model
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func transport(prompt: String) async throws -> String {
        log.info("[ClaudeSidecar] POST \(self.baseURL)/extract (prompt: \(prompt.count) chars, model: \(self.modelIdentifier))")

        let url = URL(string: "\(baseURL)/extract")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "model": modelIdentifier
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log.error("[ClaudeSidecar] Request failed — is the sidecar running at \(self.baseURL)? \(error.localizedDescription)")
            throw AIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("[ClaudeSidecar] Response is not HTTPURLResponse")
            throw AIError.invalidResponse
        }

        log.info("[ClaudeSidecar] HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            log.error("[ClaudeSidecar] HTTP error \(httpResponse.statusCode): \(String(message.prefix(300)))")
            throw AIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed: SidecarResponse
        do {
            parsed = try JSONDecoder().decode(SidecarResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[ClaudeSidecar] Could not parse response structure: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }
        guard let text = parsed.text else {
            log.error("[ClaudeSidecar] Response had no text field")
            throw AIError.invalidResponse
        }

        log.info("[ClaudeSidecar] Got text response: \(text.count) chars")
        log.debug("[ClaudeSidecar] Response preview: \(String(text.prefix(200)))")
        return text
    }
}

private struct SidecarResponse: Decodable {
    let text: String?
}
