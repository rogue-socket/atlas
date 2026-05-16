//
//  EmbeddingResolver.swift
//  Atlas
//
//  ETR stage 3 — Tiered Resolution.
//
//  Pure helpers (text shaping, content hashing, eligibility, pair generation,
//  similarity classification) live here as static functions for unit-testing.
//  The async orchestrator that calls `AtlasEmbeddingBackend` + the adjudication
//  LLM is layered on top in a separate slice.
//
//  Decisions locked 2026-05-16 (see `atlas/audits/2026-05-16_etr-step1-status.md`):
//   - Embedding text: `"<label>: <type> <summary>"`, drop summary when nil.
//   - Pair scope: cross-doc only — skip pairs whose source-doc sets match.
//   - Levels: only `.concept` / `.entity` eligible; skip document/chapter.
//   - Thresholds: 0.95 auto-merge, 0.85 adjudication floor (PRD defaults).
//

import Foundation
import CryptoKit
import os.log

private let log = AtlasLogger.embedding

// MARK: - Tunables

struct ResolverThresholds: Sendable, Equatable {
    var autoMerge: Float = 0.95
    var adjudicationFloor: Float = 0.85
    var adjudicationBatchSize: Int = 18
    static let `default` = ResolverThresholds()
}

// MARK: - Result types

enum ClassificationBand: Sendable, Equatable {
    case autoMerge       // sim ≥ autoMerge
    case adjudication    // adjudicationFloor ≤ sim < autoMerge
    case reject          // sim < adjudicationFloor
}

enum MergeReason: String, Codable, Sendable {
    case exactLabel       // case-insensitive label match — force-merge regardless of sim
    case highSimilarity   // sim ≥ autoMerge threshold
    case llmAdjudicated   // LLM said merge inside the adjudication band
}

struct MergeCandidate: Sendable, Equatable {
    let aID: UUID
    let bID: UUID
    let similarity: Float
}

struct MergeDecision: Sendable, Equatable {
    let aID: UUID
    let bID: UUID
    let similarity: Float
    let reason: MergeReason
}

struct MergePlan: Sendable {
    let decisions: [MergeDecision]
    let thresholds: ResolverThresholds
}

// MARK: - Pure helpers

enum EmbeddingResolver {

    /// The string we feed to the embedding model for `node`.
    /// `"<label>: <type> <summary>"` when summary present;
    /// `"<label>: <type>"` when nil (no synthetic placeholder — placeholders
    /// would pull all summary-less nodes toward one shared vector region).
    static func embeddingText(for node: ConceptNode) -> String {
        let head = "\(node.label): \(node.type.rawValue)"
        guard let summary = node.summary, !summary.isEmpty else { return head }
        return "\(head) \(summary)"
    }

    /// Stable hash of the fields that go into the embedding text. When this
    /// changes for a given node, its cached vector is stale and must be
    /// re-embedded. Includes the summary literal even when nil-or-empty
    /// (as `""`) so a nil → "x" transition invalidates correctly.
    static func contentHash(for node: ConceptNode) -> String {
        let input = "\(node.label):\(node.type.rawValue):\(node.summary ?? "")"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// True iff `node` is at a level ETR is allowed to merge. Document and
    /// chapter nodes are structural containers (filename labels, section
    /// headers) and don't participate in semantic merging.
    static func isEligible(_ node: ConceptNode) -> Bool {
        switch node.level {
        case .concept, .entity: return true
        case .document, .chapter: return false
        }
    }

    static func eligibleNodes(in graph: KnowledgeGraph) -> [ConceptNode] {
        graph.allNodes.filter(isEligible)
    }

    /// Cross-doc pair filter. Returns false (skip) when both nodes have the
    /// **exact same set** of source documents — that includes the common case
    /// of "both came from the same single doc" and the rarer "both already
    /// merged across the same docs."
    static func isCrossDoc(_ a: ConceptNode, _ b: ConceptNode) -> Bool {
        let setA = Set(a.sourceAnchors.map { $0.documentURL })
        let setB = Set(b.sourceAnchors.map { $0.documentURL })
        return setA != setB
    }

    /// All eligible pairs to compare. n²/2 generation — at ~250 nodes that's
    /// ~31k pairs, trivial. Returns pairs as `(aID, bID)` tuples with `aID <
    /// bID` (UUID lexicographic) so pair generation is deterministic and
    /// each unordered pair appears exactly once.
    static func pairsToCompare(among nodes: [ConceptNode]) -> [(UUID, UUID)] {
        var pairs: [(UUID, UUID)] = []
        pairs.reserveCapacity(nodes.count * (nodes.count - 1) / 2)
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                guard isCrossDoc(a, b) else { continue }
                if a.id.uuidString < b.id.uuidString {
                    pairs.append((a.id, b.id))
                } else {
                    pairs.append((b.id, a.id))
                }
            }
        }
        return pairs
    }

    static func classify(similarity: Float,
                         thresholds: ResolverThresholds) -> ClassificationBand {
        if similarity >= thresholds.autoMerge { return .autoMerge }
        if similarity >= thresholds.adjudicationFloor { return .adjudication }
        return .reject
    }

    /// Case-insensitive label match force-merges regardless of similarity.
    /// "Helena Vargas" == "helena vargas" must always merge even if the
    /// summaries embed to differ vectors.
    static func isExactLabelMatch(_ a: ConceptNode, _ b: ConceptNode) -> Bool {
        a.label.lowercased() == b.label.lowercased()
    }
}

