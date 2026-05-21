//
//  GeminiBackend.swift
//  Atlas
//
//  Google Gemini API backend via URLSession
//

import Foundation
import os.log

private let log = AtlasLogger.ai

final class GeminiBackend: LLMBackend, @unchecked Sendable {
    let displayName = "Google Gemini"
    let modelIdentifier: String
    let logTag = "Gemini"
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    var isAvailable: Bool { !apiKey.isEmpty }

    init(
        apiKey: String,
        model: String = "gemini-2.5-flash",
        baseURL: String = "https://generativelanguage.googleapis.com"
    ) {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    func transport(prompt: String) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey }

        let endpoint = "\(baseURL)/v1beta/models/\(modelIdentifier):generateContent?key=\(apiKey)"
        log.info("[Gemini] POST \(self.baseURL)/v1beta/models/\(self.modelIdentifier):generateContent (prompt: \(prompt.count) chars)")

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.0,
                "topK": 1,
                "maxOutputTokens": 32768,
                "responseMimeType": "application/json"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("[Gemini] Response is not HTTPURLResponse")
            throw AIError.invalidResponse
        }

        log.info("[Gemini] HTTP \(httpResponse.statusCode), \(data.count) bytes")

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            log.error("[Gemini] HTTP error \(httpResponse.statusCode): \(String(message.prefix(300)))")
            throw AIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed: GeminiResponse
        do {
            parsed = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Gemini] Could not parse response structure: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }
        guard let text = parsed.candidates.first?.content.parts.first?.text else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Gemini] Empty candidates/parts. Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }

        log.info("[Gemini] Got text response: \(text.count) chars")
        log.debug("[Gemini] Response preview: \(String(text.prefix(200)))")
        return text
    }
}

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]
    struct Candidate: Decodable {
        let content: Content
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String
    }
}
