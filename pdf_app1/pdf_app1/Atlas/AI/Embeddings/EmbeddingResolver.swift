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
    /// Bumped 2026-05-16 from 0.85 → 0.80 after the threshold sweep on
    /// vitacare (see `audits/2026-05-16_etr-live-verification.md` §"Threshold
    /// sweep"). 0.80 caught rubric row 8 (care-coordinator cluster) at no
    /// precision cost vs 0.85; LLM kept rejection rate at ~92% so false
    /// positives stayed at zero.
    var adjudicationFloor: Float = 0.80
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

// MARK: - Audit trail (followup #3 from 2026-05-16 sweep)

/// One entry per "interesting" pair the resolver evaluated — every auto-
/// merge and every pair that reached the adjudication band. Rejects (sim
/// below floor) are skipped to keep the file small; if you need them, lower
/// the floor and re-run.
struct ResolverAuditEntry: Codable, Sendable {
    let aID: String
    let aLabel: String
    let aDoc: String?      // primary source-doc filename (first anchor)
    let aLevel: String     // "concept" or "entity"
    let bID: String
    let bLabel: String
    let bDoc: String?
    let bLevel: String
    let similarity: Float
    let band: String       // "autoMerge" | "adjudication" | "exactLabel"
    let exactLabelMatch: Bool
    let llmVerdict: String?  // "approved" | "rejected" | null (no LLM run)
    let finalReason: String? // MergeReason raw value, or nil if not in plan
}

struct ResolverAudit: Codable, Sendable {
    let timestamp: String
    let modelIdentifier: String
    let vectorDimension: Int
    let thresholds: ResolverThresholdsCodable
    let eligibleNodeCount: Int
    let pairsEvaluated: Int
    let entries: [ResolverAuditEntry]

    struct ResolverThresholdsCodable: Codable, Sendable {
        let autoMerge: Float
        let adjudicationFloor: Float
        let adjudicationBatchSize: Int
    }
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
        thresholds: ResolverThresholds = .default,
        auditOutputDir: URL? = nil
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
        // Audit collector: one entry per pair that reached auto-merge or
        // adjudication. Rejects (sim < floor) skipped — adding them would
        // bloat the file from ~100 entries to tens of thousands.
        var auditEntries: [ResolverAuditEntry] = []

        for (aID, bID) in pairs {
            guard let va = resolved[aID], let vb = resolved[bID],
                  let a = nodesByID[aID], let b = nodesByID[bID] else { continue }
            let sim = EmbeddingMath.cosineSimilarity(va, vb)

            if isExactLabelMatch(a, b) {
                autoMerges.append(MergeDecision(aID: aID, bID: bID, similarity: sim, reason: .exactLabel))
                if auditOutputDir != nil {
                    auditEntries.append(makeAuditEntry(a: a, b: b, sim: sim,
                                                       band: "exactLabel",
                                                       exactLabel: true,
                                                       llmVerdict: nil,
                                                       finalReason: MergeReason.exactLabel.rawValue))
                }
                continue
            }
            switch classify(similarity: sim, thresholds: thresholds) {
            case .autoMerge:
                autoMerges.append(MergeDecision(aID: aID, bID: bID, similarity: sim, reason: .highSimilarity))
                if auditOutputDir != nil {
                    auditEntries.append(makeAuditEntry(a: a, b: b, sim: sim,
                                                       band: "autoMerge",
                                                       exactLabel: false,
                                                       llmVerdict: nil,
                                                       finalReason: MergeReason.highSimilarity.rawValue))
                }
            case .adjudication:
                adjudicationCandidates.append(MergeCandidate(aID: aID, bID: bID, similarity: sim))
                // Audit entry written later once the LLM verdict is known.
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
                if auditOutputDir != nil {
                    for cand in adjudicationCandidates {
                        if let a = nodesByID[cand.aID], let b = nodesByID[cand.bID] {
                            auditEntries.append(makeAuditEntry(
                                a: a, b: b, sim: cand.similarity,
                                band: "adjudication",
                                exactLabel: false,
                                llmVerdict: nil,
                                finalReason: nil))
                        }
                    }
                    writeAudit(entries: auditEntries,
                               thresholds: thresholds,
                               eligibleCount: eligible.count,
                               pairCount: pairs.count,
                               modelIdentifier: embeddingBackend.modelIdentifier,
                               vectorDimension: embeddingBackend.vectorDimension,
                               projectID: projectID,
                               dir: auditOutputDir!)
                }
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
                let raw = try await generateWithRetry(llm: llm, prompt: prompt)
                let decisions = try PromptTemplates.parseMergeAdjudicationResponse(raw, expectedCount: pairsForPrompt.count)
                for (cand, merge) in zip(batch, decisions) {
                    if merge {
                        adjudicated.append(MergeDecision(aID: cand.aID, bID: cand.bID,
                                                         similarity: cand.similarity, reason: .llmAdjudicated))
                    }
                    if auditOutputDir != nil,
                       let a = nodesByID[cand.aID], let b = nodesByID[cand.bID] {
                        auditEntries.append(makeAuditEntry(
                            a: a, b: b, sim: cand.similarity,
                            band: "adjudication",
                            exactLabel: false,
                            llmVerdict: merge ? "approved" : "rejected",
                            finalReason: merge ? MergeReason.llmAdjudicated.rawValue : nil))
                    }
                }
                log.info("[ETR] adjudication batch [\(batchStart)..<\(batchStart + batch.count)]: \(decisions.filter { $0 }.count)/\(decisions.count) approved")
            }
        }

