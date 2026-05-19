import XCTest
@testable import pdf_app1

/// Tests for `JSONRepair.cleanAndRepair` — the LLM-response cleanup path.
/// Goals:
///   - Strip markdown fences regardless of language tag.
///   - Round-trip well-formed JSON unchanged.
///   - Close trailing unbalanced quotes / braces / brackets.
///   - Aggressively recover concepts when the `edges` tail is truncated.
final class JSONRepairTests: XCTestCase {

    private func isValidJSON(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    // MARK: - Pass-through

    func test_passesThroughWellFormedObject() {
        let input = #"{"a":1,"b":"two"}"#
        XCTAssertEqual(JSONRepair.cleanAndRepair(input), input)
    }

    func test_passesThroughWellFormedArray() {
        let input = #"[1, 2, 3]"#
        XCTAssertEqual(JSONRepair.cleanAndRepair(input), input)
    }

    func test_trimsLeadingAndTrailingWhitespace() {
        let input = "\n\n  {\"a\":1}  \n"
        XCTAssertEqual(JSONRepair.cleanAndRepair(input), "{\"a\":1}")
    }

    func test_returnsEmptyForEmptyOrWhitespaceOnly() {
        XCTAssertEqual(JSONRepair.cleanAndRepair(""), "")
        XCTAssertEqual(JSONRepair.cleanAndRepair("   \n\n  "), "")
    }

    // MARK: - Markdown fence stripping

    func test_stripsTripleBacktickJSONFence() {
        let input = "```json\n{\"a\":1}\n```"
        let cleaned = JSONRepair.cleanAndRepair(input)
        XCTAssertEqual(cleaned, "{\"a\":1}")
    }

    func test_stripsBareTripleBacktickFence() {
        let input = "```\n{\"x\":[1,2]}\n```"
        let cleaned = JSONRepair.cleanAndRepair(input)
        XCTAssertEqual(cleaned, "{\"x\":[1,2]}")
    }

    func test_stripsLeadingFenceWhenTrailingFenceMissing() {
        // Truncated LLM output: opener present, closer cut off.
        let input = "```json\n{\"a\":1}"
        let cleaned = JSONRepair.cleanAndRepair(input)
        XCTAssertEqual(cleaned, "{\"a\":1}")
    }

    // MARK: - Bracket / brace closure

    func test_closesMissingClosingBrace() {
        let cleaned = JSONRepair.cleanAndRepair(#"{"a":1"#)
        XCTAssertTrue(isValidJSON(cleaned), "Expected repaired JSON to parse; got \(cleaned)")
    }

    func test_closesMissingClosingBracket() {
        let cleaned = JSONRepair.cleanAndRepair(#"{"items":[1,2,3"#)
        XCTAssertTrue(isValidJSON(cleaned), "Expected repaired JSON to parse; got \(cleaned)")
    }

    func test_dropsTrailingComma() {
        let cleaned = JSONRepair.cleanAndRepair(#"{"a":1,"#)
        XCTAssertTrue(isValidJSON(cleaned), "Expected repaired JSON to parse; got \(cleaned)")
    }

    func test_closesUnterminatedStringThenBraces() {
        // Open string "hello and missing closing brace
        let cleaned = JSONRepair.cleanAndRepair(#"{"msg":"hello"#)
        XCTAssertTrue(isValidJSON(cleaned), "Expected repaired JSON to parse; got \(cleaned)")
    }

    // MARK: - Concept-truncation recovery

    func test_recoversTruncatedEdgesSection_inConceptsObject() {
        let truncated = """
        {"concepts":[
          {"label":"A","type":"concept","summary":"s","textSpan":"q","confidence":0.9},
          {"label":"B","type":"concept","summary":"s","textSpan":"q","confidence":0.8}
        ], "edges":[
          {"sourceLabel":"A","targetLabel
        """
        let cleaned = JSONRepair.cleanAndRepair(truncated)
        XCTAssertTrue(isValidJSON(cleaned), "Expected truncated-edges payload to recover; got: \(cleaned)")

        let data = cleaned.data(using: .utf8)!
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let concepts = obj?["concepts"] as? [[String: Any]]
        XCTAssertNotNil(concepts)
        XCTAssertEqual(concepts?.count, 2, "Both concepts should be preserved by truncation-recovery")
    }
}
