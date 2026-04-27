//
//  DeepExtractionPipeline.swift
//  Atlas
//
//  3-pass deep extraction: facts → clustering/dedup → cross-referencing
//

import Foundation
import CoreGraphics
import Observation
import os.log

private let log = AtlasLogger.pipeline

@Observable
class DeepExtractionPipeline {
    var isProcessing: Bool = false
    var currentPass: Int = 0
    var statusMessage: String = ""

    func processChunks(
        _ chunks: [TextChunk],
        backend: any AtlasModel,
        graph: KnowledgeGraph,
        documentURL: URL
    ) async {
        guard !chunks.isEmpty else { return }
        isProcessing = true

        // Pass 1: Extract raw facts from each chunk
        currentPass = 1
        statusMessage = "Pass 1/3: Extracting facts..."
        log.info("[Deep] Pass 1: extracting facts from \(chunks.count) chunks")

        var allFacts: [IndexedFact] = []

        for chunk in chunks {
            if Task.isCancelled { break }
            do {
                let prompt = PromptTemplates.deepFactExtraction(
                    text: chunk.text,
                    documentTitle: documentURL.lastPathComponent,
                    pageRange: chunk.pageRange
                )
                let response = try await backend.generateRawResponse(prompt: prompt)
                let cleaned = JSONRepair.cleanAndRepair(response)
                guard let data = cleaned.data(using: .utf8) else { continue }
                let parsed = try JSONDecoder().decode(RawFactExtractionResponse.self, from: data)

                for fact in parsed.facts {
                    allFacts.append(IndexedFact(fact: fact, pageRange: chunk.pageRange, textChunk: chunk.text))
                }
                log.info("[Deep] Pass 1: chunk pages \(chunk.pageRange.lowerBound+1)-\(chunk.pageRange.upperBound) → \(parsed.facts.count) facts")
            } catch {
                log.error("[Deep] Pass 1 error for chunk: \(error)")
            }
        }

        if allFacts.isEmpty || Task.isCancelled {
            isProcessing = false
            statusMessage = allFacts.isEmpty ? "No facts extracted" : "Cancelled"
            return
        }

        // Pass 2: Cluster and deduplicate
        currentPass = 2
        statusMessage = "Pass 2/3: Clustering & deduplicating \(allFacts.count) facts..."
        log.info("[Deep] Pass 2: clustering \(allFacts.count) facts")

        let clusters: [DeepConceptCluster]
        do {
            let rawFacts = allFacts.map { $0.fact }
            let prompt = PromptTemplates.deepClustering(facts: rawFacts, documentTitle: documentURL.lastPathComponent)
            let response = try await backend.generateRawResponse(prompt: prompt)
            let cleaned = JSONRepair.cleanAndRepair(response)
            guard let data = cleaned.data(using: .utf8) else {
                isProcessing = false
                statusMessage = "Failed to parse clustering response"
                return
            }
            let parsed = try JSONDecoder().decode(DeepClusterResponse.self, from: data)
            clusters = parsed.concepts
            log.info("[Deep] Pass 2: produced \(clusters.count) concept clusters")
        } catch {
            log.error("[Deep] Pass 2 error: \(error)")
            isProcessing = false
            statusMessage = "Clustering failed: \(error.localizedDescription)"
            return
        }

        // Integrate Pass 2 results into graph
        for cluster in clusters {
            let anchors = sourceAnchors(for: cluster.factIndices, from: allFacts, documentURL: documentURL)
            guard !anchors.isEmpty else { continue }

            let existingNode = graph.allNodes.first { $0.label.lowercased() == cluster.label.lowercased() }
            let conceptNodeID: UUID

            if var existing = existingNode {
                existing.sourceAnchors.append(contentsOf: anchors)
                if let summary = cluster.summary, existing.summary == nil {
                    existing.summary = summary
                }
                graph.updateNode(existing)
                conceptNodeID = existing.id
            } else {
                let conceptType = ConceptType(rawValue: cluster.type) ?? .concept
                let colorIndex = graph.nextHighlightColorIndex()
                let node = ConceptNode(
                    label: cluster.label,
                    type: conceptType,
                    summary: cluster.summary,
                    sourceAnchors: anchors,
                    confidence: 0.9,
                    level: .concept,
                    highlightColorIndex: colorIndex
                )
                graph.addNode(node)
                conceptNodeID = node.id
            }

            // Process entities
            guard let entities = cluster.entities else { continue }
            for entity in entities {
                let entityAnchors = sourceAnchors(for: entity.factIndices, from: allFacts, documentURL: documentURL)
                guard !entityAnchors.isEmpty else { continue }

                let existingEntity = graph.allNodes.first { $0.label.lowercased() == entity.label.lowercased() }

                if var existing = existingEntity {
                    existing.sourceAnchors.append(contentsOf: entityAnchors)
                    if existing.parentConceptID == nil {
                        existing.parentConceptID = conceptNodeID
                    }
                    graph.updateNode(existing)
                } else {
                    let entityType = ConceptType(rawValue: entity.type) ?? .definition
                    let parentColor = graph.node(for: conceptNodeID)?.highlightColorIndex
                    let entityNode = ConceptNode(
                        label: entity.label,
                        type: entityType,
                        summary: entity.summary,
                        sourceAnchors: entityAnchors,
                        confidence: 0.85,
                        level: .entity,
                        parentConceptID: conceptNodeID,
                        highlightColorIndex: parentColor
                    )
                    graph.addNode(entityNode)

                    let containsEdge = GraphEdge(
                        sourceNodeID: conceptNodeID,
                        targetNodeID: entityNode.id,
                        type: .containsEntity,
                        confidence: 1.0
                    )
                    graph.addEdge(containsEdge)
                }
            }
        }

        // Pass 3: Cross-reference
        currentPass = 3
        statusMessage = "Pass 3/3: Cross-referencing \(graph.nodeCount) concepts..."
        log.info("[Deep] Pass 3: cross-referencing \(graph.nodeCount) concepts")

        do {
            let conceptSummaries = graph.conceptNodes().map { (label: $0.label, summary: $0.summary) }
            let prompt = PromptTemplates.deepCrossReference(concepts: conceptSummaries, documentTitle: documentURL.lastPathComponent)
            let response = try await backend.generateRawResponse(prompt: prompt)
            let cleaned = JSONRepair.cleanAndRepair(response)
            guard let data = cleaned.data(using: .utf8) else {
                isProcessing = false
                statusMessage = "Done — \(graph.nodeCount) concepts (cross-ref parse failed)"
                return
            }
            let rawEdges = try JSONDecoder().decode([RawEdge].self, from: data)

            var added = 0
            for rawEdge in rawEdges {
                guard let sourceNode = graph.allNodes.first(where: { $0.label.lowercased() == rawEdge.sourceLabel.lowercased() }),
                      let targetNode = graph.allNodes.first(where: { $0.label.lowercased() == rawEdge.targetLabel.lowercased() }) else {
                    continue
                }

                let exists = graph.allEdges.contains {
                    ($0.sourceNodeID == sourceNode.id && $0.targetNodeID == targetNode.id) ||
                    ($0.sourceNodeID == targetNode.id && $0.targetNodeID == sourceNode.id)
                }
                guard !exists else { continue }

                let edgeType = EdgeType(rawValue: rawEdge.type) ?? .sameTopic
                guard edgeType != .containsEntity else { continue }
                let edge = GraphEdge(
                    sourceNodeID: sourceNode.id,
                    targetNodeID: targetNode.id,
                    type: edgeType,
                    confidence: rawEdge.confidence ?? 0.7
                )
                graph.addEdge(edge)
                added += 1
            }
            log.info("[Deep] Pass 3: added \(added) cross-reference edges")
        } catch {
            log.error("[Deep] Pass 3 error: \(error)")
        }

        isProcessing = false
        statusMessage = "Done — \(graph.nodeCount) concepts, \(graph.edgeCount) edges (Deep)"
        log.info("[Deep] Complete: \(graph.nodeCount) nodes, \(graph.edgeCount) edges")
    }

    // MARK: - Helpers

    private func sourceAnchors(
        for factIndices: [Int],
        from allFacts: [IndexedFact],
        documentURL: URL
    ) -> [SourceAnchor] {
        var seen = Set<Int>()
        var anchors: [SourceAnchor] = []

        for idx in factIndices {
            guard idx >= 0, idx < allFacts.count else { continue }
            let indexed = allFacts[idx]
            let pageIndex = indexed.pageRange.lowerBound
            guard !seen.contains(pageIndex) else { continue }
            seen.insert(pageIndex)

            anchors.append(SourceAnchor(
                documentURL: documentURL,
                pageIndex: pageIndex,
                boundingBox: .zero,
                textSnippet: String(indexed.fact.textSpan.prefix(200))
            ))
        }
        return anchors
    }
}

// MARK: - Internal Types

struct IndexedFact {
    let fact: RawFact
    let pageRange: Range<Int>
    let textChunk: String
}