// MARK: - Async orchestrator

extension EmbeddingResolver {

    /// Drives ETR stage 3 end-to-end. Loads the per-project embedding cache,
    /// fills cache misses via `embeddingBackend`, computes pairwise cosine
    /// across eligible nodes, classifies each pair against `thresholds`,
    /// batches the adjudication band through `llmBackend`, and returns the
    /// `MergePlan` for stage 4 to apply.
    ///
    /// When `llmBackend` is nil, the adjudication band is logged + dropped
    /// (only auto-merges land in the plan). Useful for cheap dry-runs that
    /// skip LLM cost — `resolve(... llmBackend: nil ...)`.
    static func resolve(
        graph: KnowledgeGraph,
        projectID: UUID,
        embeddingBackend: any AtlasEmbeddingBackend,
        llmBackend: (any AtlasModel)? = nil,
        thresholds: ResolverThresholds = .default
    ) async throws -> MergePlan {
        log.info("[ETR] thresholds: autoMerge=\(thresholds.autoMerge) adjudicationFloor=\(thresholds.adjudicationFloor) batch=\(thresholds.adjudicationBatchSize)")

        let eligible = eligibleNodes(in: graph)
        log.info("[ETR] eligible: \(eligible.count) nodes (concept+entity)")
        guard eligible.count >= 2 else {
            return MergePlan(decisions: [], thresholds: thresholds)
        }

        // 1. Load (or initialize) cache; whole-file invalidate on model/dim drift.
        var cache = EmbeddingCacheStore.load(for: projectID)
            ?? EmbeddingCache.empty(modelIdentifier: embeddingBackend.modelIdentifier,
                                    vectorDimension: embeddingBackend.vectorDimension)
        if cache.modelIdentifier != embeddingBackend.modelIdentifier
            || cache.vectorDimension != embeddingBackend.vectorDimension {
            log.info("[ETR] cache model/dim mismatch — discarding (was \(cache.modelIdentifier) dim=\(cache.vectorDimension); now \(embeddingBackend.modelIdentifier) dim=\(embeddingBackend.vectorDimension))")
            cache = EmbeddingCache.empty(modelIdentifier: embeddingBackend.modelIdentifier,
                                         vectorDimension: embeddingBackend.vectorDimension)
        }

        // 2. Per-node resolve: cache hit or queue for fresh embed.
        struct Pending { let node: ConceptNode; let hash: String }
        var resolved: [UUID: [Float]] = [:]
        var pending: [Pending] = []
        for node in eligible {
            let h = contentHash(for: node)
            if let v = cache.vector(for: node.id, expectedHash: h) {
                resolved[node.id] = v
            } else {
                pending.append(Pending(node: node, hash: h))
            }
        }
        log.info("[ETR] cache: \(resolved.count) hits, \(pending.count) misses")

        if !pending.isEmpty {
            let texts = pending.map { embeddingText(for: $0.node) }
            let vectors = try await embeddingBackend.embed(texts)
            guard vectors.count == pending.count else {
                throw AIError.decodingError("ETR embed: backend returned \(vectors.count) vectors for \(pending.count) inputs")
            }
            for (p, v) in zip(pending, vectors) {
                resolved[p.node.id] = v
                cache.put(nodeID: p.node.id, contentHash: p.hash, vector: v)
            }
        }

        // 3. Save cache with orphan cleanup (drops entries for nodes
        //    no longer in the graph — e.g. after a prior merge).
        cache.retain(Set(eligible.map { $0.id }))
        do {
            try EmbeddingCacheStore.save(cache, for: projectID)
        } catch {
            log.error("[ETR] cache save failed: \(error.localizedDescription) — continuing")
        }

        // 4. Pairwise cosine + classify.
        let nodesByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })
        let pairs = pairsToCompare(among: eligible)
        log.info("[ETR] pairs to evaluate: \(pairs.count)")

        var autoMerges: [MergeDecision] = []
        var adjudicationCandidates: [MergeCandidate] = []

        for (aID, bID) in pairs {
            guard let va = resolved[aID], let vb = resolved[bID],
                  let a = nodesByID[aID], let b = nodesByID[bID] else { continue }
            let sim = EmbeddingMath.cosineSimilarity(va, vb)

            if isExactLabelMatch(a, b) {
                autoMerges.append(MergeDecision(aID: aID, bID: bID, similarity: sim, reason: .exactLabel))
                continue
            }
            switch classify(similarity: sim, thresholds: thresholds) {
            case .autoMerge:
                autoMerges.append(MergeDecision(aID: aID, bID: bID, similarity: sim, reason: .highSimilarity))
            case .adjudication:
                adjudicationCandidates.append(MergeCandidate(aID: aID, bID: bID, similarity: sim))
            case .reject:
                continue
            }
        }
        log.info("[ETR] auto-merges: \(autoMerges.count); adjudication candidates: \(adjudicationCandidates.count)")

        // 5. LLM adjudication for the 0.85-0.95 band.
        var adjudicated: [MergeDecision] = []
        if !adjudicationCandidates.isEmpty {
            guard let llm = llmBackend else {
                log.info("[ETR] no LLM backend provided; dropping \(adjudicationCandidates.count) adjudication candidates")
                return MergePlan(decisions: autoMerges, thresholds: thresholds)
            }
            let batchSize = max(1, thresholds.adjudicationBatchSize)
            for batchStart in stride(from: 0, to: adjudicationCandidates.count, by: batchSize) {
                let batch = Array(adjudicationCandidates[batchStart..<min(batchStart + batchSize, adjudicationCandidates.count)])
                let pairsForPrompt = batch.compactMap { cand -> (a: ConceptNode, b: ConceptNode)? in
                    guard let a = nodesByID[cand.aID], let b = nodesByID[cand.bID] else { return nil }
                    return (a, b)
                }
                guard pairsForPrompt.count == batch.count else {
                    log.error("[ETR] batch shrink — node lookup failure (\(pairsForPrompt.count)/\(batch.count)); skipping batch")
                    continue
                }
                let prompt = PromptTemplates.mergeAdjudication(pairs: pairsForPrompt)
                let raw = try await llm.generateRawResponse(prompt: prompt)
                let decisions = try PromptTemplates.parseMergeAdjudicationResponse(raw, expectedCount: pairsForPrompt.count)
                for (cand, merge) in zip(batch, decisions) where merge {
                    adjudicated.append(MergeDecision(aID: cand.aID, bID: cand.bID,
                                                     similarity: cand.similarity, reason: .llmAdjudicated))
                }
                log.info("[ETR] adjudication batch [\(batchStart)..<\(batchStart + batch.count)]: \(decisions.filter { $0 }.count)/\(decisions.count) approved")
            }
        }

        let all = autoMerges + adjudicated
        log.info("[ETR] final merge plan: \(all.count) decisions (auto=\(autoMerges.count), adjudicated=\(adjudicated.count))")
        return MergePlan(decisions: all, thresholds: thresholds)
    }
}
