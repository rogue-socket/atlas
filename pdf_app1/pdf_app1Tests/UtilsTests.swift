import XCTest
@testable import pdf_app1

/// Pure-value tests for small Utils helpers:
/// - `Debouncer` (trailing-edge schedule + flush)
/// - `String.sha256HexPrefix16` (content-derived file-name hashing)
/// - `String.asConceptType` / `String.asEdgeType` (lenient enum decoding)
final class UtilsTests: XCTestCase {

    // MARK: - Debouncer

    func test_debouncer_runsActionAfterDelay() {
        let debouncer = Debouncer(delay: 0.05)
        let exp = expectation(description: "action fires")
        debouncer.schedule { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func test_debouncer_cancelsPriorScheduleOnNewCall() {
        let debouncer = Debouncer(delay: 0.05)
        var firedCount = 0
        debouncer.schedule { firedCount += 1 }
        debouncer.schedule { firedCount += 1 }
        debouncer.schedule { firedCount += 1 }

        let exp = expectation(description: "last fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(firedCount, 1, "Only the last scheduled work item should fire")
    }

    func test_debouncer_flushRunsPendingSynchronouslyAndClears() {
        let debouncer = Debouncer(delay: 10)  // long delay so the async path won't fire
        var fired = false
        debouncer.schedule { fired = true }
        debouncer.flush()
        XCTAssertTrue(fired, "flush should run the pending work synchronously")

        // After flush, a second flush should be a no-op (no crash, nothing to run).
        debouncer.flush()
    }

    func test_debouncer_flushWithNothingPendingIsNoOp() {
        let debouncer = Debouncer(delay: 0.01)
        // No schedule call.
        debouncer.flush()  // must not crash
    }

    // MARK: - String+Hash

    func test_sha256HexPrefix16_isDeterministicAcrossCalls() {
        let s = "atlas://example/doc.pdf"
        XCTAssertEqual(s.sha256HexPrefix16, s.sha256HexPrefix16)
    }

    func test_sha256HexPrefix16_isThirtyTwoHexChars() {
        let s = "hello world"
        let hash = s.sha256HexPrefix16
        XCTAssertEqual(hash.count, 32)
        let hexSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(hash.unicodeScalars.allSatisfy { hexSet.contains($0) })
    }

    func test_sha256HexPrefix16_differsForDifferentInputs() {
        XCTAssertNotEqual("a".sha256HexPrefix16, "b".sha256HexPrefix16)
    }

    func test_sha256HexPrefix16_emptyStringHashesToKnownValue() {
        // SHA256("") = e3b0c44298fc1c14...; first 16 bytes (32 hex chars):
        XCTAssertEqual("".sha256HexPrefix16, "e3b0c44298fc1c149afbf4c8996fb924")
    }

    // MARK: - String+EnumDecoding (asConceptType / asEdgeType)

    func test_asConceptType_returnsCaseForValidRawValue() {
        XCTAssertEqual("definition".asConceptType(), .definition)
        XCTAssertEqual("theorem".asConceptType(), .theorem)
        XCTAssertEqual("person".asConceptType(), .person)
    }

    func test_asConceptType_returnsDefaultForUnknownValue() {
        XCTAssertEqual("hypothesis".asConceptType(), .concept)
        XCTAssertEqual("hypothesis".asConceptType(default: .definition), .definition)
    }

    func test_asConceptType_isCaseSensitive() {
        // ConceptType raw values are lowercase; mixed-case should fall back.
        XCTAssertEqual("Definition".asConceptType(default: .example), .example)
    }

    func test_asEdgeType_returnsCaseForValidRawValue() {
        XCTAssertEqual("dependsOn".asEdgeType(), .dependsOn)
        XCTAssertEqual("contradicts".asEdgeType(), .contradicts)
        XCTAssertEqual("containsEntity".asEdgeType(), .containsEntity)
    }

    func test_asEdgeType_returnsDefaultForUnknownValue() {
        XCTAssertEqual("madeUpEdge".asEdgeType(), .sameTopic)
        XCTAssertEqual("madeUpEdge".asEdgeType(default: .partOf), .partOf)
    }
}
