//
//  GuidedTourGenerator.swift
//  Atlas
//
//  Builds a guided learning tour from a completed knowledge graph.
//

import Foundation
import os.log

private let tourLog = AtlasLogger.pipeline

enum GuidedTourGenerator {
    private struct TourResponse: Decodable {
        let stops: [TourStopResponse]
    }

    private struct TourStopResponse: Decodable {
        let nodeID: UUID
        let narration: String
    }

    static func generate(
        graph: KnowledgeGraph,
        documentURL: URL,
        backend: any AtlasModel,
        maxStops: Int = 8
    ) async -> GuidedTour? {
        let candidates = tourCandidates(in: graph, documentURL: documentURL, maxCandidates: 24)
        guard !candidates.isEmpty else { return nil }

        do {
            let prompt = PromptTemplates.guidedTour(
                candidates: candidates,
                edges: graph.allEdges,
                documentTitle: documentURL.lastPathComponent,
                maxStops: maxStops
            )
            let response = try await backend.generateRawResponse(prompt: prompt)
            let cleaned = JSONRepair.cleanAndRepair(response)
            guard let data = cleaned.data(using: .utf8) else {
                return fallbackTour(candidates: candidates, documentURL: documentURL, backend: backend, maxStops: maxStops)
            }
            let parsed = try JSONDecoder().decode(TourResponse.self, from: data)
            let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
            var seen = Set<UUID>()
            let stops = parsed.stops.compactMap { stop -> GuidedTourStop? in
                guard let node = byID[stop.nodeID],
                      !seen.contains(node.id) else { return nil }
                let narration = stop.narration.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !narration.isEmpty else { return nil }
                seen.insert(node.id)
                return GuidedTourStop(nodeID: node.id, title: node.label, narration: narration)
            }
            guard !stops.isEmpty else {
                return fallbackTour(candidates: candidates, documentURL: documentURL, backend: backend, maxStops: maxStops)
            }
            return GuidedTour(
                documentURL: documentURL,
                stops: Array(stops.prefix(maxStops)),
                generatedByModel: backend.modelIdentifier
            )
        } catch {
            tourLog.error("[GuidedTour] generation failed for \(documentURL.lastPathComponent): \(error.localizedDescription)")
            return fallbackTour(candidates: candidates, documentURL: documentURL, backend: backend, maxStops: maxStops)
        }
    }

    static func tourCandidates(
        in graph: KnowledgeGraph,
        documentURL: URL,
        maxCandidates: Int
    ) -> [ConceptNode] {
        let anchored = graph.allNodes.filter { node in
            node.sourceAnchors.contains { $0.documentURL == documentURL }
        }
        let nonEntity = anchored.filter { $0.level != .entity }
        let source = nonEntity.isEmpty ? anchored : nonEntity

        return source.sorted { lhs, rhs in
            if lhs.level != rhs.level { return lhs.level.sortRank < rhs.level.sortRank }
            let leftDegree = graph.degree(of: lhs.id)
            let rightDegree = graph.degree(of: rhs.id)
            if leftDegree != rightDegree { return leftDegree > rightDegree }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
        .prefix(maxCandidates)
        .map { $0 }
    }

    private static func fallbackTour(
        candidates: [ConceptNode],
        documentURL: URL,
        backend: any AtlasModel,
        maxStops: Int
    ) -> GuidedTour {
        let stops = Array(candidates.prefix(maxStops)).enumerated().map { index, node in
            let narration: String
            if index == 0 {
                narration = "Start with \(node.label). This is a useful entry point for the map because it sits near the top of the document structure."
            } else {
                narration = "Now that you have seen the earlier themes, move to \(node.label) to connect the next major idea in the map."
            }
            return GuidedTourStop(nodeID: node.id, title: node.label, narration: narration)
        }
        return GuidedTour(
            documentURL: documentURL,
            stops: stops,
            generatedByModel: "\(backend.modelIdentifier)-fallback"
        )
    }
}

private extension NodeLevel {
    var sortRank: Int {
        switch self {
        case .document: return 0
        case .chapter: return 1
        case .concept: return 2
        case .entity: return 3
        }
    }
}
