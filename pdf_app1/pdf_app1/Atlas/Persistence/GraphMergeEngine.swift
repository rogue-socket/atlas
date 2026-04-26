//
//  GraphMergeEngine.swift
//  Atlas
//
//  Cross-document entity resolution and concept merging
//

import Foundation

// MARK: - Merge Proposal

// MARK: - Merge Type
enum MergeType: String {
    case exactMatch
    case semanticEquivalent
    case partialOverlap
}

struct MergeProposal: Identifiable {
    let id = UUID()
    let sourceNode: ConceptNode
    let targetNode: ConceptNode
    let similarity: Double
    let reason: String
    var mergeType: MergeType = .exactMatch
    var llmReason: String?
}

// MARK: - Document Pair Key

struct DocumentPairID: Hashable, Codable {
    let urlA: URL
    let urlB: URL

    init(_ a: URL, _ b: URL) {
        // Canonical ordering so (A,B) == (B,A)
        if a.absoluteString < b.absoluteString {
            self.urlA = a
            self.urlB = b
        } else {
            self.urlA = b
            self.urlB = a
        }
    }
}

// MARK: - Correlation Stats

struct CorrelationStats: Codable {
    var sharedConceptCount: Int = 0
    var edgeCountByType: [String: Int] = [:]
    var lastUpdated: Date = Date()
}

// MARK: - Graph Merge Engine

class GraphMergeEngine {

    /// Find merge proposals between a new document's graph and the existing project graph
    func findMergeProposals(
        newDocumentGraph: KnowledgeGraph,
        projectGraph: KnowledgeGraph
    ) -> [MergeProposal] {
        var proposals: [MergeProposal] = []

        for newNode in newDocumentGraph.allNodes {
            for existingNode in projectGraph.allNodes {
                // Skip if same document
                let newDocs = Set(newNode.sourceAnchors.map { $0.documentURL })
                let existingDocs = Set(existingNode.sourceAnchors.map { $0.documentURL })
                guard newDocs.isDisjoint(with: existingDocs) else { continue }

                let similarity = computeSimilarity(newNode.label, existingNode.label)
                if similarity > 0.7 {
                    proposals.append(MergeProposal(
                        sourceNode: newNode,
                        targetNode: existingNode,
                        similarity: similarity,
                        reason: similarity > 0.95 ? "Exact label match" : "Similar labels"
                    ))
                }
            }
        }

        return proposals.sorted { $0.similarity > $1.similarity }
    }

    // MARK: - Semantic Merge Proposals (LLM-powered)

    func findSemanticMergeProposals(
        newDocumentGraph: KnowledgeGraph,
        projectGraph: KnowledgeGraph,
        backend: any AtlasModel
    ) async throws -> [MergeProposal] {
        // Stage 1: Fast Levenshtein pre-filter (lower threshold for wider net)
        var proposals: [MergeProposal] = []
        var seenPairs: Set<String> = []

        for newNode in newDocumentGraph.allNodes where newNode.level == .concept {
            for existingNode in projectGraph.allNodes where existingNode.level == .concept {
                let newDocs = Set(newNode.sourceAnchors.map { $0.documentURL })
                let existingDocs = Set(existingNode.sourceAnchors.map { $0.documentURL })
                guard newDocs.isDisjoint(with: existingDocs) else { continue }

                let similarity = computeSimilarity(newNode.label, existingNode.label)
                if similarity > 0.5 {
                    let pairKey = [newNode.label, existingNode.label].sorted().joined(separator: "||")
                    guard !seenPairs.contains(pairKey) else { continue }
                    seenPairs.insert(pairKey)

                    let mergeType: MergeType = similarity > 0.95 ? .exactMatch : .semanticEquivalent
                    proposals.append(MergeProposal(
                        sourceNode: newNode,
                        targetNode: existingNode,
                        similarity: similarity,
                        reason: similarity > 0.95 ? "Exact label match" : "Similar labels (Levenshtein: \(Int(similarity * 100))%)",
                        mergeType: mergeType
                    ))
                }
            }
        }

        // Stage 2: LLM semantic match on concept-level nodes
        let newConcepts = newDocumentGraph.conceptNodes().prefix(50).map { (label: $0.label, summary: $0.summary) }
        let existingConcepts = projectGraph.conceptNodes().prefix(50).map { (label: $0.label, summary: $0.summary) }

        if !newConcepts.isEmpty && !existingConcepts.isEmpty {
            let rawMerges = try await backend.proposeMerges(
                documentAConcepts: newConcepts,
                documentBConcepts: existingConcepts
            )

            for raw in rawMerges {
                let pairKey = [raw.labelA, raw.labelB].sorted().joined(separator: "||")
                guard !seenPairs.contains(pairKey) else { continue }
                seenPairs.insert(pairKey)

                guard let sourceNode = newDocumentGraph.allNodes.first(where: { $0.label.lowercased() == raw.labelA.lowercased() }),
                      let targetNode = projectGraph.allNodes.first(where: { $0.label.lowercased() == raw.labelB.lowercased() }) else {
                    continue
                }

                let mergeType = MergeType(rawValue: raw.mergeType ?? "semanticEquivalent") ?? .semanticEquivalent
                proposals.append(MergeProposal(
                    sourceNode: sourceNode,
                    targetNode: targetNode,
                    similarity: raw.confidence,
                    reason: raw.reason,
                    mergeType: mergeType,
                    llmReason: raw.reason
                ))
            }
        }

        return proposals.sorted { $0.similarity > $1.similarity }
    }

