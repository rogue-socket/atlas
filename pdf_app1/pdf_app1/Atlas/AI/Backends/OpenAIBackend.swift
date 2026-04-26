//
//  OpenAIBackend.swift
//  Atlas
//
//  OpenAI-compatible API backend (works with OpenAI, Ollama, LM Studio)
//

import Foundation

final class OpenAIBackend: AtlasModel, @unchecked Sendable {
    let displayName: String
    let modelIdentifier: String
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    var isAvailable: Bool { !apiKey.isEmpty || baseURL.contains("localhost") }

    init(
        apiKey: String,
        model: String = "gpt-4o",
        baseURL: String = "https://api.openai.com",
        displayName: String = "OpenAI"
    ) {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.baseURL = baseURL
        self.displayName = displayName
        self.session = URLSession.shared
    }

    // MARK: - AtlasModel

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] {
        let prompt = PromptTemplates.conceptExtraction(text: text, context: context)
        let response = try await sendChatCompletion(prompt)
        let parsed = try parseExtractionResponse(response)
        return parsed.concepts
    }

    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] {
        let prompt = PromptTemplates.edgeProposal(concepts: concepts, context: context)
        let response = try await sendChatCompletion(prompt)
        return try parseEdgesResponse(response)
    }

    func summarizeConcept(_ label: String, sourceText: String) async throws -> String {
        let prompt = PromptTemplates.summarize(conceptLabel: label, sourceText: sourceText)
        return try await sendChatCompletion(prompt)
    }

    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        let prompt = PromptTemplates.questionAnswer(question: question, context: context)
        let response = try await sendChatCompletion(prompt)
        return try parseAnswerResponse(response)
    }

    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal] {
        let prompt = PromptTemplates.semanticMergeProposal(
            documentATitle: "Document A",
            documentAConcepts: documentAConcepts,
            documentBTitle: "Document B",
            documentBConcepts: documentBConcepts
        )
        let response = try await sendChatCompletion(prompt)
        let cleaned = extractJSON(from: response)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RawMergeProposal].self, from: data)) ?? []
    }

    // MARK: - HTTP

    private func sendChatCompletion(_ content: String) async throws -> String {
        let url = URL(string: "\(baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": modelIdentifier,
            "messages": [
                ["role": "user", "content": content]
            ],
            "max_tokens": 4096,
            "temperature": 0.1
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
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIError.invalidResponse
        }

        return text
    }

    // MARK: - Parsing (shared with ClaudeBackend pattern)

    private func parseExtractionResponse(_ text: String) throws -> ExtractionResponse {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        return try JSONDecoder().decode(ExtractionResponse.self, from: data)
    }

    private func parseEdgesResponse(_ text: String) throws -> [RawEdge] {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode([RawEdge].self, from: data)
        } catch {
            if let response = try? JSONDecoder().decode(ExtractionResponse.self, from: data) {
                return response.edges
            }
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    private func parseAnswerResponse(_ text: String) throws -> AnswerWithCitations {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else {
            return AnswerWithCitations(answer: text, citations: [])
        }
        do {
            return try JSONDecoder().decode(AnswerWithCitations.self, from: data)
        } catch {
            return AnswerWithCitations(answer: text, citations: [])
        }
    }

    private func extractJSON(from text: String) -> String {
        JSONRepair.cleanAndRepair(text)
    }
}