        let all = autoMerges + adjudicated
        log.info("[ETR] final merge plan: \(all.count) decisions (auto=\(autoMerges.count), adjudicated=\(adjudicated.count))")

        if let dir = auditOutputDir {
            writeAudit(entries: auditEntries,
                       thresholds: thresholds,
                       eligibleCount: eligible.count,
                       pairCount: pairs.count,
                       modelIdentifier: embeddingBackend.modelIdentifier,
                       vectorDimension: embeddingBackend.vectorDimension,
                       projectID: projectID,
                       dir: dir)
        }

        return MergePlan(decisions: all, thresholds: thresholds)
    }

    // MARK: - Audit helpers

    /// Internal for unit testability. Builds an audit row from two nodes.
    static func makeAuditEntry(a: ConceptNode, b: ConceptNode,
                               sim: Float, band: String,
                               exactLabel: Bool,
                               llmVerdict: String?,
                               finalReason: String?) -> ResolverAuditEntry {
        ResolverAuditEntry(
            aID: a.id.uuidString,
            aLabel: a.label,
            aDoc: a.sourceAnchors.first?.documentURL.lastPathComponent,
            aLevel: a.level.rawValue,
            bID: b.id.uuidString,
            bLabel: b.label,
            bDoc: b.sourceAnchors.first?.documentURL.lastPathComponent,
            bLevel: b.level.rawValue,
            similarity: sim,
            band: band,
            exactLabelMatch: exactLabel,
            llmVerdict: llmVerdict,
            finalReason: finalReason
        )
    }

    /// Writes `etr_audit_<projectID>_<ISO8601>.json` into `dir`. Failure
    /// logs but does not throw — audit logging is best-effort, never a
    /// reason to abort the resolve.
    static func writeAudit(entries: [ResolverAuditEntry],
                           thresholds: ResolverThresholds,
                           eligibleCount: Int,
                           pairCount: Int,
                           modelIdentifier: String,
                           vectorDimension: Int,
                           projectID: UUID,
                           dir: URL) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeStamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let audit = ResolverAudit(
            timestamp: timestamp,
            modelIdentifier: modelIdentifier,
            vectorDimension: vectorDimension,
            thresholds: .init(autoMerge: thresholds.autoMerge,
                              adjudicationFloor: thresholds.adjudicationFloor,
                              adjudicationBatchSize: thresholds.adjudicationBatchSize),
            eligibleNodeCount: eligibleCount,
            pairsEvaluated: pairCount,
            entries: entries
        )
        let url = dir.appendingPathComponent("etr_audit_\(projectID.uuidString)_\(safeStamp).json")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(audit)
            try data.write(to: url, options: .atomic)
            log.info("[ETR] audit written: \(entries.count) entries to \(url.lastPathComponent)")
        } catch {
            log.error("[ETR] audit write failed: \(error.localizedDescription) — continuing")
        }
    }

    /// Calls `llm.generateRawResponse(prompt:)` with retry-with-backoff for
    /// transient transport failures. Added after the 2026-05-16 vitacare
    /// sweep at `--adj-floor 0.70` lost a multi-minute run to a single
    /// "network connection was lost" mid-batch.
    ///
    /// Policy: 3 attempts total, exponential backoff (1s → 3s). Logical
    /// errors (`AIError.decodingError`, `AIError.invalidResponse`) bypass
    /// retry — those don't get better on retry. Everything else retries.
    /// `maxAttempts` is exposed for tests.
    static func generateWithRetry(
        llm: any AtlasModel,
        prompt: String,
        maxAttempts: Int = 3
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await llm.generateRawResponse(prompt: prompt)
            } catch let error as AIError {
                switch error {
                case .decodingError, .invalidResponse:
                    throw error  // logical; retry won't help
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
            if attempt < maxAttempts - 1 {
                let delaySeconds = pow(3.0, Double(attempt))  // 1s, 3s
                log.warning("[ETR] LLM call failed (attempt \(attempt + 1)/\(maxAttempts)): \(lastError?.localizedDescription ?? "?", privacy: .public) — retrying in \(delaySeconds)s")
                try? await Task.sleep(for: .seconds(delaySeconds))
            }
        }
        throw lastError ?? AIError.modelUnavailable("retry exhausted with no captured error")
    }
}
