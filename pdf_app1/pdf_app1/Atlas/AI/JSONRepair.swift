//
//  JSONRepair.swift
//  Atlas
//
//  Shared utility for extracting and repairing truncated JSON from LLM responses
//

import Foundation
import os.log

private let log = AtlasLogger.ai

enum JSONRepair {

    /// Strip markdown code fences and repair truncated JSON
    static func cleanAndRepair(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if result.hasPrefix("```") {
            if let endOfFirstLine = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: endOfFirstLine)...])
            }
            if result.hasSuffix("```") {
                result = String(result.dropLast(3))
            }
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !result.isEmpty else { return result }

        // Check if it parses already
        if (try? JSONSerialization.jsonObject(with: Data(result.utf8))) != nil {
            return result
        }

        log.info("JSON is malformed, attempting repair (\(result.count) chars)...")
        return repair(result)
    }

    private static func repair(_ json: String) -> String {
        var repaired = json

        // Close unclosed strings
        var inString = false
        var escaped = false
        for ch in repaired {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString = !inString }
        }
        if inString { repaired += "\"" }

        // Remove trailing comma
        let trimmed = repaired.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(",") {
            repaired = String(trimmed.dropLast())
        }

        // Count and close open brackets/braces
        var openBraces = 0
        var openBrackets = 0
        inString = false
        escaped = false
        for ch in repaired {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" { inString = !inString; continue }
            if inString { continue }
            switch ch {
            case "{": openBraces += 1
            case "}": openBraces -= 1
            case "[": openBrackets += 1
            case "]": openBrackets -= 1
            default: break
            }
        }

        for _ in 0..<max(0, openBrackets) { repaired += "]" }
        for _ in 0..<max(0, openBraces) { repaired += "}" }

        if (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) != nil {
            log.info("JSON repair succeeded (bracket closure)")
            return repaired
        }

        // Aggressive: find last complete concept object and drop the rest
        if let conceptsRange = json.range(of: "\"concepts\"") {
            let afterConcepts = json[conceptsRange.upperBound...]
            var lastGoodEnd = afterConcepts.startIndex
            var braceDepth = 0
            var inStr = false
            var esc = false
            var foundArray = false
            for i in afterConcepts.indices {
                let ch = afterConcepts[i]
                if esc { esc = false; continue }
                if ch == "\\" { esc = true; continue }
                if ch == "\"" { inStr = !inStr; continue }
                if inStr { continue }
                if ch == "[" { foundArray = true; braceDepth += 1 }
                else if ch == "]" {
                    braceDepth -= 1
                    if foundArray && braceDepth == 0 { lastGoodEnd = afterConcepts.index(after: i); break }
                } else if ch == "}" && braceDepth == 1 {
                    lastGoodEnd = afterConcepts.index(after: i)
                }
            }

            if lastGoodEnd > afterConcepts.startIndex {
                let partial = String(json[json.startIndex..<lastGoodEnd])
                let fixed = partial + "], \"edges\": []}"
                if (try? JSONSerialization.jsonObject(with: Data(fixed.utf8))) != nil {
                    log.info("JSON repair succeeded (truncated edges recovery)")
                    return fixed
                }
            }
        }

        log.error("JSON repair failed")
        return json
    }
}
