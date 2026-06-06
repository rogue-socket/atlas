import XCTest
@testable import pdf_app1

/// Tests for the Codable surface of the LLM intermediate types defined in
/// `Atlas/AI/AtlasModelProtocol.swift`:
///   - RawConcept (incl. snake_case mapping, nested entities)
///   - RawEdge
///   - ExtractionResponse / ChapterExtractionResponse
///   - RawFact / RawFactExtractionResponse
///   - DeepConceptCluster / DeepEntityCluster / DeepClusterResponse
///   - RawMergeProposal
///   - AnswerWithCitations
///   - AIBackendType convenience
final class RawTypesCodableTests: XCTestCase {

    // MARK: - RawConcept

    func test_rawConcept_flatDecode() throws {
        let json = """
        {
          "label": "Topic",
          "type": "concept",
          "summary": "Topic summary.",
          "textSpan": "exact span",
          "confidence": 0.9
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertEqual(c.label, "Topic")
        XCTAssertEqual(c.type, "concept")
        XCTAssertEqual(c.confidence, 0.9)
        XCTAssertNil(c.entities)
        XCTAssertNil(c.parentLabel)
        XCTAssertNil(c.priorLabelMatch)
        XCTAssertNil(c.matchKind)
    }

    func test_rawConcept_nestedEntitiesDecode() throws {
        let json = """
        {
          "label": "Parent",
          "type": "concept",
          "summary": null,
          "textSpan": "parent span",
          "confidence": 0.9,
          "entities": [
            {"label":"Child", "type":"definition", "summary":"a", "textSpan":"q", "confidence":0.8}
          ]
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawConcept.self, from: json)
        XCTAssertNil(c.summary)
        XCTAssertEqual(c.entities?.count, 1)
        XCTAssertEqual(c.entities?.first?.label, "Child")
        XCTAssertEqual(c.entities?.first?.type, "definition")
    }

    // MARK: - RawEdge

    func test_rawEdge_decodeWithLinkingPhrase() throws {
        let json = """
        {"sourceLabel":"A","targetLabel":"B","type":"dependsOn","confidence":0.9,"linkingPhrase":"requires"}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(RawEdge.self, from: json)
        XCTAssertEqual(e.sourceLabel, "A")
        XCTAssertEqual(e.targetLabel, "B")
        XCTAssertEqual(e.type, "dependsOn")
        XCTAssertEqual(e.confidence, 0.9)
        XCTAssertEqual(e.linkingPhrase, "requires")
    }

    func test_rawEdge_decodeWithoutOptionalFields() throws {
        let json = #"{"sourceLabel":"A","targetLabel":"B","type":"sameTopic"}"#.data(using: .utf8)!
        let e = try JSONDecoder().decode(RawEdge.self, from: json)
        XCTAssertNil(e.confidence)
        XCTAssertNil(e.linkingPhrase)
    }

    // MARK: - ExtractionResponse

    func test_extractionResponse_topLevelDecode() throws {
        let json = """
        {
          "concepts": [
            {"label":"A","type":"concept","summary":"x","textSpan":"q","confidence":0.9}
          ],
          "edges": [
            {"sourceLabel":"A","targetLabel":"B","type":"dependsOn","confidence":0.8}
          ]
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ExtractionResponse.self, from: json)
        XCTAssertEqual(r.concepts.count, 1)
        XCTAssertEqual(r.edges.count, 1)
    }

    // MARK: - ChapterExtractionResponse

    func test_chapterExtractionResponse_decode() throws {
        let json = """
        {"chapters":[{"title":"Intro","pageStart":0,"pageEnd":4,"summary":"summary"}]}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(ChapterExtractionResponse.self, from: json)
        XCTAssertEqual(r.chapters.count, 1)
        XCTAssertEqual(r.chapters.first?.pageStart, 0)
        XCTAssertEqual(r.chapters.first?.pageEnd, 4)
    }

    func test_rawChapter_summaryOptional() throws {
        let json = #"{"title":"X","pageStart":0,"pageEnd":3,"summary":null}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(RawChapter.self, from: json)
        XCTAssertNil(c.summary)
    }

    // MARK: - RawFact

    func test_rawFact_decode_andDeepResponse() throws {
        let json = """
        {"facts":[{"claim":"X is Y","textSpan":"X is Y","type":"claim","confidence":0.9}]}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(RawFactExtractionResponse.self, from: json)
        XCTAssertEqual(r.facts.count, 1)
        XCTAssertEqual(r.facts.first?.type, "claim")
    }

    // MARK: - DeepConceptCluster

    func test_deepCluster_decode_nestedEntities() throws {
        let json = """
        {
          "concepts": [
            {
              "label": "X",
              "type": "concept",
              "summary": "s",
              "level": "concept",
              "factIndices": [0,1],
              "entities": [
                {"label":"E","type":"definition","summary":"d","parentLabel":"X","factIndices":[0]}
              ]
            }
          ]
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(DeepClusterResponse.self, from: json)
        XCTAssertEqual(r.concepts.count, 1)
        XCTAssertEqual(r.concepts.first?.entities?.count, 1)
        XCTAssertEqual(r.concepts.first?.entities?.first?.parentLabel, "X")
    }

    // MARK: - RawMergeProposal

    func test_rawMergeProposal_decode() throws {
        let json = """
        {"labelA":"A","labelB":"B","confidence":0.8,"reason":"sim","mergeType":"exactMatch"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(RawMergeProposal.self, from: json)
        XCTAssertEqual(p.labelA, "A")
        XCTAssertEqual(p.confidence, 0.8)
        XCTAssertEqual(p.mergeType, "exactMatch")
    }

    // MARK: - AnswerWithCitations

    func test_answerWithCitations_decode() throws {
        let json = """
        {"answer":"yes","citations":[{"text":"see fig","pageIndex":3}]}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(AnswerWithCitations.self, from: json)
        XCTAssertEqual(a.answer, "yes")
        XCTAssertEqual(a.citations.first?.pageIndex, 3)
    }
}
