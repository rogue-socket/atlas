import XCTest
@testable import pdf_app1

final class ExtractionModeTests: XCTestCase {

    // MARK: - Cycle 1: Enum cases and raw value round-trip

    func testFastModeRawValue() {
        XCTAssertEqual(ExtractionMode.fast.rawValue, "fast")
    }

    func testDeepModeRawValue() {
        XCTAssertEqual(ExtractionMode.deep.rawValue, "deep")
    }

    func testRoundTripFromRawValue() {
        XCTAssertEqual(ExtractionMode(rawValue: "fast"), .fast)
        XCTAssertEqual(ExtractionMode(rawValue: "deep"), .deep)
        XCTAssertNil(ExtractionMode(rawValue: "invalid"))
    }

    // MARK: - Cycle 2: Display properties and availability

    func testDisplayNames() {
        XCTAssertFalse(ExtractionMode.fast.displayName.isEmpty)
        XCTAssertFalse(ExtractionMode.deep.displayName.isEmpty)
        XCTAssertNotEqual(ExtractionMode.fast.displayName, ExtractionMode.deep.displayName)
    }

    func testDescriptions() {
        XCTAssertFalse(ExtractionMode.fast.description.isEmpty)
        XCTAssertFalse(ExtractionMode.deep.description.isEmpty)
        XCTAssertNotEqual(ExtractionMode.fast.description, ExtractionMode.deep.description)
    }

    func testFastModeIsAvailable() {
        XCTAssertTrue(ExtractionMode.fast.isAvailable)
    }

    func testDeepModeIsAvailable() {
        XCTAssertTrue(ExtractionMode.deep.isAvailable)
    }
}
