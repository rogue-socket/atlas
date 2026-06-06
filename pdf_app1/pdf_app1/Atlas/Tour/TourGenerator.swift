//
//  TourGenerator.swift
//  Atlas
//

import Foundation
import os.log

private let tourLog = Logger(subsystem: "com.atlas.pdf", category: "tour")

private struct RawTourStop: Codable {
    let label: String
    let narration: String
}

private struct RawTourResponse: Codable {
    let title: String
    let stops: [RawTourStop]
}

enum TourGenerationError: Error, LocalizedError {
    case decoding(String)
    case empty
    case insufficientStops

    var errorDescription: String? {
        switch self {
        case .decoding(let message):
            return "Couldn't parse tour response: \(message)"
        case .empty:
            return "The model didn't return any recognizable themes for this graph."
        case .insufficientStops:
            return "The model didn't return enough recognizable themes for a tour."
        }
    }
}

final class TourGenerator {
    private let model: any AtlasModel

    init(model: any AtlasModel) {
        self.model = model
    }

    func generate(from graph: KnowledgeGraph) async throws -> GuidedTour {
        let candidates = Self.candidateNodes(in: graph)
        let prompt = Self.buildPrompt(nodes: candidates)
        let raw = try await model.generateRawResponse(prompt: prompt)
        let cleaned = JSONRepair.cleanAndRepair(raw)

        guard let data = cleaned.data(using: .utf8) else {
            throw TourGenerationError.decoding("non-utf8 response")
        }

        let parsed: RawTourResponse
        do {
            parsed = try JSONDecoder().decode(RawTourResponse.self, from: data)
        } catch {
            throw TourGenerationError.decoding(error.localizedDescription)
        }

        let labelToNode = candidates.reduce(into: [String: ConceptNode]()) { result, node in
            result[Self.normalizedLabel(node.label)] = node
        }

        var seenNodeIDs = Set<UUID>()
        let resolved: [(nodeID: UUID, narration: String)] = parsed.stops.compactMap { stop in
            guard let node = labelToNode[Self.normalizedLabel(stop.label)] else {
                tourLog.info("[Tour] dropping hallucinated stop: \(stop.label)")
                return nil
            }
            guard !seenNodeIDs.contains(node.id) else {
                tourLog.info("[Tour] dropping duplicate stop: \(stop.label)")
                return nil
            }
            seenNodeIDs.insert(node.id)
            let narration = stop.narration.trimmingCharacters(in: .whitespacesAndNewlines)
            return (node.id, narration.isEmpty ? "Explore \(node.label)." : narration)
        }

        guard !resolved.isEmpty else { throw TourGenerationError.empty }
        guard resolved.count >= 2 else { throw TourGenerationError.insufficientStops }

        let stops = resolved.map { item in
            TourStop(nodeID: item.nodeID, narration: item.narration)
        }

        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return GuidedTour(title: title.isEmpty ? "Guided Tour" : title, stops: stops)
    }

    static func hasTourCandidates(in graph: KnowledgeGraph) -> Bool {
        candidateNodes(in: graph).count >= 2
    }

    static func candidateNodes(in graph: KnowledgeGraph) -> [ConceptNode] {
        let chapters = sorted(uniqueByLabel(graph.nodes(at: .chapter)))
        if chapters.count >= 2 { return chapters }

        let concepts = sorted(uniqueByLabel(graph.nodes(at: .concept)))
        if concepts.count >= 2 { return concepts }

        return sorted(uniqueByLabel(graph.allNodes.filter { $0.level != .entity }))
    }

    static func buildPrompt(nodes: [ConceptNode]) -> String {
        let nodeList = nodes.map { node -> String in
            let summary = node.summary ?? ""
            return "- \(node.label): \(summary)"
        }.joined(separator: "\n")

        return """
        You are designing a guided tour through a concept map for a student. \
        Order the following themes in a pedagogically sensible learning order: \
        start with the most foundational, then build to more advanced ideas. \
        For each stop, write one self-contained sentence explaining why that \
        theme matters. The sentence must still make sense if the user jumps \
        directly to that stop; do not refer to a previous or next stop.

        Themes:
        \(nodeList)

        Respond with ONLY a JSON object of this shape:
        {
          "title": "<short tour title>",
          "stops": [
            {"label": "<exact theme label>", "narration": "<one sentence>"}
          ]
        }
        """
    }

    private static func sorted(_ nodes: [ConceptNode]) -> [ConceptNode] {
        nodes.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private static func uniqueByLabel(_ nodes: [ConceptNode]) -> [ConceptNode] {
        var bestByLabel = [String: ConceptNode]()
        for node in nodes {
            let normalized = normalizedLabel(node.label)
            guard !normalized.isEmpty else { continue }
            guard let existing = bestByLabel[normalized] else {
                bestByLabel[normalized] = node
                continue
            }
            if isCleanerLabel(node.label, than: existing.label) {
                bestByLabel[normalized] = node
            }
        }
        return Array(bestByLabel.values)
    }

    private static func normalizedLabel(_ label: String) -> String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isCleanerLabel(_ candidate: String, than existing: String) -> Bool {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate == trimmedCandidate && existing != trimmedExisting { return true }
        if candidate != trimmedCandidate && existing == trimmedExisting { return false }
        return candidate.count < existing.count
    }
}
