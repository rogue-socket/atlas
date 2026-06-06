import CryptoKit
import XCTest
@testable import pdf_app1

final class HybridAdjudicationEvalTests: XCTestCase {

    func test_evalSet_decodesSeedFixture() throws {
        let url = evalFixtureURL("docs/evals/pp1-hybrid-adjudication-labels.json")
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

    func test_evalSet_decodesVitacareHoldoutFixture() throws {
        let url = evalFixtureURL("docs/evals/vitacare-hybrid-adjudication-labels.json")
        let data = try Data(contentsOf: url)

        let evalSet = try JSONDecoder().decode(HybridAdjudicationEvalSet.self, from: data)

        XCTAssertEqual(evalSet.id, "vitacare-hybrid-adjudication-v1")
        XCTAssertGreaterThanOrEqual(evalSet.labels.count, 10)
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

    func test_score_mapsHighOverlapEntityKeepToInstanceOf() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "Repair and event workshops", bLabel: "Repair workshops",
                      expectedVerdict: .instanceOf, expectedDirection: .ba, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "Repair and event workshops", b: "Repair workshops", verdict: "keep")
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.totalLabels, 1)
        XCTAssertEqual(result.matchedLabels, 1)
        XCTAssertEqual(result.exactMatches, 1)
        XCTAssertEqual(result.mismatches.count, 0)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.predicted, 1)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.correct, 1)
        XCTAssertEqual(result.countsByVerdict[.keep]?.predicted, 0)
    }

    func test_score_checksExpectedDirectionWhenProvided() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "Kitchen revenue share", bLabel: "Revenue share",
                      expectedVerdict: .instanceOf, expectedDirection: .ab, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "Kitchen revenue share", b: "Revenue share",
                  verdict: "instance_of", direction: "ba")
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.totalLabels, 1)
        XCTAssertEqual(result.matchedLabels, 1)
        XCTAssertEqual(result.exactMatches, 0)
        XCTAssertEqual(result.directionRequiredLabels, 1)
        XCTAssertEqual(result.directionMismatches, 1)
        XCTAssertEqual(result.mismatches.first?.predicted, .instanceOf)
        XCTAssertEqual(result.mismatches.first?.predictedDirection, .ba)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.predicted, 1)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.correct, 0)
    }

    func test_score_normalizesDirectionFromAuditPairOrder() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "Kitchen revenue share", bLabel: "Revenue share",
                      expectedVerdict: .instanceOf, expectedDirection: .ab, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "Revenue share", b: "Kitchen revenue share",
                  verdict: "instance_of", direction: "ba")
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.totalLabels, 1)
        XCTAssertEqual(result.matchedLabels, 1)
        XCTAssertEqual(result.exactMatches, 1)
        XCTAssertEqual(result.directionRequiredLabels, 1)
        XCTAssertEqual(result.directionMismatches, 0)
        XCTAssertEqual(result.mismatches.count, 0)
        XCTAssertEqual(result.countsByVerdict[.instanceOf]?.correct, 1)
    }

    func test_score_countsMissingDirectionAsMismatchWhenExpected() {
        let evalSet = HybridAdjudicationEvalSet(
            id: "test",
            corpus: "unit",
            labels: [
                .init(aLabel: "Kitchen revenue share", bLabel: "Revenue share",
                      expectedVerdict: .instanceOf, expectedDirection: .ab, rationale: nil)
            ]
        )
        let entries = [
            audit(a: "Kitchen revenue share", b: "Revenue share",
                  verdict: "instance_of", direction: nil)
        ]

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: entries)

        XCTAssertEqual(result.exactMatches, 0)
        XCTAssertEqual(result.directionRequiredLabels, 1)
        XCTAssertEqual(result.directionMismatches, 1)
        XCTAssertEqual(result.mismatches.first?.predicted, .instanceOf)
        XCTAssertNil(result.mismatches.first?.predictedDirection)
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

    func test_score_pp1CanonicalAudit_matchesFixtureBaseline() throws {
        let evalURL = evalFixtureURL("docs/evals/pp1-hybrid-adjudication-labels.json")
        let auditURL = evalFixtureURL("docs/evals/reference-audits/pp1-hybrid-adjudication-audit-canonical.json")

        let evalSet = try JSONDecoder().decode(HybridAdjudicationEvalSet.self, from: Data(contentsOf: evalURL))
        let audit = try JSONDecoder().decode(ResolverAudit.self, from: Data(contentsOf: auditURL))

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: audit.entries)

        XCTAssertEqual(result.totalLabels, 12)
        XCTAssertEqual(result.matchedLabels, 12)
        XCTAssertEqual(result.exactMatches, 12)
        XCTAssertEqual(result.directionRequiredLabels, 5)
        XCTAssertEqual(result.directionMismatches, 0)
        XCTAssertEqual(result.missingLabels.count, 0)
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-6)
        XCTAssertEqual(result.mismatches.count, 0)
    }

    func test_score_vitacareCanonicalAudit_matchesFixtureBaseline() throws {
        let evalURL = evalFixtureURL("docs/evals/vitacare-hybrid-adjudication-labels.json")
        let auditURL = evalFixtureURL("docs/evals/reference-audits/vitacare-hybrid-adjudication-audit-canonical.json")

        let evalSet = try JSONDecoder().decode(HybridAdjudicationEvalSet.self, from: Data(contentsOf: evalURL))
        let audit = try JSONDecoder().decode(ResolverAudit.self, from: Data(contentsOf: auditURL))

        let result = HybridAdjudicationEvaluator.score(evalSet: evalSet, auditEntries: audit.entries)

        XCTAssertEqual(result.totalLabels, 21)
        XCTAssertEqual(result.matchedLabels, 21)
        XCTAssertEqual(result.exactMatches, 21)
        XCTAssertEqual(result.directionRequiredLabels, 10)
        XCTAssertEqual(result.directionMismatches, 0)
        XCTAssertEqual(result.missingLabels.count, 0)
        XCTAssertEqual(result.accuracy, 1.0, accuracy: 1e-6)
    }

    private func evalFixtureURL(_ relativePath: String) -> URL {
        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerURLs = [
            home.appendingPathComponent("tmp/hybrid-eval-fixtures"),
            home.appendingPathComponent("Library/Containers/rogues.pdf-app1/Data/tmp/hybrid-eval-fixtures")
        ]
        for containerURL in containerURLs {
            guard let manifest = stagedManifest(at: containerURL),
                  let expectedSHA = manifest.sources.first(where: { $0.fileName == fileName })?.sha256 else {
                continue
            }

            let stagedURL = containerURL.appendingPathComponent(fileName)
            if stagedFixture(stagedURL, matchesSHA256: expectedSHA) {
                return stagedURL
            }

            let stagedReferenceURL = containerURL
                .appendingPathComponent("reference-audits")
                .appendingPathComponent(fileName)
            if stagedFixture(stagedReferenceURL, matchesSHA256: expectedSHA) {
                return stagedReferenceURL
            }
        }

        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private struct StagedManifest: Decodable {
        struct Source: Decodable {
            let fileName: String
            let sha256: String
        }

        let sources: [Source]
    }

    private func stagedManifest(at containerURL: URL) -> StagedManifest? {
        let manifestURL = containerURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(StagedManifest.self, from: data)
    }

    private func stagedFixture(_ url: URL, matchesSHA256 expectedSHA: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest == expectedSHA
    }

    private func audit(a: String, b: String, verdict: String?, direction: String? = nil) -> ResolverAuditEntry {
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
            llmDirection: direction,
            finalReason: nil
        )
    }
}
