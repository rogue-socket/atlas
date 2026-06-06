import XCTest
@testable import pdf_app1

/// Tests for the per-pair-kind threshold split landed in
/// `EmbeddingResolver` on 2026-05-19 (backlog item (c)). Goals:
///   - `pairKind(a:b:)` buckets correctly for the three combos.
///   - `ResolverThresholds.autoMerge(for:)` and `.adjudicationFloor(for:)`
///     fall back to the flat field when the per-kind override is absent.
///   - The pair-kind-aware `classify` overload honors per-kind overrides.
///   - The flat `classify` overload ignores per-kind overrides (no change
///     in behavior for callers that haven't migrated).
final class EmbeddingResolverPerKindThresholdTests: XCTestCase {

    private func concept(_ label: String = "c") -> ConceptNode {
        ConceptNode(label: label, type: .concept, level: .concept)
    }

    private func entity(_ label: String = "e") -> ConceptNode {
        ConceptNode(label: label, type: .definition, level: .entity)
    }

    // MARK: - pairKind

    func test_pairKind_bothConcept_returnsConceptConcept() {
        XCTAssertEqual(EmbeddingResolver.pairKind(concept(), concept()), .conceptConcept)
    }

    func test_pairKind_bothEntity_returnsEntityEntity() {
        XCTAssertEqual(EmbeddingResolver.pairKind(entity(), entity()), .entityEntity)
    }

    func test_pairKind_mixedConceptAndEntity_returnsCrossLevel() {
        XCTAssertEqual(EmbeddingResolver.pairKind(concept(), entity()), .crossLevel)
        XCTAssertEqual(EmbeddingResolver.pairKind(entity(), concept()), .crossLevel)
    }

    // MARK: - ResolverThresholds accessor fallback

    func test_thresholds_perKindAccessor_fallsBackToFlatWhenAbsent() {
        let t = ResolverThresholds(autoMerge: 0.95,
                                   adjudicationFloor: 0.80,
                                   adjudicationBatchSize: 18)
        for kind in EmbeddingResolver.PairKind.allCases {
            XCTAssertEqual(t.autoMerge(for: kind), 0.95, accuracy: 1e-6)
            XCTAssertEqual(t.adjudicationFloor(for: kind), 0.80, accuracy: 1e-6)
        }
    }

    func test_thresholds_perKindAccessor_returnsOverrideWhenPresent() {
        var t = ResolverThresholds.default  // flat: autoMerge 0.95, floor 0.80
        t.autoMergePerKind = [.conceptConcept: 0.97]
        t.adjudicationFloorPerKind = [.entityEntity: 0.75]

        XCTAssertEqual(t.autoMerge(for: .conceptConcept), 0.97, accuracy: 1e-6)
        XCTAssertEqual(t.autoMerge(for: .entityEntity), 0.95, accuracy: 1e-6)
        XCTAssertEqual(t.autoMerge(for: .crossLevel), 0.95, accuracy: 1e-6)

        XCTAssertEqual(t.adjudicationFloor(for: .conceptConcept), 0.80, accuracy: 1e-6)
        XCTAssertEqual(t.adjudicationFloor(for: .entityEntity), 0.75, accuracy: 1e-6)
        XCTAssertEqual(t.adjudicationFloor(for: .crossLevel), 0.80, accuracy: 1e-6)
    }

    // MARK: - classify(similarity:pairKind:thresholds:)

    func test_classifyByPairKind_appliesConceptConceptOverride() {
        // concept↔concept stricter than the flat default so a 0.85 sim
        // lands as .reject for concept-concept but .adjudication for the
        // other two kinds.
        var t = ResolverThresholds.default  // floor 0.80, autoMerge 0.95
        t.adjudicationFloorPerKind = [.conceptConcept: 0.90]

        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.85, pairKind: .conceptConcept, thresholds: t),
            .reject
        )
        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.85, pairKind: .entityEntity, thresholds: t),
            .adjudication
        )
        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.85, pairKind: .crossLevel, thresholds: t),
            .adjudication
        )
    }

    func test_classifyByPairKind_appliesAutoMergeOverride() {
        // Looser auto-merge for entity↔entity (e.g. specific named things
        // tend to score very high when truly the same) — a 0.92 sim auto-
        // merges entity-entity but only enters adjudication for the others.
        var t = ResolverThresholds.default
        t.autoMergePerKind = [.entityEntity: 0.90]

        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.92, pairKind: .entityEntity, thresholds: t),
            .autoMerge
        )
        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.92, pairKind: .conceptConcept, thresholds: t),
            .adjudication
        )
        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.92, pairKind: .crossLevel, thresholds: t),
            .adjudication
        )
    }

    func test_classifyByPairKind_matchesFlatBehaviorWhenNoOverridesSet() {
        // With an empty per-kind dictionary the pair-kind classify must
        // match the flat classify for every kind.
        let t = ResolverThresholds.default
        for kind in EmbeddingResolver.PairKind.allCases {
            for sim: Float in [-0.1, 0.0, 0.5, 0.79, 0.80, 0.85, 0.95, 0.96, 1.0] {
                XCTAssertEqual(
                    EmbeddingResolver.classify(similarity: sim, pairKind: kind, thresholds: t),
                    EmbeddingResolver.classify(similarity: sim, thresholds: t),
                    "drift at sim=\(sim) kind=\(kind)"
                )
            }
        }
    }

    // MARK: - Flat classify ignores per-kind overrides (back-compat)

    func test_flatClassify_ignoresPerKindOverrides() {
        // Even with a draconian concept-concept floor, the flat classify
        // should still call 0.85 → adjudication (using the flat field 0.80).
        var t = ResolverThresholds.default
        t.adjudicationFloorPerKind = [.conceptConcept: 0.99,
                                      .entityEntity: 0.99,
                                      .crossLevel: 0.99]
        XCTAssertEqual(
            EmbeddingResolver.classify(similarity: 0.85, thresholds: t),
            .adjudication
        )
    }

    // MARK: - PairKind Codable round-trip (audit sidecar uses raw value)

    func test_pairKind_rawValuesAreStable() {
        XCTAssertEqual(EmbeddingResolver.PairKind.conceptConcept.rawValue, "conceptConcept")
        XCTAssertEqual(EmbeddingResolver.PairKind.entityEntity.rawValue, "entityEntity")
        XCTAssertEqual(EmbeddingResolver.PairKind.crossLevel.rawValue, "crossLevel")
    }

    func test_pairKind_codableRoundTrip() throws {
        for k in EmbeddingResolver.PairKind.allCases {
            let data = try JSONEncoder().encode(k)
            let decoded = try JSONDecoder().decode(EmbeddingResolver.PairKind.self, from: data)
            XCTAssertEqual(decoded, k)
        }
    }
}
