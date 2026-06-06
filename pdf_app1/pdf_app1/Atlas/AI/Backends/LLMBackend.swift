//
//  LLMBackend.swift
//  Atlas
//
//  Shared protocol + default implementations for HTTP-backed LLM providers.
//  Each concrete backend implements only transport(prompt:) and the vendor identity.
//

import Foundation
import os.log

private let log = AtlasLogger.ai

protocol LLMBackend: AtlasModel {
    var logTag: String { get }
    func transport(prompt: String) async throws -> String
}

extension LLMBackend {
    func extractConceptGraph(from text: String, context: ExtractionContext) async throws -> ExtractionResponse {
        log.info("[\(self.logTag)] extractConcepts: prompt \(text.count) chars")
        let prompt = PromptTemplates.conceptExtraction(text: text, context: context)
        let response = try await transport(prompt: prompt)
        do {
            let parsed = try LLMResponseParser.parseExtractionResponse(response)
            log.info("[\(self.logTag)] Parsed \(parsed.concepts.count) concepts, \(parsed.edges.count) edges from response")
            return parsed
        } catch {
            log.error("[\(self.logTag)] Failed to parse extraction response: \(error)")
            log.error("[\(self.logTag)] Raw response (first 500 chars): \(String(response.prefix(500)))")
            throw error
        }
    }

    func extractConcepts(from text: String, context: ExtractionContext) async throws -> [RawConcept] {
        try await extractConceptGraph(from: text, context: context).concepts
    }

    func proposeEdges(between candidates: [EdgeProposalCandidate], context: String) async throws -> [RawEdge] {
        log.info("[\(self.logTag)] proposeEdges for \(candidates.count) candidates")
        let prompt = PromptTemplates.edgeProposal(candidates: candidates, context: context)
        let response = try await transport(prompt: prompt)
        do {
            let edges = try LLMResponseParser.parseEdgesResponse(response)
            log.info("[\(self.logTag)] Parsed \(edges.count) edges")
            return edges
        } catch {
            log.error("[\(self.logTag)] Failed to parse edges response: \(error)")
            log.error("[\(self.logTag)] Raw response (first 500 chars): \(String(response.prefix(500)))")
            throw error
        }
    }

    func proposeEdges(between concepts: [String], context: String) async throws -> [RawEdge] {
        let candidates = concepts.map {
            EdgeProposalCandidate(label: $0, level: .concept, type: .concept, parentLabel: nil, summary: nil)
        }
        return try await proposeEdges(between: candidates, context: context)
    }

    func summarizeConcept(_ label: String, sourceText: String) async throws -> String {
        log.info("[\(self.logTag)] summarizeConcept: \(label)")
        let prompt = PromptTemplates.summarize(conceptLabel: label, sourceText: sourceText)
        return try await transport(prompt: prompt)
    }

    func answerQuestion(_ question: String, context: String) async throws -> AnswerWithCitations {
        log.info("[\(self.logTag)] answerQuestion: \(question.prefix(80))")
        let prompt = PromptTemplates.questionAnswer(question: question, context: context)
        let response = try await transport(prompt: prompt)
        return try LLMResponseParser.parseAnswerResponse(response)
    }

    func proposeMerges(
        documentAConcepts: [(label: String, summary: String?)],
        documentBConcepts: [(label: String, summary: String?)]
    ) async throws -> [RawMergeProposal] {
        log.info("[\(self.logTag)] proposeMerges: \(documentAConcepts.count) vs \(documentBConcepts.count) concepts")
        let prompt = PromptTemplates.semanticMergeProposal(
            documentATitle: "Document A",
            documentAConcepts: documentAConcepts,
            documentBTitle: "Document B",
            documentBConcepts: documentBConcepts
        )
        let response = try await transport(prompt: prompt)
        let merges = LLMResponseParser.parseMergesResponse(response)
        log.info("[\(self.logTag)] proposeMerges: \(merges.count) merge proposals")
        return merges
    }

    func generateRawResponse(prompt: String) async throws -> String {
        try await transport(prompt: prompt)
    }
}

enum LLMResponseParser {
    static func parseExtractionResponse(_ text: String) throws -> ExtractionResponse {
        let cleaned = JSONRepair.cleanAndRepair(text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode(ExtractionResponse.self, from: data)
        } catch {
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    static func parseEdgesResponse(_ text: String) throws -> [RawEdge] {
        let cleaned = JSONRepair.cleanAndRepair(text)
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

    static func parseAnswerResponse(_ text: String) throws -> AnswerWithCitations {
        let cleaned = JSONRepair.cleanAndRepair(text)
        guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }
        do {
            return try JSONDecoder().decode(AnswerWithCitations.self, from: data)
        } catch {
            throw AIError.decodingError(error.localizedDescription)
        }
    }

    static func parseMergesResponse(_ text: String) -> [RawMergeProposal] {
        let cleaned = JSONRepair.cleanAndRepair(text)
        guard let data = cleaned.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RawMergeProposal].self, from: data)) ?? []
    }
}
