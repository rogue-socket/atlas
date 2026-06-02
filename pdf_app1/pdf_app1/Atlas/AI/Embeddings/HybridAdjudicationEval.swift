//
//  HybridAdjudicationEval.swift
//  Atlas
//
//  Small scoring helpers for Hybrid adjudication audit sidecars.
//

import Foundation
import os.log

struct HybridAdjudicationEvalSet: Decodable, Sendable {
    let id: String
    let corpus: String
    let labels: [Label]

    struct Label: Decodable, Equatable, Sendable {
        let aLabel: String
        let bLabel: String
        let expectedVerdict: AdjudicationVerdict
        let expectedDirection: PairDirection?
        let rationale: String?
    }
}

struct HybridAdjudicationEvalResult: Sendable {
    struct Mismatch: Equatable, Sendable {
        let label: HybridAdjudicationEvalSet.Label
        let predicted: AdjudicationVerdict
    }

    struct VerdictCounts: Equatable, Sendable {
        var expected: Int = 0
        var predicted: Int = 0
        var correct: Int = 0

        var precision: Double? {
            predicted == 0 ? nil : Double(correct) / Double(predicted)
        }

        var recall: Double? {
            expected == 0 ? nil : Double(correct) / Double(expected)
        }
    }

    let totalLabels: Int
    let matchedLabels: Int
    let exactMatches: Int
    let missingLabels: [HybridAdjudicationEvalSet.Label]
    let mismatches: [Mismatch]
    let countsByVerdict: [AdjudicationVerdict: VerdictCounts]

    var accuracy: Double {
        totalLabels == 0 ? 0 : Double(exactMatches) / Double(totalLabels)
    }
}

enum HybridAdjudicationEvaluator {
    static func score(evalSet: HybridAdjudicationEvalSet,
                      auditEntries: [ResolverAuditEntry]) -> HybridAdjudicationEvalResult {
        var predictions: [PairKey: AdjudicationVerdict] = [:]
        for entry in auditEntries {
            let verdict = entry.llmVerdict.flatMap(AdjudicationVerdict.init(rawValue:)) ?? .keep
            predictions[PairKey(entry.aLabel, entry.bLabel)] = verdict
        }

        var counts: [AdjudicationVerdict: HybridAdjudicationEvalResult.VerdictCounts] = [:]
        for verdict in AdjudicationVerdict.allCasesForEval {
            counts[verdict] = .init()
        }

        var matched = 0
        var exact = 0
        var missing: [HybridAdjudicationEvalSet.Label] = []
        var mismatches: [HybridAdjudicationEvalResult.Mismatch] = []

        for label in evalSet.labels {
            counts[label.expectedVerdict, default: .init()].expected += 1
            guard let predicted = predictions[PairKey(label.aLabel, label.bLabel)] else {
                missing.append(label)
                continue
            }
            matched += 1
            counts[predicted, default: .init()].predicted += 1
            if predicted == label.expectedVerdict {
                exact += 1
                counts[predicted, default: .init()].correct += 1
            } else {
                mismatches.append(.init(label: label, predicted: predicted))
            }
        }

        return HybridAdjudicationEvalResult(
            totalLabels: evalSet.labels.count,
            matchedLabels: matched,
            exactMatches: exact,
            missingLabels: missing,
            mismatches: mismatches,
            countsByVerdict: counts
        )
    }

    private struct PairKey: Hashable {
        let first: String
        let second: String

        init(_ a: String, _ b: String) {
            let normalizedA = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedB = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalizedA <= normalizedB {
                first = normalizedA
                second = normalizedB
            } else {
                first = normalizedB
                second = normalizedA
            }
        }
    }
}

enum HybridAdjudicationEvalScorer {
    private static let log = AtlasLogger.headless

    static func run(auditPath: String, evalPath: String?) {
        guard let evalPath else {
            log.error("[HybridEval] --score-hybrid-adjudication requires --eval <labels.json>")
            exit(4)
        }

        let auditURL = URL(fileURLWithPath: auditPath)
        let evalURL = URL(fileURLWithPath: evalPath)
        let decoder = JSONDecoder()

        let audit: ResolverAudit
        let evalSet: HybridAdjudicationEvalSet
        do {
            let auditData = try Data(contentsOf: auditURL)
            audit = try decoder.decode(ResolverAudit.self, from: auditData)
            let evalData = try Data(contentsOf: evalURL)
            evalSet = try decoder.decode(HybridAdjudicationEvalSet.self, from: evalData)
        } catch {
            log.error("[HybridEval] could not load scorer inputs: \(error.localizedDescription, privacy: .public)")
            exit(4)
        }

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: audit.entries)
        let accuracy = format(result.accuracy)
        log.info("[HybridEval] eval=\(evalSet.id, privacy: .public) corpus=\(evalSet.corpus, privacy: .public)")
        log.info("[HybridEval] audit model=\(audit.modelIdentifier, privacy: .public) dim=\(audit.vectorDimension) entries=\(audit.entries.count)")
        log.info("[HybridEval] total=\(result.totalLabels) matched=\(result.matchedLabels) exact=\(result.exactMatches) missing=\(result.missingLabels.count) accuracy=\(accuracy, privacy: .public)")

        for verdict in AdjudicationVerdict.allCasesForEval {
            let counts = result.countsByVerdict[verdict] ?? .init()
            let precision = counts.precision.map(format) ?? "n/a"
            let recall = counts.recall.map(format) ?? "n/a"
            log.info("[HybridEval] \(verdict.rawValue, privacy: .public): expected=\(counts.expected) predicted=\(counts.predicted) correct=\(counts.correct) precision=\(precision, privacy: .public) recall=\(recall, privacy: .public)")
        }

        for mismatch in result.mismatches.prefix(10) {
            log.info("[HybridEval] mismatch: \(mismatch.label.aLabel, privacy: .public) <> \(mismatch.label.bLabel, privacy: .public) expected=\(mismatch.label.expectedVerdict.rawValue, privacy: .public) predicted=\(mismatch.predicted.rawValue, privacy: .public)")
        }
        if result.mismatches.count > 10 {
            log.info("[HybridEval] mismatch: plus \(result.mismatches.count - 10) more")
        }

        for label in result.missingLabels.prefix(10) {
            log.info("[HybridEval] missing: \(label.aLabel, privacy: .public) <> \(label.bLabel, privacy: .public) expected=\(label.expectedVerdict.rawValue, privacy: .public)")
        }
        if result.missingLabels.count > 10 {
            log.info("[HybridEval] missing: plus \(result.missingLabels.count - 10) more")
        }
        exit(0)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

private extension AdjudicationVerdict {
    static let allCasesForEval: [AdjudicationVerdict] = [
        .merge,
        .instanceOf,
        .attributeOf,
        .processFor,
        .keep
    ]
}
