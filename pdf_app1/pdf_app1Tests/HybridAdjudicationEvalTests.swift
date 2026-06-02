import XCTest
@testable import pdf_app1

final class HybridAdjudicationEvalTests: XCTestCase {

    func test_evalSet_decodesSeedFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/pp1-hybrid-adjudication-labels.json")
        let data = try Data(contentsOf: url)

        let evalSet = try JSONDecoder().decode(HybridAdjudicationEvalSet.self, from: data)

        XCTAssertEqual(evalSet.id, "pp1-hybrid-adjudication-v1")
        XCTAssertGreaterThanOrEqual(evalSet.labels.count, 12)
        XCTAssertTrue(evalSet.labels.contains {
            $0.aLabel == "Revenue share"
                && $0.bLabel == "E-commerce revenue share"
                && $0.expectedVerdict == .merge
        })
    }

    func test_score_matchesPairsByUnorderedLabels() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "Revenue share", bLabel: "E-commerce revenue share",
                      expectedVerdict: .merge, expectedDirection: nil, rationale: nil),
                .init(aLabel: "Furniture assortment", bLabel: "FSC wood sourcing",
                      expectedVerdict: .keep, expectedDirection: nil, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "E-commerce revenue share", b: "Revenue share", verdict: "merge"),
            audit(a: "Furniture assortment", b: "FSC wood sourcing", verdict: "keep")
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.totalLabels, 2)
        XCTAssertEqual(result.matchedLabels, 2)
        XCTAssertEqual(result.exactMatches, 2)
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-6)
        XCTAssertEqual(result.countsByVerdict[.merge]?.precision, 1.0)
        XCTAssertEqual(result.countsByVerdict[.keep]?.recall, 1.0)
    }

    func test_score_reportsMissingAndWrongTypedVerdicts() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "A", bLabel: "B",
                      expectedVerdict: .instanceOf, expectedDirection: nil, rationale: nil),
                .init(aLabel: "C", bLabel: "D",
                      expectedVerdict: .attributeOf, expectedDirection: nil, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "A", b: "B", verdict: "keep")
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.totalLabels, 2)
        XCTAssertEqual(result.matchedLabels, 1)
        XCTAssertEqual(result.exactMatches, 0)
        XCTAssertEqual(result.missingLabels.map(\.aLabel), ["C"])
        XCTAssertEqual(result.mismatches.first?.label.aLabel, "A")
        XCTAssertEqual(result.mismatches.first?.predicted, .keep)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.expected, 1)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.correct, 0)
        XCTAssertEqual(result.countsByVerdict[.keep]?.predicted, 1)
    }

    private func audit(a: String, b: String, verdict: String?) -> ResolverAuditEntry {
        ResolverAuditEntry(
            aID: UUID().uuidString,
            aLabel: a,
            aDocs: ["a.pdf"],
            aLevel: "entity",
            bID: UUID().uuidString,
            bLabel: b,
            bDocs: ["b.pdf"],
            bLevel: "entity",
            similarity: 0.8,
            band: "adjudication",
            exactLabelMatch: false,
            llmVerdict: verdict,
            finalReason: nil
        )
    }
}
