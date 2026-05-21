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

    /// Optional per-pair-kind override of `autoMerge`. nil entries fall
    /// back to the flat field above. Lets a tuning run set
    /// concept↔concept stricter than entity↔entity (concept labels share
    /// more topic words → more false-positive risk at the same cosine).
    /// Backlog item (c), 2026-05-16.
    var autoMergePerKind: [EmbeddingResolver.PairKind: Float] = [:]
    /// Optional per-pair-kind override of `adjudicationFloor`. nil entries
    /// fall back to the flat field above.
    var adjudicationFloorPerKind: [EmbeddingResolver.PairKind: Float] = [:]

    static let `default` = ResolverThresholds()

    func autoMerge(for kind: EmbeddingResolver.PairKind) -> Float {
        autoMergePerKind[kind] ?? autoMerge
    }

    func adjudicationFloor(for kind: EmbeddingResolver.PairKind) -> Float {
        adjudicationFloorPerKind[kind] ?? adjudicationFloor
    }
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

// MARK: - Hybrid adjudication (ETR backbone + SCE typed-relation taxonomy)

/// Verdict the hybrid adjudicator returns for one candidate pair: ETR's
/// merge/keep, extended with SCE's three typed-relation kinds. A `merge`
/// collapses the pair; a typed verdict keeps both nodes but records a
/// directed `GraphEdge`; `keep` does nothing.
enum AdjudicationVerdict: String, Codable, Sendable, Equatable {
    case merge
    case keep
    case instanceOf  = "instance_of"
    case attributeOf = "attribute_of"
    case processFor  = "process_for"

    /// EdgeType for the three typed verdicts; nil for `merge` / `keep`.
    var edgeType: EdgeType? {
        switch self {
        case .instanceOf:   return .instanceOf
        case .attributeOf:  return .attributeOf
        case .processFor:   return .processFor
        case .merge, .keep: return nil
        }
    }
}

/// Direction a typed relation runs for a candidate pair `(a, b)`:
/// `.ab` → edge a→b, `.ba` → edge b→a.
enum PairDirection: String, Codable, Sendable, Equatable {
    case ab
    case ba
}

/// One parsed adjudication answer for a candidate pair.
struct AdjudicationResult: Codable, Sendable, Equatable {
    let verdict: AdjudicationVerdict
    let direction: PairDirection
}

/// A typed cross-doc relationship the adjudicator found between two nodes it
/// declined to merge. Stage 4 materializes it as a directed `GraphEdge`.
struct RelationDecision: Sendable, Equatable {
    let sourceID: UUID
    let targetID: UUID
    let edgeType: EdgeType
    let similarity: Float
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
    /// Typed cross-doc relations from hybrid adjudication. Empty for runs
    /// with no LLM backend (adjudication band is dropped entirely).
    let relations: [RelationDecision]
    let thresholds: ResolverThresholds

    init(decisions: [MergeDecision],
         relations: [RelationDecision] = [],
         thresholds: ResolverThresholds) {
        self.decisions = decisions
        self.relations = relations
        self.thresholds = thresholds
    }
}

// MARK: - Audit trail (followup #3 from 2026-05-16 sweep)

/// One entry per "interesting" pair the resolver evaluated — every auto-
/// merge and every pair that reached the adjudication band. Rejects (sim
/// below floor) are skipped to keep the file small; if you need them, lower
/// the floor and re-run.
struct ResolverAuditEntry: Codable, Sendable {
    let aID: String
    let aLabel: String
    let aDocs: [String]    // every distinct source-doc filename, sorted; multi-element
                           // when the node has been merged across docs in a prior run
    let aLevel: String     // "concept" or "entity"
    let bID: String
    let bLabel: String
    let bDocs: [String]
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
        /// Per-pair-kind overrides surfaced in the audit so a reader can see
        /// which floor actually applied to a given pair. Empty when the run
        /// used flat thresholds only. Optional in JSON for back-compat with
        /// pre-2026-05-19 audit sidecars.
        let autoMergePerKind: [String: Float]?
        let adjudicationFloorPerKind: [String: Float]?
    }
}

// MARK: - Pair kind

