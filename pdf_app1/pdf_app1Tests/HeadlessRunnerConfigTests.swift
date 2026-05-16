import XCTest
@testable import pdf_app1

/// Tests for `HeadlessRunnerConfig.parse(...)` — CLI flag parsing for the
/// headless extract harness. Covers the new `--etr` family added in
/// 2026-05-16 (ETR step 1) alongside baseline coverage for project/mode.
final class HeadlessRunnerConfigTests: XCTestCase {

    // MARK: - Baseline

    func test_parse_absentHeadlessFlag_returnsNil() {
        XCTAssertNil(HeadlessRunnerConfig.parse(from: ["--project", "p"]))
    }

    func test_parse_missingProject_returnsNil() {
        XCTAssertNil(HeadlessRunnerConfig.parse(from: ["--headless-extract"]))
    }

    func test_parse_minimalValid_returnsConfigWithFastDefaultMode() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "vitacare"])
        XCTAssertEqual(c?.projectName, "vitacare")
        XCTAssertEqual(c?.mode, .fast)
    }

    func test_parse_modeDeep_returnsDeepMode() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p", "--mode", "deep"])
        XCTAssertEqual(c?.mode, .deep)
    }

    func test_parse_unknownMode_fallsBackToFast() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p", "--mode", "bogus"])
        XCTAssertEqual(c?.mode, .fast)
    }

    // MARK: - ETR flags

    func test_parse_etrAbsent_runETRIsFalse_thresholdsNil() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p"])
        XCTAssertEqual(c?.runETR, false)
        XCTAssertNil(c?.etrThresholds)
    }

    func test_parse_etrPresent_runETRIsTrue() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p", "--etr"])
        XCTAssertEqual(c?.runETR, true)
    }

    func test_parse_etrWithoutThresholdOverrides_thresholdsNil() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p", "--etr"])
        XCTAssertNil(c?.etrThresholds, "No override flags → caller uses .default in resolver")
    }

    func test_parse_autoMergeOverride_buildsThresholds() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p",
                                                  "--etr", "--auto-merge", "0.92"])
        XCTAssertEqual(c?.etrThresholds?.autoMerge, 0.92)
        // Other fields fall back to default
        XCTAssertEqual(c?.etrThresholds?.adjudicationFloor, ResolverThresholds.default.adjudicationFloor)
        XCTAssertEqual(c?.etrThresholds?.adjudicationBatchSize, ResolverThresholds.default.adjudicationBatchSize)
    }

    func test_parse_adjFloorOverride_buildsThresholds() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p",
                                                  "--etr", "--adj-floor", "0.80"])
        XCTAssertEqual(c?.etrThresholds?.adjudicationFloor, 0.80)
        XCTAssertEqual(c?.etrThresholds?.autoMerge, ResolverThresholds.default.autoMerge)
    }

    func test_parse_adjBatchOverride_buildsThresholds() {
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p",
                                                  "--etr", "--adj-batch", "25"])
        XCTAssertEqual(c?.etrThresholds?.adjudicationBatchSize, 25)
    }

    func test_parse_allOverrides_buildsFullyCustomThresholds() {
        let c = HeadlessRunnerConfig.parse(from: [
            "--headless-extract", "--project", "p", "--etr",
            "--auto-merge", "0.97",
            "--adj-floor", "0.83",
            "--adj-batch", "12"
        ])
        XCTAssertEqual(c?.etrThresholds, ResolverThresholds(autoMerge: 0.97,
                                                             adjudicationFloor: 0.83,
                                                             adjudicationBatchSize: 12))
    }

    func test_parse_invalidAutoMergeValue_silentlyIgnored() {
        // Float("not-a-number") = nil → falls back to default in struct build.
        // No threshold struct is built because no field is parsed.
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p",
                                                  "--etr", "--auto-merge", "not-a-number"])
        XCTAssertNil(c?.etrThresholds)
        XCTAssertEqual(c?.runETR, true)
    }

    func test_parse_thresholdOverridesWithoutETRFlag_stillBuildThresholds() {
        // --auto-merge alone (without --etr) still builds thresholds; runETR
        // stays false. The thresholds become a no-op but the parser doesn't
        // require coupling — keeps the flags independently testable.
        let c = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "p",
                                                  "--auto-merge", "0.92"])
        XCTAssertEqual(c?.runETR, false)
        XCTAssertEqual(c?.etrThresholds?.autoMerge, 0.92)
    }
}
