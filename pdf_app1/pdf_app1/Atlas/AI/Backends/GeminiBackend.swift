//
//  GeminiBackend.swift
//  Atlas
//
//  Google Gemini API backend via URLSession
//

import Foundation
import os.log

private let log = AtlasLogger.ai

final class GeminiBackend: AtlasModel, @unchecked Sendable {
    let displayName = "Google Gemini"
    let modelIdentifier: String
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

    // MARK: - AtlasModel

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] {
        log.info("[Gemini] extractConcepts: prompt \(text.count) chars")
        let prompt = PromptTemplates.conceptExtraction(text: text, context: context)
        let response = try await generateContent(prompt)
        do {
            let parsed = try parseExtractionResponse(response)
            log.info("[Gemini] Parsed \(parsed.concepts.count) concepts, \(parsed.edges.count) edges from response")
            return parsed.concepts
        } catch {
            log.error("[Gemini] Failed to parse extraction response: \(error)")
            log.error("[Gemini] Raw response (first 500 chars): \(String(response.prefix(500)))")
            throw error
        }
    }

    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] {
        log.info("[Gemini] proposeEdges for \(concepts.count) concepts")
        let prompt = PromptTemplates.edgeProposal(concepts: concepts, context: context)
        let response = try await generateContent(prompt)
        do {
            let edges = try parseEdgesResponse(response)
            log.info("[Gemini] Parsed \(edges.count) edges")
            return edges
        } catch {
            log.error("[Gemini] Failed to parse edges response: \(error)")
            log.error("[Gemini] Raw response (first 500 chars): \(String(response.prefix(500)))")
            throw error
        }
    }

    func summarizeConcept(_ label: String, sourceText: String) async throws -> String {
        let prompt = PromptTemplates.summarize(conceptLabel: label, sourceText: sourceText)
        return try await generateContent(prompt)
    }

    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        let prompt = PromptTemplates.questionAnswer(question: question, context: context)
        let response = try await generateContent(prompt)
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
        let response = try await generateContent(prompt)
        let cleaned = extractJSON(from: response)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RawMergeProposal].self, from: data)) ?? []
    }

    // MARK: - HTTP

    private func generateContent(_ content: String) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey }

        let endpoint = "\(baseURL)/v1beta/models/\(modelIdentifier):generateContent?key=\(apiKey)"
        log.info("[Gemini] POST \(self.baseURL)/v1beta/models/\(self.modelIdentifier):generateContent (prompt: \(content.count) chars)")

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180 // 3 minutes for large prompts
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": content]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
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

        // Parse Gemini response structure
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let candidateContent = firstCandidate["content"] as? [String: Any],
              let parts = candidateContent["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Gemini] Could not parse response structure. Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }

        log.info("[Gemini] Got text response: \(text.count) chars")
        log.debug("[Gemini] Response preview: \(String(text.prefix(200)))")
        return text
    }

    // MARK: - Parsing

    private func parseExtractionResponse(_ text: String) throws -> ExtractionResponse {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode(ExtractionResponse.self, from: data)
        } catch {
            log.error("[Gemini] JSON decode failed for ExtractionResponse: \(error)")
            log.error("[Gemini] Cleaned JSON (first 300): \(String(cleaned.prefix(300)))")
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    private func parseEdgesResponse(_ text: String) throws -> [RawEdge] {
        let cleaned = extractJSON(from: text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode([RawEdge].self, from: data)
        } catch {
            // Try as ExtractionResponse wrapper
            if let response = try? JSONDecoder().decode(ExtractionResponse.self, from: data) {
                return response.edges
            }
            log.error("[Gemini] JSON decode failed for edges: \(error)")
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