extension EmbeddingResolver {
    /// Categorizes a candidate pair by the levels of its two nodes. Only
    /// `.concept` and `.entity` are ETR-eligible (see `isEligible`), so the
    /// possible combinations collapse to three buckets. Used to look up
    /// per-kind threshold overrides on `ResolverThresholds`.
    enum PairKind: String, Sendable, Hashable, CaseIterable, Codable {
        case conceptConcept   // both nodes at `.concept` level
        case entityEntity     // both nodes at `.entity` level
        case crossLevel       // one concept + one entity
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
    ///
    /// Edge case worth knowing: if `a` is single-doc `{X}` and `b` is multi-
    /// doc `{X, Y}` (e.g., previously merged across docs), the sets differ
    /// so this returns true — they enter adjudication even though both
    /// share doc X. The intent is that a previously-spanning canonical `b`
    /// should be reconsidered against single-doc siblings. Trace in
    /// `audits/2026-05-18_etr-in-doc-pair-trace.md`.
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

    /// Flat classify — used when callers don't have a `PairKind` handy
    /// (e.g. existing unit tests). Reads only `thresholds.autoMerge` and
    /// `thresholds.adjudicationFloor`; per-kind overrides are ignored.
    static func classify(similarity: Float,
                         thresholds: ResolverThresholds) -> ClassificationBand {
        if similarity >= thresholds.autoMerge { return .autoMerge }
        if similarity >= thresholds.adjudicationFloor { return .adjudication }
        return .reject
    }

    /// Pair-kind-aware classify. Looks up
    /// `thresholds.autoMerge(for: kind)` and `adjudicationFloor(for: kind)`,
    /// which fall back to the flat fields when no per-kind override is set.
    /// `resolve` calls this; tests prefer this form when they're exercising
    /// per-level split behavior.
    static func classify(similarity: Float,
                         pairKind kind: PairKind,
                         thresholds: ResolverThresholds) -> ClassificationBand {
        if similarity >= thresholds.autoMerge(for: kind) { return .autoMerge }
        if similarity >= thresholds.adjudicationFloor(for: kind) { return .adjudication }
        return .reject
    }

    /// Categorize a pair by the levels of its two nodes. Both `.concept` →
    /// `.conceptConcept`; both `.entity` → `.entityEntity`; one each →
    /// `.crossLevel`. Pairs containing a non-eligible node (`.document` or
    /// `.chapter`) should be excluded by the caller (`isEligible`); we still
    /// bucket them defensively into `.crossLevel` rather than crash.
    static func pairKind(_ a: ConceptNode, _ b: ConceptNode) -> PairKind {
        switch (a.level, b.level) {
        case (.concept, .concept): return .conceptConcept
        case (.entity,  .entity):  return .entityEntity
        default:                   return .crossLevel
        }
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

        // 2. Per-node resolve: cache hit (by contentHash) or queue for fresh embed.
        struct Pending { let node: ConceptNode; let hash: String }
        var resolved: [UUID: [Float]] = [:]
        var pending: [Pending] = []
        let liveHashes: Set<String> = Set(eligible.map { contentHash(for: $0) })
        for node in eligible {
            let h = contentHash(for: node)
            if let v = cache.vector(forHash: h) {
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
                cache.put(contentHash: p.hash, vector: v)
            }
        }

        // 3. Save cache with orphan cleanup (drops entries whose hash isn't
        //    in the live set — e.g. after a label edit or content rewrite).
        cache.retain(liveHashes)
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
            let kind = pairKind(a, b)
            switch classify(similarity: sim, pairKind: kind, thresholds: thresholds) {
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

        // 5. Hybrid LLM adjudication for the band — merge / keep / typed relation.
        var adjudicated: [MergeDecision] = []
        var relations: [RelationDecision] = []
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
                let prompt = PromptTemplates.mergeAdjudicationHybrid(pairs: pairsForPrompt)
                let raw = try await generateWithRetry(llm: llm, prompt: prompt)
                let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: pairsForPrompt.count)
                var mergeCount = 0, relationCount = 0
                for (cand, result) in zip(batch, results) {
                    switch result.verdict {
                    case .merge:
                        adjudicated.append(MergeDecision(aID: cand.aID, bID: cand.bID,
                                                         similarity: cand.similarity, reason: .llmAdjudicated))
                        mergeCount += 1
                    case .instanceOf, .attributeOf, .processFor:
                        if let edgeType = result.verdict.edgeType {
                            // direction.ab → edge a→b; .ba → edge b→a.
                            let (src, tgt) = result.direction == .ab
                                ? (cand.aID, cand.bID)
                                : (cand.bID, cand.aID)
                            relations.append(RelationDecision(sourceID: src, targetID: tgt,
                                                              edgeType: edgeType,
                                                              similarity: cand.similarity))
                            relationCount += 1
                        }
                    case .keep:
                        break
                    }
                    if auditOutputDir != nil,
                       let a = nodesByID[cand.aID], let b = nodesByID[cand.bID] {
                        auditEntries.append(makeAuditEntry(
                            a: a, b: b, sim: cand.similarity,
                            band: "adjudication",
                            exactLabel: false,
                            llmVerdict: result.verdict.rawValue,
                            finalReason: result.verdict == .merge ? MergeReason.llmAdjudicated.rawValue : nil))
                    }
                }
                log.info("[ETR] adjudication batch [\(batchStart)..<\(batchStart + batch.count)]: \(mergeCount) merge, \(relationCount) relation, \(batch.count - mergeCount - relationCount) keep")
            }
        }

