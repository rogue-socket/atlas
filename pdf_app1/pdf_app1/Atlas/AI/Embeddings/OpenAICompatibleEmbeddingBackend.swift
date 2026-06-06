//
//  OpenAICompatibleEmbeddingBackend.swift
//  Atlas
//
//  OpenAI-compatible embedding API backend for LAN gateways.
//

import Foundation
import os.log

private let openAIEmbeddingLog = AtlasLogger.embedding

enum OpenAIEmbeddingModelCatalog {
    static let defaultBaseURL = "http://192.168.1.14:8200/v1"
    static let defaultModel = "bge-base-en-v1.5"
    static let defaultAPIKey = "none"

    static let availableModels = [
        "bge-base-en-v1.5",
        "all-minilm-l6-v2"
    ]

    static func vectorDimension(for model: String) -> Int {
        switch model {
        case "all-minilm-l6-v2":
            return 384
        case "bge-base-en-v1.5", "e5-base-v2", "nomic-embed-text-v1":
            return 768
        default:
            return 768
        }
    }

    static func isValidBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }
}

final class OpenAICompatibleEmbeddingBackend: AtlasEmbeddingBackend, @unchecked Sendable {
    let displayName: String
    let modelIdentifier: String
    let vectorDimension: Int

    private let apiKey: String
    private let baseURL: String
    private let session: URLSession
    private static let maxBatchSize = 100

    var isAvailable: Bool { OpenAIEmbeddingModelCatalog.isValidBaseURL(baseURL) }

    init(
        apiKey: String = OpenAIEmbeddingModelCatalog.defaultAPIKey,
        model: String = OpenAIEmbeddingModelCatalog.defaultModel,
        vectorDimension: Int? = nil,
        baseURL: String = OpenAIEmbeddingModelCatalog.defaultBaseURL,
        displayName: String = "LAN Embedding Gateway",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.modelIdentifier = model
        self.vectorDimension = vectorDimension ?? OpenAIEmbeddingModelCatalog.vectorDimension(for: model)
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.displayName = displayName
        self.session = session
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard isAvailable else {
            throw AIError.decodingError("Invalid embedding gateway URL: \(baseURL)")
        }

        var out: [[Float]] = []
        out.reserveCapacity(texts.count)

        for chunkStart in stride(from: 0, to: texts.count, by: Self.maxBatchSize) {
            let chunkEnd = min(chunkStart + Self.maxBatchSize, texts.count)
            let chunk = Array(texts[chunkStart..<chunkEnd])
            openAIEmbeddingLog.info("[EmbedGateway] POST /embeddings (chunk \(chunkStart)..<\(chunkEnd), \(chunk.count) inputs, model=\(self.modelIdentifier))")
            let vectors = try await embedBatch(chunk)
            out.append(contentsOf: vectors)
        }

        guard out.count == texts.count else {
            throw AIError.decodingError("Embedding gateway returned \(out.count) vectors for \(texts.count) inputs")
        }
        return out
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard let url = URL(string: "\(baseURL)/embeddings") else {
            throw AIError.decodingError("Invalid embedding gateway URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty && apiKey.lowercased() != OpenAIEmbeddingModelCatalog.defaultAPIKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: modelIdentifier, input: texts))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            openAIEmbeddingLog.error("[EmbedGateway] HTTP \(http.statusCode): \(String(msg.prefix(300)))")
            throw AIError.httpError(statusCode: http.statusCode, message: msg)
        }

        let parsed: EmbeddingResponse
        do {
            parsed = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            openAIEmbeddingLog.error("[EmbedGateway] decode failed: \(error). Raw (first 500): \(String(raw.prefix(500)))")
            throw AIError.invalidResponse
        }

        let rows = parsed.data.enumerated().sorted { lhs, rhs in
            let li = lhs.element.index ?? lhs.offset
            let ri = rhs.element.index ?? rhs.offset
            return li < ri
        }
        let vectors = rows.map { $0.element.embedding }
        for (i, v) in vectors.enumerated() where v.count != vectorDimension {
            openAIEmbeddingLog.error("[EmbedGateway] dimension mismatch at index \(i): got \(v.count), expected \(self.vectorDimension)")
            throw AIError.invalidResponse
        }
        return vectors
    }
}

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: [String]
}

private struct EmbeddingResponse: Decodable {
    let data: [EmbeddingData]

    struct EmbeddingData: Decodable {
        let index: Int?
        let embedding: [Float]
    }
}
