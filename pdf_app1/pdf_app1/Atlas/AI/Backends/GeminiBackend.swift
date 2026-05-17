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

    // Updated on every transport(prompt:) call. Reads/writes happen on the
    // same task that drives the extraction loop (sequential by design), so
    // no synchronization is needed despite @unchecked Sendable.
    var lastResponsePromptTokens: Int?

    var isAvailable: Bool { !apiKey.isEmpty }

    init(
        apiKey: String,
        model: String = "gemini-3.1-pro-preview",
        baseURL: String = "https://generativelanguage.googleapis.com"
    ) {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    func transport(prompt: String) async throws -> String {
        try await transport(prompt: prompt, responseSchema: nil)
    }

    /// SCE Option D+E: when `responseSchema` is non-nil it is wired into
    /// Gemini's `generationConfig.responseSchema`. Used by `extractConcepts`
    /// to constrain `prior_label_match` to an enum of the actual prior-doc
    /// labels, making hallucinations impossible at the decoder level.
    func transport(prompt: String, responseSchema: [String: Any]?) async throws -> String {
        guard isAvailable else { throw AIError.noAPIKey }

        let endpoint = "\(baseURL)/v1beta/models/\(modelIdentifier):generateContent?key=\(apiKey)"
        log.info("[Gemini] POST \(self.baseURL)/v1beta/models/\(self.modelIdentifier):generateContent (prompt: \(prompt.count) chars, schema=\(responseSchema != nil))")

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = [
            "temperature": 0.1,
            "maxOutputTokens": 32768,
            "responseMimeType": "application/json"
        ]
        if let schema = responseSchema {
            generationConfig["responseSchema"] = schema
        }

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": generationConfig
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
        lastResponsePromptTokens = parsed.usageMetadata?.promptTokenCount
        guard let text = parsed.candidates.first?.content.parts.first?.text else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Gemini] Empty candidates/parts. Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }

        log.info("[Gemini] Got text response: \(text.count) chars")
        log.debug("[Gemini] Response preview: \(String(text.prefix(200)))")
        return text
    }

    /// Schema-aware override: when the context carries a non-empty
    /// `priorDocsLabelMap`, construct an OpenAPI-3-flavored response schema
    /// that constrains `prior_label_match` to the canonical prior labels
    /// (Gemini enforces enum at decode-time → 0% hallucinations) and
    /// constrains `match_kind` to the four valid taxonomic values.
    /// Falls back to schema-less transport when no priors exist (doc 1).
    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] {
        log.info("[\(self.logTag)] extractConcepts: prompt \(text.count) chars, prior-labels=\(context.priorDocsLabelMap.count)")
        let prompt = PromptTemplates.conceptExtraction(text: text, context: context)
        // SCE v4 (gemini-3.1-pro-preview): schema disabled. Earlier runs on
        // 2.5-flash showed schema-enabled mode induced verbose responses that
        // truncated past maxOutputTokens. Test stronger model's behavior on
        // prompt-only signal first; if precision lifts, layer the schema back
        // on in a follow-up using 3-series JSON Schema support.
        let response = try await transport(prompt: prompt, responseSchema: nil)
        do {
            let parsed = try LLMResponseParser.parseExtractionResponse(response)
            log.info("[\(self.logTag)] Parsed \(parsed.concepts.count) concepts, \(parsed.edges.count) edges from response")
            return parsed.concepts
        } catch {
            log.error("[\(self.logTag)] Failed to parse extraction response: \(error)")
            log.error("[\(self.logTag)] Raw response (first 500 chars): \(String(response.prefix(500)))")
            throw error
        }
    }

    /// Build the OpenAPI-3 subset Gemini accepts. Gemini's structured-output
    /// mode rejects when the schema's "constraint state" exceeds an internal
    /// budget — empirically ~1500 chars of enum content on gemini-2.5-flash
    /// (the prior-label enum is duplicated across concept + nested-entity
    /// schemas, doubling effective load). We strip newlines/control chars
    /// from labels first (the API explicitly rejects them) and emit the enum
    /// only when ALL cleaned labels fit under budget. When they don't, the
    /// schema falls back to an unconstrained string field — the parser-side
    /// validation (priorDocsLabelMap lookup) catches hallucinations softly.
    /// The all-or-nothing choice (vs. partial enum) preserves match recall
    /// against the long labels we'd otherwise drop entirely.
    static func buildExtractionResponseSchema(priorCanonicalLabels: [String]) -> [String: Any] {
        let matchKindEnum: [String] = ["same_entity", "instance_of", "attribute_of", "process_for"]
        let cleaned: [String] = priorCanonicalLabels
            .map {
                $0.replacingOccurrences(of: "\n", with: " ")
                  .replacingOccurrences(of: "\r", with: " ")
                  .replacingOccurrences(of: "\t", with: " ")
                  .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let totalChars = cleaned.reduce(0) { $0 + $1.count }
        let enumFitsBudget = !cleaned.isEmpty && totalChars <= 1500
        let enumLabels: [String]? = enumFitsBudget ? cleaned : nil

        // Inner concept/entity shape — same for top-level concepts and nested entities.
        var conceptProperties: [String: Any] = [
            "label": ["type": "string"],
            "type": ["type": "string"],
            "summary": ["type": "string"],
            "textSpan": ["type": "string"],
            "confidence": ["type": "number"],
            "match_kind": ["type": "string", "enum": matchKindEnum]
        ]
        if let enumLabels {
            conceptProperties["prior_label_match"] = ["type": "string", "enum": enumLabels]
        } else if !priorCanonicalLabels.isEmpty {
            // Soft-validation fallback: schema permits any string; parser checks against priorDocsLabelMap.
            conceptProperties["prior_label_match"] = ["type": "string"]
        }

        // Entity = same shape as concept minus `entities` (no further nesting).
        let entitySchema: [String: Any] = [
            "type": "object",
            "properties": conceptProperties,
            "required": ["label", "type", "summary", "textSpan", "confidence"]
        ]

        // Top-level concept also has nested entities array.
        var topConceptProperties = conceptProperties
        topConceptProperties["entities"] = [
            "type": "array",
            "items": entitySchema
        ] as [String: Any]
        let conceptSchema: [String: Any] = [
            "type": "object",
            "properties": topConceptProperties,
            "required": ["label", "type", "summary", "textSpan", "confidence"]
        ]

        let edgeSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "sourceLabel": ["type": "string"],
                "targetLabel": ["type": "string"],
                "type": ["type": "string"],
                "confidence": ["type": "number"],
                "linkingPhrase": ["type": "string"]
            ],
            "required": ["sourceLabel", "targetLabel", "type", "confidence"]
        ]

        return [
            "type": "object",
            "properties": [
                "concepts": ["type": "array", "items": conceptSchema],
                "edges": ["type": "array", "items": edgeSchema]
            ],
            "required": ["concepts", "edges"]
        ]
    }
}

private struct GeminiResponse: Decodable {
    let candidates: [Candidate]
    let usageMetadata: UsageMetadata?
    struct Candidate: Decodable {
        let content: Content
    }
    struct Content: Decodable {
        let parts: [Part]
    }
    struct Part: Decodable {
        let text: String
    }
    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
    }
}