        let all = autoMerges + adjudicated
        log.info("[ETR] final plan: \(all.count) merges (auto=\(autoMerges.count), adjudicated=\(adjudicated.count)), \(relations.count) typed relations")

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

        return MergePlan(decisions: all, relations: relations, thresholds: thresholds)
    }

    // MARK: - Audit helpers

    /// Internal for unit testability. Builds an audit row from two nodes.
    /// `aDocs`/`bDocs` capture every distinct source-doc filename (sorted),
    /// so a sidecar reader can see when a pair involves a previously-merged
    /// multi-doc node — see `isCrossDoc` docstring and
    /// `audits/2026-05-18_etr-in-doc-pair-trace.md`.
    static func makeAuditEntry(a: ConceptNode, b: ConceptNode,
                               sim: Float, band: String,
                               exactLabel: Bool,
                               llmVerdict: String?,
                               finalReason: String?) -> ResolverAuditEntry {
        let docNames: (ConceptNode) -> [String] = { node in
            Set(node.sourceAnchors.map { $0.documentURL.lastPathComponent }).sorted()
        }
        return ResolverAuditEntry(
            aID: a.id.uuidString,
            aLabel: a.label,
            aDocs: docNames(a),
            aLevel: a.level.rawValue,
            bID: b.id.uuidString,
            bLabel: b.label,
            bDocs: docNames(b),
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
            thresholds: .init(
                autoMerge: thresholds.autoMerge,
                adjudicationFloor: thresholds.adjudicationFloor,
                adjudicationBatchSize: thresholds.adjudicationBatchSize,
                autoMergePerKind: thresholds.autoMergePerKind.isEmpty
                    ? nil
                    : Dictionary(uniqueKeysWithValues: thresholds.autoMergePerKind.map { ($0.key.rawValue, $0.value) }),
                adjudicationFloorPerKind: thresholds.adjudicationFloorPerKind.isEmpty
                    ? nil
                    : Dictionary(uniqueKeysWithValues: thresholds.adjudicationFloorPerKind.map { ($0.key.rawValue, $0.value) })
            ),
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

// MARK: - Lexical resolution (embedding-free path)

extension EmbeddingResolver {

    private static let lexicalStopwords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "for", "to", "in", "on", "with",
        "by", "at", "is", "are", "be", "as", "from", "that", "this", "its",
        "their", "our", "via", "per",
    ]

    /// Significant tokens of a label: lowercased, split on non-alphanumerics,
    /// stopwords and tokens shorter than 3 characters dropped.
    static func lexicalTokens(_ label: String) -> Set<String> {
        let parts = label.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(parts.map(String.init).filter { $0.count >= 3 && !lexicalStopwords.contains($0) })
    }

    /// Embedding-free candidate generation: cross-doc pairs whose labels share
    /// significant tokens. Score is token Jaccard. A pair is kept when it
    /// shares `minShared`+ significant tokens; results are sorted by score
    /// descending and capped at `limit` — so the cap keeps the highest-overlap
    /// pairs and `minShared: 1` is a recall floor, not the real selector.
    /// Used when no embedding backend is available (the hybrid runs Claude-only).
    static func lexicalCandidatePairs(among nodes: [ConceptNode],
                                      minShared: Int = 1,
                                      limit: Int = 60) -> [MergeCandidate] {
        let toks = nodes.map { lexicalTokens($0.label) }
        var out: [MergeCandidate] = []
        for i in 0..<nodes.count {
            for j in (i + 1)..<nodes.count {
                guard isCrossDoc(nodes[i], nodes[j]) else { continue }
                let shared = toks[i].intersection(toks[j])
                guard shared.count >= minShared else { continue }
                let union = toks[i].union(toks[j])
                let jaccard = union.isEmpty ? 0 : Float(shared.count) / Float(union.count)
                let (a, b) = nodes[i].id.uuidString < nodes[j].id.uuidString
                    ? (nodes[i].id, nodes[j].id)
                    : (nodes[j].id, nodes[i].id)
                out.append(MergeCandidate(aID: a, bID: b, similarity: jaccard))
            }
        }
        return Array(out.sorted { $0.similarity > $1.similarity }.prefix(limit))
    }

    /// Embedding-free hybrid resolution. Generates candidate pairs lexically
    /// (shared significant tokens) instead of by embedding cosine, then runs
    /// the same hybrid adjudication — merge / typed-relation / keep — through
    /// `llmBackend`. Exact-label pairs auto-merge; everything else is
    /// adjudicated. For end-to-end runs with no embedding provider available.
    static func resolveLexical(
        graph: KnowledgeGraph,
        llmBackend: any AtlasModel,
        thresholds: ResolverThresholds = .default
    ) async throws -> MergePlan {
        let eligible = eligibleNodes(in: graph)
        log.info("[Lexical] eligible: \(eligible.count) nodes (concept+entity)")
        guard eligible.count >= 2 else { return MergePlan(decisions: [], thresholds: thresholds) }
        let nodesByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })

        var autoMerges: [MergeDecision] = []
        var candidates: [MergeCandidate] = []
        for cand in lexicalCandidatePairs(among: eligible) {
            guard let a = nodesByID[cand.aID], let b = nodesByID[cand.bID] else { continue }
            if isExactLabelMatch(a, b) {
                autoMerges.append(MergeDecision(aID: cand.aID, bID: cand.bID,
                                                similarity: cand.similarity, reason: .exactLabel))
            } else {
                candidates.append(cand)
            }
        }
        log.info("[Lexical] \(autoMerges.count) exact-label auto-merge, \(candidates.count) for adjudication")

        var adjudicated: [MergeDecision] = []
        var relations: [RelationDecision] = []
        let batchSize = max(1, thresholds.adjudicationBatchSize)
        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            let batch = Array(candidates[batchStart..<min(batchStart + batchSize, candidates.count)])
            let pairsForPrompt = batch.compactMap { c -> (a: ConceptNode, b: ConceptNode)? in
                guard let a = nodesByID[c.aID], let b = nodesByID[c.bID] else { return nil }
                return (a, b)
            }
            guard pairsForPrompt.count == batch.count else {
                log.error("[Lexical] batch shrink — node lookup failure; skipping batch")
                continue
            }
            let prompt = PromptTemplates.mergeAdjudicationHybrid(pairs: pairsForPrompt)
            let raw = try await generateWithRetry(llm: llmBackend, prompt: prompt)
            let results = try PromptTemplates.parseHybridAdjudicationResponse(raw, expectedCount: pairsForPrompt.count)
            var mergeCount = 0, relationCount = 0
            for (cand, result) in zip(batch, results) {
                switch result.verdict {
                case .merge:
                    adjudicated.append(MergeDecision(aID: cand.aID, bID: cand.bID,
                                                     similarity: cand.similarity, reason: .llmAdjudicated))
                    mergeCount += 1
                case .instanceOf, .attributeOf, .processFor:
                    if let edgeType = result.verdict.edgeType {
                        let (src, tgt) = result.direction == .ab
                            ? (cand.aID, cand.bID)
                            : (cand.bID, cand.aID)
                        relations.append(RelationDecision(sourceID: src, targetID: tgt,
                                                          edgeType: edgeType,
                                                          similarity: cand.similarity))
                        relationCount += 1
                    }
                case .keep:
                    break
                }
            }
            log.info("[Lexical] adjudication batch [\(batchStart)..<\(batchStart + batch.count)]: \(mergeCount) merge, \(relationCount) relation, \(batch.count - mergeCount - relationCount) keep")
        }

        let all = autoMerges + adjudicated
        log.info("[Lexical] final plan: \(all.count) merges (auto=\(autoMerges.count), adjudicated=\(adjudicated.count)), \(relations.count) typed relations")
        return MergePlan(decisions: all, relations: relations, thresholds: thresholds)
    }
}