    /// Execute an accepted merge: combine two nodes into one, handling hierarchy
    func executeMerge(
        sourceNodeID: UUID,
        targetNodeID: UUID,
        in graph: KnowledgeGraph
    ) {
        guard var targetNode = graph.node(for: targetNodeID),
              let sourceNode = graph.node(for: sourceNodeID) else { return }

        // Merge source anchors
        targetNode.sourceAnchors.append(contentsOf: sourceNode.sourceAnchors)

        // Keep the better summary
        if targetNode.summary == nil {
            targetNode.summary = sourceNode.summary
        }

        // Use higher confidence
        targetNode.confidence = max(targetNode.confidence, sourceNode.confidence)

        // Transfer edges from source to target
        for edge in graph.edges(for: sourceNodeID) {
            // Skip containsEntity edges — re-parenting handles these
            if edge.type == .containsEntity { continue }

            let newSourceID = edge.sourceNodeID == sourceNodeID ? targetNodeID : edge.sourceNodeID
            let newTargetID = edge.targetNodeID == sourceNodeID ? targetNodeID : edge.targetNodeID

            // Skip self-loops (e.g., source had an edge to target before merge)
            guard newSourceID != newTargetID else { continue }

            let newEdge = GraphEdge(
                sourceNodeID: newSourceID,
                targetNodeID: newTargetID,
                type: edge.type,
                confidence: edge.confidence,
                label: edge.label
            )
            graph.addEdge(newEdge)
        }

        // Re-parent child entities of the source under the target
        if sourceNode.level == .concept {
            for entity in graph.entities(for: sourceNodeID) {
                var updated = entity
                updated.parentConceptID = targetNodeID
                graph.updateNode(updated)
            }
        }

        // Update target and remove source
        graph.updateNode(targetNode)
        graph.removeNode(sourceNodeID)
    }

    /// Compute correlation stats between all document pairs in a project
    func computeCorrelationStats(
        projectGraph: KnowledgeGraph,
        documentURLs: [URL]
    ) -> [DocumentPairID: CorrelationStats] {
        var stats: [DocumentPairID: CorrelationStats] = [:]

        for i in 0..<documentURLs.count {
            for j in (i + 1)..<documentURLs.count {
                let pairID = DocumentPairID(documentURLs[i], documentURLs[j])
                let nodesA = Set(projectGraph.nodes(forDocument: documentURLs[i]).map { $0.id })
                let nodesB = Set(projectGraph.nodes(forDocument: documentURLs[j]).map { $0.id })

                // Shared concepts: nodes that have source anchors in both documents
                let sharedNodes = projectGraph.allNodes.filter { node in
                    let docs = Set(node.sourceAnchors.map { $0.documentURL })
                    return docs.contains(documentURLs[i]) && docs.contains(documentURLs[j])
                }

                // Cross-document edges
                var edgeCounts: [String: Int] = [:]
                for edge in projectGraph.allEdges {
                    let sourceInA = nodesA.contains(edge.sourceNodeID)
                    let sourceInB = nodesB.contains(edge.sourceNodeID)
                    let targetInA = nodesA.contains(edge.targetNodeID)
                    let targetInB = nodesB.contains(edge.targetNodeID)

                    if (sourceInA && targetInB) || (sourceInB && targetInA) {
                        edgeCounts[edge.type.rawValue, default: 0] += 1
                    }
                }

                stats[pairID] = CorrelationStats(
                    sharedConceptCount: sharedNodes.count,
                    edgeCountByType: edgeCounts,
                    lastUpdated: Date()
                )
            }
        }

        return stats
    }

    // MARK: - Similarity

    private func computeSimilarity(_ a: String, _ b: String) -> Double {
        let lowA = a.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let lowB = b.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lowA == lowB { return 1.0 }

        // Levenshtein distance normalized
        let maxLen = max(lowA.count, lowB.count)
        guard maxLen > 0 else { return 0 }

        let distance = levenshteinDistance(lowA, lowB)
        return 1.0 - Double(distance) / Double(maxLen)
    }

    private func levenshteinDistance(_ s: String, _ t: String) -> Int {
        let sChars = Array(s)
        let tChars = Array(t)
        let m = sChars.count
        let n = tChars.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = sChars[i - 1] == tChars[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,
                    matrix[i][j - 1] + 1,
                    matrix[i - 1][j - 1] + cost
                )
            }
        }

        return matrix[m][n]
    }
}
