import XCTest
@testable import pdf_app1

/// Tests for `HeadlessRunnerConfig.parse(from:)` — argv parsing for the
/// `--headless-extract --project <name> [--mode fast|deep]` flag chain.
final class HeadlessRunnerConfigTests: XCTestCase {

    func test_parse_returnsNilWhenHeadlessFlagAbsent() {
        XCTAssertNil(HeadlessRunnerConfig.parse(from: ["--project", "P"]))
    }

    func test_parse_returnsNilWhenProjectNameMissing() {
        XCTAssertNil(HeadlessRunnerConfig.parse(from: ["--headless-extract", "--mode", "deep"]))
    }

    func test_parse_defaultsToFastMode() {
        let cfg = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "DemoProject"])
        XCTAssertEqual(cfg?.projectName, "DemoProject")
        XCTAssertEqual(cfg?.mode, .fast)
    }

    func test_parse_acceptsExplicitDeepMode() {
        let cfg = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "Demo", "--mode", "deep"])
        XCTAssertEqual(cfg?.projectName, "Demo")
        XCTAssertEqual(cfg?.mode, .deep)
    }

    func test_parse_unknownModeFallsBackToFast() {
        let cfg = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project", "P", "--mode", "ludicrous"])
        XCTAssertEqual(cfg?.mode, .fast)
    }

    func test_parse_ignoresUnknownFlagsAndOrderingDoesNotMatter() {
        let cfg = HeadlessRunnerConfig.parse(from: [
            "/usr/local/bin/pdf_app1", "--unrelated", "value",
            "--mode", "deep",
            "--headless-extract",
            "--project", "Atlas"
        ])
        XCTAssertEqual(cfg?.projectName, "Atlas")
        XCTAssertEqual(cfg?.mode, .deep)
    }

    func test_parse_projectFlagWithoutValue_failsCleanly() {
        // `--project` at the end of argv with no following value: parser
        // should treat it as absent (no crash, no spurious config).
        let cfg = HeadlessRunnerConfig.parse(from: ["--headless-extract", "--project"])
        XCTAssertNil(cfg)
    }

    func test_parse_acceptsDocOrderReverse() {
        let cfg = HeadlessRunnerConfig.parse(from: [
            "--headless-extract", "--project", "P", "--doc-order", "reverse"
        ])
        XCTAssertEqual(cfg?.docOrder, "reverse")
    }

    func test_orderedFiles_reverseFlipsAlphaOrder() {
        let files = [
            ProjectFile(displayName: "b.pdf", bookmarkData: Data(), lastKnownPath: "/b.pdf"),
            ProjectFile(displayName: "a.pdf", bookmarkData: Data(), lastKnownPath: "/a.pdf"),
            ProjectFile(displayName: "c.pdf", bookmarkData: Data(), lastKnownPath: "/c.pdf"),
        ]
        let project = Project(name: "P", files: files)
        let cfg = HeadlessRunnerConfig(projectName: "P", mode: .fast, docOrder: "reverse")
        XCTAssertEqual(cfg.orderedFiles(from: project).map(\.displayName), ["c.pdf", "b.pdf", "a.pdf"])
    }

    func test_orderedFiles_customListPreserved() {
        let files = [
            ProjectFile(displayName: "a.pdf", bookmarkData: Data(), lastKnownPath: "/a.pdf"),
            ProjectFile(displayName: "b.pdf", bookmarkData: Data(), lastKnownPath: "/b.pdf"),
            ProjectFile(displayName: "c.pdf", bookmarkData: Data(), lastKnownPath: "/c.pdf"),
        ]
        let project = Project(name: "P", files: files)
        let cfg = HeadlessRunnerConfig(projectName: "P", mode: .fast, docOrder: "c.pdf,a.pdf")
        XCTAssertEqual(cfg.orderedFiles(from: project).map(\.displayName), ["c.pdf", "a.pdf", "b.pdf"])
    }
}
