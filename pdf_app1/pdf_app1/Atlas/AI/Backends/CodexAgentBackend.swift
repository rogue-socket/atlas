//
//  CodexAgentBackend.swift
//  Atlas
//
//  Talks to the local codex-agent sidecar, which wraps the user's Codex CLI.
//

import Foundation
import os.log

private let log = AtlasLogger.ai

final class CodexAgentBackend: LLMBackend, @unchecked Sendable {
    let displayName = "Codex Agent"
    let modelIdentifier: String
    let logTag = "CodexAgent"
    private let baseURL: String
    private let session: URLSession

    var isAvailable: Bool { true }

    init(baseURL: String = "http://127.0.0.1:8775", model: String = "gpt-5.5", session: URLSession? = nil) {
        self.baseURL = baseURL
        self.modelIdentifier = model
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    func preflight() async throws {
        let url = URL(string: "\(baseURL)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let message = Self.errorMessage(from: data)
                    ?? "Codex Agent sidecar at \(baseURL) responded with HTTP \(http.statusCode)"
                throw AIError.modelUnavailable(message)
            }
        } catch let error as AIError {
            throw error
        } catch {
            log.error("[CodexAgent] Health check failed: \(error.localizedDescription)")
            throw AIError.modelUnavailable(
                "Codex Agent sidecar is not running at \(baseURL). Start it with 'python3 atlas/codex-agent-sidecar/server.py' from the pdf_projects workspace.")
        }
    }

    func transport(prompt: String) async throws -> String {
        log.info("[CodexAgent] POST \(self.baseURL)/extract (prompt: \(prompt.count) chars, model: \(self.modelIdentifier))")

        let url = URL(string: "\(baseURL)/extract")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
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
            log.error("[CodexAgent] Request failed — is the sidecar running at \(self.baseURL)? \(error.localizedDescription)")
            throw AIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("[CodexAgent] Response is not HTTPURLResponse")
            throw AIError.invalidResponse
        }

        log.info("[CodexAgent] HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            let message = Self.errorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            log.error("[CodexAgent] HTTP error \(httpResponse.statusCode): \(String(message.prefix(300)))")
            throw AIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed: CodexAgentResponse
        do {
            parsed = try JSONDecoder().decode(CodexAgentResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[CodexAgent] Could not parse response structure: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }
        guard let text = parsed.text else {
            log.error("[CodexAgent] Response had no text field")
            throw AIError.invalidResponse
        }

        log.info("[CodexAgent] Got text response: \(text.count) chars")
        log.debug("[CodexAgent] Response preview: \(String(text.prefix(200)))")
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let parsed = try? JSONDecoder().decode(CodexAgentErrorResponse.self, from: data) else {
            return nil
        }
        return parsed.error
    }
}

private struct CodexAgentResponse: Decodable {
    let text: String?
}

private struct CodexAgentErrorResponse: Decodable {
    let error: String?
}
