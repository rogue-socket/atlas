//
//  ClaudeBackend.swift
//  Atlas
//
//  Anthropic Claude API backend via URLSession
//

import Foundation

final class ClaudeBackend: AtlasModel, @unchecked Sendable {
    let displayName = "Anthropic Claude"
    let modelIdentifier: String
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    var isAvailable: Bool { !apiKey.isEmpty }

    init(apiKey: String, model: String = "claude-sonnet-4-5-20250514", baseURL: String = "https://api.anthropic.com") {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    // MARK: - AtlasModel

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] {
        let prompt = PromptTemplates.conceptExtraction(text: text, context: context)
        let response = try await sendMessage(prompt)
        let parsed = try parseExtractionResponse(response)
        return parsed.concepts
    }

    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] {
        let prompt = PromptTemplates.edgeProposal(concepts: concepts, context: context)
        let response = try await sendMessage(prompt)
        return try parseEdgesResponse(response)
    }

    func summarizeConcept(_ label: String, sourceText: String) async throws -> String {
        let prompt = PromptTemplates.summarize(conceptLabel: label, sourceText: sourceText)
        return try await sendMessage(prompt)
    }

    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        let prompt = PromptTemplates.questionAnswer(question: question, context: context)
        let response = try await sendMessage(prompt)
        return try parseAnswerResponse(response)
    }

    // MARK: - HTTP

    private func sendMessage(_ content: String) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey }

        let url = URL(string: "\(baseURL)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": modelIdentifier,
            "max_tokens": 4096,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let contentArray = json?["content"] as? [[String: Any]],
              let firstBlock = contentArray.first,
              let text = firstBlock["text"] as? String else {
            throw AIError.invalidResponse
        }

        return text
    }

    // MARK: - Parsing

    private func parseExtractionResponse(_ text: String) throws -> ExtractionResponse {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode(ExtractionResponse.self, from: data)
        } catch {
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    private func parseEdgesResponse(_ text: String) throws -> [RawEdge] {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode([RawEdge].self, from: data)
        } catch {
            // Try wrapping in extraction response
            if let response = try? JSONDecoder().decode(ExtractionResponse.self, from: data) {
                return response.edges
            }
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    private func parseAnswerResponse(_ text: String) throws -> AnswerWithCitations {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode(AnswerWithCitations.self, from: data)
        } catch {
            // Fallback: return raw text as answer with no citations
            return AnswerWithCitations(answer: text, citations: [])
        }
    }

    private func extractJSON(from text: String) -> String {
        JSONRepair.cleanAndRepair(text)
    }
}
