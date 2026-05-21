//
//  GeminiEmbeddingBackend.swift
//  Atlas
//
//  Google Gemini embedding API for ETR. Defaults to gemini-embedding-2-preview
//  (3072-dim, live-tested 2026-05-16); gemini-embedding-001 is the fallback if
//  the preview model deprecates. Hits the batchEmbedContents endpoint so one
//  HTTP call covers up to 100 inputs.
//

import Foundation
import os.log

private let log = AtlasLogger.embedding

final class GeminiEmbeddingBackend: AtlasEmbeddingBackend, @unchecked Sendable {
    let displayName = "Google Gemini Embeddings"
    let modelIdentifier: String
    let vectorDimension: Int
    private let apiKey: String
    private let baseURL: String
    private let session: URLSession

    /// Gemini's batchEmbedContents endpoint accepts up to 100 requests per
    /// call (per Google's docs as of 2026-05). Chunk input to fit.
    private static let maxBatchSize = 100

    var isAvailable: Bool { !apiKey.isEmpty }

    init(
        apiKey: String,
        model: String = "gemini-embedding-2-preview",
        vectorDimension: Int = 3072,
        baseURL: String = "https://generativelanguage.googleapis.com"
    ) {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.vectorDimension = vectorDimension
        self.baseURL = baseURL
        self.session = URLSession.shared
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard isAvailable else { throw AIError.noAPIKey }

        var out: [[Float]] = []
        out.reserveCapacity(texts.count)

        for chunkStart in stride(from: 0, to: texts.count, by: Self.maxBatchSize) {
            let chunkEnd = min(chunkStart + Self.maxBatchSize, texts.count)
            let chunk = Array(texts[chunkStart..<chunkEnd])
            log.info("[Embed] POST batchEmbedContents (chunk \(chunkStart)..<\(chunkEnd), \(chunk.count) inputs)")
            let vectors = try await batchEmbed(chunk)
            out.append(contentsOf: vectors)
        }

        guard out.count == texts.count else {
            log.error("[Embed] response count mismatch: got \(out.count), expected \(texts.count)")
            throw AIError.invalidResponse
        }
        return out
    }

    private func batchEmbed(_ texts: [String]) async throws -> [[Float]] {
        let endpoint = "\(baseURL)/v1beta/models/\(modelIdentifier):batchEmbedContents?key=\(apiKey)"

        let url = URL(string: endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Each input becomes one Content with one text Part. The `model`
        // field in each request must include the full path prefix.
        let modelPath = "models/\(modelIdentifier)"
        let requests = texts.map { text in
            [
                "model": modelPath,
                "content": ["parts": [["text": text]]]
            ] as [String: Any]
        }
        let body: [String: Any] = ["requests": requests]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            log.error("[Embed] response is not HTTPURLResponse")
            throw AIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Embed] HTTP \(http.statusCode): \(String(msg.prefix(300)))")
            throw AIError.httpError(statusCode: http.statusCode, message: msg)
        }

        let parsed: BatchEmbedResponse
        do {
            parsed = try JSONDecoder().decode(BatchEmbedResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            log.error("[Embed] decode failed: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }

        let vectors = parsed.embeddings.map { $0.values }
        for (i, v) in vectors.enumerated() where v.count != vectorDimension {
            log.error("[Embed] dimension mismatch at index \(i): got \(v.count), expected \(self.vectorDimension)")
            throw AIError.invalidResponse
        }
        return vectors
    }
}

private struct BatchEmbedResponse: Decodable {
    let embeddings: [Embedding]
    struct Embedding: Decodable {
        let values: [Float]
    }
}
