//
//  AtlasModelProtocol.swift
//  Atlas
//
//  Protocol defining the AI backend interface for concept extraction
//

import Foundation

// MARK: - Raw Concept (from AI)

struct RawConcept: Codable {
    let label: String
    let type: String // maps to ConceptType raw value
    let summary: String?
    let textSpan: String // the exact text from the document
    let confidence: Double?
    let level: String?       // "concept" or "entity" — nil for flat extraction
    let parentLabel: String? // label of parent concept (for entities)
    let entities: [RawConcept]? // nested entities when using hierarchical extraction
    let hierarchyLevel: Int? // 0 = top theme, 1+ = sub-concept depth
    let subtopicOf: String?  // label of parent theme (for Novak-style maps)
}

// MARK: - Raw Edge (from AI)

struct RawEdge: Codable {
    let sourceLabel: String
    let targetLabel: String
    let type: String // maps to EdgeType raw value
    let confidence: Double?
    let linkingPhrase: String? // natural-language verb phrase for Novak-style edges
}

// MARK: - Extraction Context

struct ExtractionContext {
    let documentTitle: String
    let pageRange: Range<Int>
    let existingConcepts: [String] // labels of concepts already extracted
    let outlineHints: [String] // TOC entries for structure hints
}

// MARK: - Answer With Citations

struct AnswerWithCitations: Codable {
    let answer: String
    let citations: [Citation]

    struct Citation: Codable {
        let text: String
        let pageIndex: Int?
    }
}

// MARK: - AI Extraction Response

struct ExtractionResponse: Codable {
    let concepts: [RawConcept]
    let edges: [RawEdge]
}

// MARK: - Raw Merge Proposal (from AI)

struct RawMergeProposal: Codable {
    let labelA: String
    let labelB: String
    let confidence: Double
    let reason: String
    let mergeType: String? // "exactMatch", "semanticEquivalent", "partialOverlap"
}

// MARK: - Atlas Model Protocol

protocol AtlasModel: Sendable {
    var displayName: String { get }
    var modelIdentifier: String { get }
    var isAvailable: Bool { get }

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept]
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge]
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String
    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations
    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal]
}

extension AtlasModel {
    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal] {
        // Default: no LLM-based merges — backends override when supported
        return []
    }
}

// MARK: - AI Backend Type

enum AIBackendType: String, CaseIterable, Codable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case ollama = "Ollama"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (Local)"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .ollama: return "http://localhost:11434"
        }
    }

    var availableModels: [String] {
        switch self {
        case .claude: return ["claude-sonnet-4-5-20250514", "claude-haiku-4-5-20251001"]
        case .openai: return ["gpt-4o", "gpt-4o-mini", "gpt-4.1-mini"]
        case .gemini: return ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .ollama: return ["llama3.1", "mistral", "qwen2.5"]
        }
    }
}

// MARK: - AI Error

enum AIError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case networkError(Error)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No API key configured"
        case .invalidResponse: return "Invalid response from AI service"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .decodingError(let msg): return "Failed to decode response: \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .modelUnavailable(let name): return "Model unavailable: \(name)"
        }
    }
}
