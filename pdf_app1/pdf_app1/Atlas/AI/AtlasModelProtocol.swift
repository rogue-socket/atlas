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

// MARK: - Raw Chapter (from AI, or synthesized from PDF outline)

/// A chapter boundary the LLM (or the PDF outline) identified.
/// `pageStart` / `pageEnd` are 0-indexed and inclusive on both ends.
struct RawChapter: Codable, Hashable {
    let title: String
    let pageStart: Int
    let pageEnd: Int
    /// Optional one-line description; populated by LLM chapter pass, nil
    /// when the chapter came from the PDF outline (no description there).
    let summary: String?
}

struct ChapterExtractionResponse: Codable {
    let chapters: [RawChapter]
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

    /// Verify the backend is reachable before a run starts. Default: no-op.
    /// Backends with an out-of-process dependency (e.g. a local sidecar)
    /// override this to fail fast with an actionable error.
    func preflight() async throws

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept]
    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge]
    func summarizeConcept(_ label: String, sourceText: String) async throws -> String
    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations
    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal]

    func generateRawResponse(prompt: String) async throws -> String
}

extension AtlasModel {
    func preflight() async throws { }

    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal] {
        return []
    }

    func generateRawResponse(prompt: String) async throws -> String {
        throw AIError.modelUnavailable("Raw generation not supported by \(displayName)")
    }
}

// MARK: - Deep Extraction Intermediate Types

struct RawFact: Codable {
    let claim: String
    let textSpan: String
    let type: String
    let confidence: Double?
}

struct RawFactExtractionResponse: Codable {
    let facts: [RawFact]
}

struct DeepConceptCluster: Codable {
    let label: String
    let type: String
    let summary: String?
    let level: String
    let factIndices: [Int]
    let entities: [DeepEntityCluster]?
}

struct DeepEntityCluster: Codable {
    let label: String
    let type: String
    let summary: String?
    let parentLabel: String
    let factIndices: [Int]
}

struct DeepClusterResponse: Codable {
    let concepts: [DeepConceptCluster]
}

// MARK: - Text Chunk (for deep pipeline)

struct TextChunk {
    let text: String
    let pageRange: Range<Int>
    let documentURL: URL
}

// MARK: - AI Backend Type

enum AIBackendType: String, CaseIterable, Codable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case ollama = "Ollama"
    case claudeSubscription = "ClaudeSubscription"
    case codexAgent = "CodexAgent"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Anthropic Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (Local)"
        case .claudeSubscription: return "Claude (Subscription)"
        case .codexAgent: return "Codex Agent"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .ollama, .claudeSubscription, .codexAgent: return false
        default: return true
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .ollama: return "http://localhost:11434"
        case .claudeSubscription: return "http://127.0.0.1:8765"
        case .codexAgent: return "http://127.0.0.1:8775"
        }
    }

    var availableModels: [String] {
        switch self {
        case .claude: return ["claude-sonnet-4-5-20250514", "claude-haiku-4-5-20251001"]
        case .openai: return ["gpt-4o", "gpt-4o-mini", "gpt-4.1-mini"]
        case .gemini: return ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .ollama: return ["llama3.1", "mistral", "qwen2.5"]
        case .claudeSubscription: return ["opus", "sonnet", "haiku"]
        case .codexAgent: return ["gpt-5.5"]
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
