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
        let predictedDirection: PairDirection?
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
    let directionRequiredLabels: Int
    let directionMismatches: Int
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
        var predictions: [PairKey: Prediction] = [:]
        for entry in auditEntries {
            var verdict = entry.llmVerdict.flatMap(AdjudicationVerdict.init(rawValue:)) ?? .keep
            var direction = entry.llmDirection.flatMap(PairDirection.init(rawValue:))
            if verdict == .keep,
               let aLevel = NodeLevel(rawValue: entry.aLevel),
               let bLevel = NodeLevel(rawValue: entry.bLevel),
               let inferred = EmbeddingResolver.inferTypedRelationForKeepPair(
                aLabel: entry.aLabel,
                aLevel: aLevel,
                bLabel: entry.bLabel,
                bLevel: bLevel,
                similarity: entry.similarity
               ) {
                verdict = inferred.verdict
                direction = inferred.direction
            }
            if verdict.edgeType == nil {
                direction = nil
            }
            predictions[PairKey(entry.aLabel, entry.bLabel)] = Prediction(
                aLabel: entry.aLabel,
                bLabel: entry.bLabel,
                verdict: verdict,
                direction: direction
            )
        }

        var counts: [AdjudicationVerdict: HybridAdjudicationEvalResult.VerdictCounts] = [:]
        for verdict in AdjudicationVerdict.allCasesForEval {
            counts[verdict] = .init()
        }

        var matched = 0
        var exact = 0
        var directionRequired = 0
        var directionMismatches = 0
        var missing: [HybridAdjudicationEvalSet.Label] = []
        var mismatches: [HybridAdjudicationEvalResult.Mismatch] = []

        for label in evalSet.labels {
            counts[label.expectedVerdict, default: .init()].expected += 1
            if label.expectedDirection != nil {
                directionRequired += 1
            }
            guard let prediction = predictions[PairKey(label.aLabel, label.bLabel)] else {
                missing.append(label)
                continue
            }
            matched += 1
            counts[prediction.verdict, default: .init()].predicted += 1
            if prediction.matches(label: label) {
                exact += 1
                counts[prediction.verdict, default: .init()].correct += 1
            } else {
                if prediction.verdict == label.expectedVerdict,
                   label.expectedDirection != nil {
                    directionMismatches += 1
                }
                mismatches.append(.init(label: label,
                                        predicted: prediction.verdict,
                                        predictedDirection: prediction.direction(relativeTo: label)))
            }
        }

        return HybridAdjudicationEvalResult(
            totalLabels: evalSet.labels.count,
            matchedLabels: matched,
            exactMatches: exact,
            directionRequiredLabels: directionRequired,
            directionMismatches: directionMismatches,
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

    private struct Prediction {
        let aLabel: String
        let bLabel: String
        let verdict: AdjudicationVerdict
        let direction: PairDirection?

        func matches(label: HybridAdjudicationEvalSet.Label) -> Bool {
            guard verdict == label.expectedVerdict else { return false }
            guard let expectedDirection = label.expectedDirection else { return true }
            return direction(relativeTo: label) == expectedDirection
        }

        func direction(relativeTo label: HybridAdjudicationEvalSet.Label) -> PairDirection? {
            guard let direction else { return nil }

            let source: String
            let target: String
            switch direction {
            case .ab:
                source = Self.normalized(aLabel)
                target = Self.normalized(bLabel)
            case .ba:
                source = Self.normalized(bLabel)
                target = Self.normalized(aLabel)
            }

            let labelA = Self.normalized(label.aLabel)
            let labelB = Self.normalized(label.bLabel)
            if source == labelA && target == labelB { return .ab }
            if source == labelB && target == labelA { return .ba }
            return nil
        }

        private static func normalized(_ label: String) -> String {
            label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

enum HybridAdjudicationEvalScorer {
    private static let log = AtlasLogger.headless

    private struct EvalSummary: Encodable {
        let evalId: String
        let corpus: String
        let auditPath: String
        let modelIdentifier: String
        let vectorDimension: Int
        let totalLabels: Int
        let matchedLabels: Int
        let exactMatches: Int
        let directionRequiredLabels: Int
        let directionMismatches: Int
        let missingLabels: Int
        let accuracy: Double
        let verdicts: [String: VerdictSummary]

        struct VerdictSummary: Encodable {
            let expected: Int
            let predicted: Int
            let correct: Int
            let precision: String
            let recall: String
        }
    }

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
            print("HYBRID_EVAL_ERROR could not load scorer inputs: \(error.localizedDescription)")
            exit(4)
        }

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: audit.entries)
        let accuracy = format(result.accuracy)
        log.info("[HybridEval] eval=\(evalSet.id, privacy: .public) corpus=\(evalSet.corpus, privacy: .public)")
        log.info("[HybridEval] audit model=\(audit.modelIdentifier, privacy: .public) dim=\(audit.vectorDimension) entries=\(audit.entries.count)")
        log.info("[HybridEval] total=\(result.totalLabels) matched=\(result.matchedLabels) exact=\(result.exactMatches) missing=\(result.missingLabels.count) directionRequired=\(result.directionRequiredLabels) directionMismatches=\(result.directionMismatches) accuracy=\(accuracy, privacy: .public)")

        for verdict in AdjudicationVerdict.allCasesForEval {
            let counts = result.countsByVerdict[verdict] ?? .init()
            let precision = counts.precision.map(format) ?? "n/a"
            let recall = counts.recall.map(format) ?? "n/a"
            log.info("[HybridEval] \(verdict.rawValue, privacy: .public): expected=\(counts.expected) predicted=\(counts.predicted) correct=\(counts.correct) precision=\(precision, privacy: .public) recall=\(recall, privacy: .public)")
        }

        for mismatch in result.mismatches.prefix(10) {
            let expectedDirection = mismatch.label.expectedDirection?.rawValue ?? "n/a"
            let predictedDirection = mismatch.predictedDirection?.rawValue ?? "n/a"
            log.info("[HybridEval] mismatch: \(mismatch.label.aLabel, privacy: .public) <> \(mismatch.label.bLabel, privacy: .public) expected=\(mismatch.label.expectedVerdict.rawValue, privacy: .public)/\(expectedDirection, privacy: .public) predicted=\(mismatch.predicted.rawValue, privacy: .public)/\(predictedDirection, privacy: .public)")
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

        let summary = EvalSummary(
            evalId: evalSet.id,
            corpus: evalSet.corpus,
            auditPath: auditPath,
            modelIdentifier: audit.modelIdentifier,
            vectorDimension: audit.vectorDimension,
            totalLabels: result.totalLabels,
            matchedLabels: result.matchedLabels,
            exactMatches: result.exactMatches,
            directionRequiredLabels: result.directionRequiredLabels,
            directionMismatches: result.directionMismatches,
            missingLabels: result.missingLabels.count,
            accuracy: result.accuracy,
            verdicts: Dictionary(
                uniqueKeysWithValues: AdjudicationVerdict.allCasesForEval.map { verdict in
                    let counts = result.countsByVerdict[verdict] ?? .init()
                    return (
                        verdict.rawValue,
                        EvalSummary.VerdictSummary(
                            expected: counts.expected,
                            predicted: counts.predicted,
                            correct: counts.correct,
                            precision: format(counts.precision ?? 0),
                            recall: format(counts.recall ?? 0)
                        )
                    )
                }
            )
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let summaryData = try encoder.encode(summary)
            if let summaryString = String(data: summaryData, encoding: .utf8) {
                print("HYBRID_EVAL_SUMMARY \(summaryString)")
            } else {
                print("HYBRID_EVAL_SUMMARY_ERROR cannot encode summary as UTF-8")
                exit(4)
            }
        } catch {
            print("HYBRID_EVAL_SUMMARY_ERROR cannot encode: \(error.localizedDescription)")
            exit(4)
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
