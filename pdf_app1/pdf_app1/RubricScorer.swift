//
//  RubricScorer.swift
//  pdf_app1
//
//  `--score-rubric` headless mode: scores a cross-doc run's output graph
//  against the frozen vitacare quality rubric (PRD §"Quality Rubric v2 —
//  vitacare 2026-05-16") and logs a precision/recall scorecard.
//
//  WHY: the rubric's 20+20 pairs are frozen against the labels of the
//  2026-05-16 extraction. Re-running SCE/ETR re-extracts, and node labels
//  drift — so locating a rubric pair by exact-label lookup fails (the
//  2026-05-19 SCE run had 17/20 should-not-merge pairs come back MISSING).
//  This scorer locates each rubric label by embedding cosine similarity to
//  the nearest node instead, so the rubric stays interpretable across
//  re-extractions.
//
//  USAGE:
//    pdf_app1 --headless-extract --score-rubric /path/to/graph.json
//  The graph file may be a raw `KnowledgeGraph.CodableRepresentation` or a
//  `GraphStore` StoredGraph envelope — both are handled. An embedding
//  backend must be configured in Settings. Output goes to the unified log,
//  prefixed `[Rubric]`:
//    log stream --predicate 'process == "pdf_app1"' | grep Rubric
//
//  METHOD: every rubric label and every graph-node label is embedded; each
//  rubric label is matched to its nearest node by cosine similarity. A pair
//  counts as "merged" when both its labels resolve to the *same* node
//  (a cross-doc merge collapses two doc-scoped nodes into one). Precision
//  and recall are computed only over pairs whose *both* labels cleared the
//  match floor; pairs that didn't are reported separately as MISSING and
//  are not folded into the ratios.
//
//  LIMITATIONS: the rubric is vitacare-specific — scoring any other corpus
//  is meaningless. Nearest-node matching can mis-locate a label onto a
//  coincidentally-similar node; each per-pair log line prints the matched
//  node label + similarity so a human can spot-check.
//

import Foundation
import os.log

/// One frozen rubric pair. `docA`/`docB` are the PRD's doc abbreviations
/// (CLI/COM/ORG/PAT), kept for scorecard readability only — matching itself
/// is purely embedding-based and ignores them.
private struct RubricPair {
    let group: String   // "should-merge" | "should-not-merge"
    let index: Int
    let docA: String
    let labelA: String
    let docB: String
    let labelB: String
    var expectMerge: Bool { group == "should-merge" }
}

enum RubricScorer {
    private static let log = AtlasLogger.headless

    /// Below this cosine a rubric label is treated as not locatable in the
    /// run's graph ("MISSING"). Heuristic — this is a *location* test, not a
    /// merge decision, so it sits well below the resolver's 0.75–0.95 merge
    /// thresholds.
    private static let matchFloor: Float = 0.60

    @MainActor
    static func run(graphPath: String, aiService: AIServiceManager, graph: KnowledgeGraph) async {
        log.info("[Rubric] scoring \(graphPath, privacy: .public)")

        // 1. Load the run's output graph. A GraphStore file is a StoredGraph
        //    envelope whose `payload` holds the CodableRepresentation; a bare
        //    export is the CodableRepresentation itself. Try the envelope
        //    first (decoding only `payload` ignores its other fields), and
        //    fall back to treating the whole file as the representation.
        let fileURL = URL(fileURLWithPath: graphPath)
        guard let fileData = try? Data(contentsOf: fileURL) else {
            log.error("[Rubric] cannot read graph file: \(graphPath, privacy: .public)")
            exit(4)
        }
        struct StoredEnvelope: Decodable { let payload: Data }
        let payload = (try? JSONDecoder().decode(StoredEnvelope.self, from: fileData))?.payload ?? fileData
        do {
            try graph.decode(from: payload)
        } catch {
            log.error("[Rubric] could not decode graph: \(error.localizedDescription)")
            exit(4)
        }
        let nodes = graph.allNodes
        guard !nodes.isEmpty else {
            log.error("[Rubric] graph has no nodes — nothing to score")
            exit(4)
        }
        log.info("[Rubric] loaded \(nodes.count) nodes")

        // 2. Embedding backend.
        guard let embedder = aiService.createEmbeddingBackend() else {
            log.error("[Rubric] no embedding backend configured — set one in Settings")
            exit(3)
        }

        // 3. Embed every node label and every (deduped) rubric label.
        let nodeLabels = nodes.map { $0.label }
        let rubricLabels = Array(Set(pairs.flatMap { [$0.labelA, $0.labelB] }))
        let nodeVecs: [[Float]]
        let rubricVecs: [[Float]]
        do {
            nodeVecs = try await embedder.embed(nodeLabels)
            rubricVecs = try await embedder.embed(rubricLabels)
        } catch {
            log.error("[Rubric] embedding failed: \(error.localizedDescription)")
            exit(5)
        }
        guard nodeVecs.count == nodes.count, rubricVecs.count == rubricLabels.count else {
            log.error("[Rubric] embedding backend returned a mismatched vector count")
            exit(5)
        }
        var vecByLabel: [String: [Float]] = [:]
        for (label, vec) in zip(rubricLabels, rubricVecs) { vecByLabel[label] = vec }

        // 4. Nearest-node match for a rubric label.
        func nearest(_ label: String) -> (node: ConceptNode, similarity: Float) {
            let vec = vecByLabel[label] ?? []
            var bestIdx = 0
            var bestSim: Float = -1
            for (i, nv) in nodeVecs.enumerated() {
                let s = EmbeddingMath.cosineSimilarity(vec, nv)
                if s > bestSim { bestSim = s; bestIdx = i }
            }
            return (nodes[bestIdx], bestSim)
        }

        // 5. Score every pair.
        var tp = 0, fp = 0, fn = 0, tn = 0, missing = 0
        log.info("[Rubric] ── per-pair ──────────────────────────────")
        for pair in pairs {
            let a = nearest(pair.labelA)
            let b = nearest(pair.labelB)
            let located = a.similarity >= matchFloor && b.similarity >= matchFloor
            let merged = located && a.node.id == b.node.id

            let outcome: String
            if !located {
                missing += 1
                outcome = "MISSING (label not locatable)"
            } else if pair.expectMerge {
                if merged { tp += 1; outcome = "TP (merge caught)" }
                else { fn += 1; outcome = "FN (merge missed)" }
            } else {
                if merged { fp += 1; outcome = "FP (wrong merge)" }
                else { tn += 1; outcome = "TN (correctly separate)" }
            }

            let simA = String(format: "%.3f", a.similarity)
            let simB = String(format: "%.3f", b.similarity)
            log.info("[Rubric] \(pair.group, privacy: .public) #\(pair.index): \(pair.docA, privacy: .public) \"\(pair.labelA, privacy: .public)\" → \"\(a.node.label, privacy: .public)\" (\(simA, privacy: .public)) | \(pair.docB, privacy: .public) \"\(pair.labelB, privacy: .public)\" → \"\(b.node.label, privacy: .public)\" (\(simB, privacy: .public)) | merged=\(merged) → \(outcome, privacy: .public)")
        }

        // 6. Scorecard.
        let precision = (tp + fp) > 0 ? Double(tp) / Double(tp + fp) : 0
        let recall = (tp + fn) > 0 ? Double(tp) / Double(tp + fn) : 0
        log.info("[Rubric] ── scorecard ─────────────────────────────")
        log.info("[Rubric] TP=\(tp) FP=\(fp) FN=\(fn) TN=\(tn) MISSING=\(missing) (of \(pairs.count) rubric pairs)")
        log.info("[Rubric] precision = TP/(TP+FP) = \(String(format: "%.3f", precision), privacy: .public)")
        log.info("[Rubric] recall    = TP/(TP+FN) = \(String(format: "%.3f", recall), privacy: .public)")
        log.info("[Rubric] precision/recall are over located pairs only; MISSING (\(missing)) excluded")
        exit(0)
    }

    // MARK: - Frozen rubric (PRD §"Quality Rubric v2 — vitacare 2026-05-16")
    //
    // 20 should-merge + 20 should-not-merge cross-doc pairs. Labels are
    // verbatim from the PRD tables with trailing "(concept)"/"(entity)"
    // node-type annotations and role parentheticals stripped (they aren't
    // part of the label text). Doc tags: CLI / COM / ORG / PAT.

    private static let pairs: [RubricPair] = [
        // ── should-merge (20) ──
        RubricPair(group: "should-merge", index: 1, docA: "CLI",
                   labelA: "Asynchronous messages",
                   docB: "PAT", labelB: "In-app messaging: response within 6 business hours, typically much faster"),
        RubricPair(group: "should-merge", index: 2, docA: "CLI",
                   labelA: "same-day or next-day results",
                   docB: "PAT", labelB: "Lab result release: typically within 24 hours of completion"),
        RubricPair(group: "should-merge", index: 3, docA: "CLI",
                   labelA: "Lab Result Communication",
                   docB: "PAT", labelB: "Lab result release: typically within 24 hours of completion"),
        RubricPair(group: "should-merge", index: 4, docA: "CLI",
                   labelA: "referral and prior authorization handled by VitaCare care coordinators",
                   docB: "PAT", labelB: "Care coordinator handles prior authorization where required"),
        RubricPair(group: "should-merge", index: 5, docA: "CLI",
                   labelA: "referral and prior authorization handled by VitaCare care coordinators",
                   docB: "PAT", labelB: "care coordinator manages the referral end-to-end"),
        RubricPair(group: "should-merge", index: 6, docA: "CLI",
                   labelA: "referral and prior authorization handled by VitaCare care coordinators",
                   docB: "PAT", labelB: "Care coordinator matches the patient to a high-quality specialist within their insurance network"),
        RubricPair(group: "should-merge", index: 7, docA: "CLI",
                   labelA: "Annual Wellness Visit",
                   docB: "PAT", labelB: "Annual wellness visit: scheduled within 14 days of patient request"),
        RubricPair(group: "should-merge", index: 8, docA: "CLI",
                   labelA: "Specialty Care Services",
                   docB: "PAT", labelB: "Specialist visit (VitaCare specialty): within 14 days for routine, same-day for urgent"),
        RubricPair(group: "should-merge", index: 9, docA: "CLI",
                   labelA: "discounted specialty services",
                   docB: "PAT", labelB: "Specialist visit (VitaCare specialty): within 14 days for routine, same-day for urgent"),
        RubricPair(group: "should-merge", index: 10, docA: "CLI",
                   labelA: "Advanced Imaging Referrals",
                   docB: "PAT", labelB: "External Care Coordination"),
        RubricPair(group: "should-merge", index: 11, docA: "CLI",
                   labelA: "Substance use disorder treatment",
                   docB: "COM", labelB: "Substance Use Disorder Records (42 CFR Part 2)"),
        RubricPair(group: "should-merge", index: 12, docA: "CLI",
                   labelA: "messaging-based care",
                   docB: "PAT", labelB: "In-app messaging: response within 6 business hours, typically much faster"),
        RubricPair(group: "should-merge", index: 13, docA: "CLI",
                   labelA: "Lab results are posted to the patient portal",
                   docB: "PAT", labelB: "Lab result release: typically within 24 hours of completion"),
        RubricPair(group: "should-merge", index: 14, docA: "ORG",
                   labelA: "Clinic hours are 7:30 AM - 7:00 PM Monday through Friday and 8:00 AM - 2:00 PM on Saturdays",
                   docB: "PAT", labelB: "Extended evening hours available at 16 clinics (open until 9:00 PM)"),
        RubricPair(group: "should-merge", index: 15, docA: "CLI",
                   labelA: "primary care clinician",
                   docB: "PAT", labelB: "Clinician identifies need for outside care and writes a referral"),
        RubricPair(group: "should-merge", index: 16, docA: "CLI",
                   labelA: "MRI, CT, mammography",
                   docB: "PAT", labelB: "External Care Coordination"),
        RubricPair(group: "should-merge", index: 17, docA: "CLI",
                   labelA: "VitaCare Direct Membership",
                   docB: "PAT", labelB: "Patient Pricing & Insurance"),
        RubricPair(group: "should-merge", index: 18, docA: "CLI",
                   labelA: "affiliated imaging centers",
                   docB: "PAT", labelB: "External Care Coordination"),
        RubricPair(group: "should-merge", index: 19, docA: "CLI",
                   labelA: "HIPAA-compliant clinical record system",
                   docB: "COM", labelB: "Technical Safeguards"),
        RubricPair(group: "should-merge", index: 20, docA: "COM",
                   labelA: "Patients entering SUD treatment receive a plain-language overview of how their records are protected, who can access them, and what consent looks like in practice.",
                   docB: "CLI", labelB: "Substance use disorder treatment"),

        // ── should-not-merge (20) ──
        RubricPair(group: "should-not-merge", index: 1, docA: "ORG",
                   labelA: "$1,200 annual wellness reimbursement",
                   docB: "PAT", labelB: "Annual wellness visit: scheduled within 14 days of patient request"),
        RubricPair(group: "should-not-merge", index: 2, docA: "COM",
                   labelA: "Privacy Officer",
                   docB: "ORG", labelB: "Dr. Helena Vargas"),
        RubricPair(group: "should-not-merge", index: 3, docA: "CLI",
                   labelA: "Video visits",
                   docB: "ORG", labelB: "Dedicated telehealth clinicians work fully remote with a state-licensed home setup"),
        RubricPair(group: "should-not-merge", index: 4, docA: "CLI",
                   labelA: "HIPAA-compliant clinical record system",
                   docB: "COM", labelB: "HIPAA Security Rule"),
        RubricPair(group: "should-not-merge", index: 5, docA: "CLI",
                   labelA: "Insurance Networks",
                   docB: "COM", labelB: "Insurance Policies"),
        RubricPair(group: "should-not-merge", index: 6, docA: "ORG",
                   labelA: "Quality incentive: up to 18% of base",
                   docB: "COM", labelB: "Quality Measurement"),
        RubricPair(group: "should-not-merge", index: 7, docA: "ORG",
                   labelA: "Patient Net Promoter Score (NPS): 71",
                   docB: "PAT", labelB: "98.9% on-time visit starts (visits started within 15 minutes of scheduled time)"),
        RubricPair(group: "should-not-merge", index: 8, docA: "CLI",
                   labelA: "Behavioral health",
                   docB: "COM", labelB: "Substance Use Disorder Records (42 CFR Part 2)"),
        RubricPair(group: "should-not-merge", index: 9, docA: "CLI",
                   labelA: "Pediatric primary care",
                   docB: "ORG", labelB: "Physicians (MD/DO): 312"),
        RubricPair(group: "should-not-merge", index: 10, docA: "CLI",
                   labelA: "988 Suicide and Crisis Lifeline",
                   docB: "PAT", labelB: "After-hours nurse line: 24/7 for VitaCare patients with urgent clinical concerns"),
        RubricPair(group: "should-not-merge", index: 11, docA: "CLI",
                   labelA: "Care Between Visits",
                   docB: "PAT", labelB: "Post-Discharge Care"),
        RubricPair(group: "should-not-merge", index: 12, docA: "CLI",
                   labelA: "Lab results are posted to the patient portal",
                   docB: "PAT", labelB: "Patient portal meets WCAG 2.1 AA accessibility standards"),
        RubricPair(group: "should-not-merge", index: 13, docA: "ORG",
                   labelA: "EAP with 12 free counseling sessions per issue per year",
                   docB: "CLI", labelB: "Behavioral Health Services"),
        RubricPair(group: "should-not-merge", index: 14, docA: "ORG",
                   labelA: "Free VitaCare primary care for employees and dependents on VitaCare health plans",
                   docB: "CLI", labelB: "VitaCare Direct Membership"),
        RubricPair(group: "should-not-merge", index: 15, docA: "CLI",
                   labelA: "Virtual Care Platform",
                   docB: "COM", labelB: "Telehealth platform RTO/RPO"),
        RubricPair(group: "should-not-merge", index: 16, docA: "ORG",
                   labelA: "Hypertension control to under 140/90 mmHg: 81%",
                   docB: "PAT", labelB: "98.9% on-time visit starts"),
        RubricPair(group: "should-not-merge", index: 17, docA: "CLI",
                   labelA: "Send-out Lab Services",
                   docB: "COM", labelB: "Business Associate Agreements"),
        RubricPair(group: "should-not-merge", index: 18, docA: "CLI",
                   labelA: "Specialty Care Services",
                   docB: "PAT", labelB: "Specialist Network Curation"),
        RubricPair(group: "should-not-merge", index: 19, docA: "PAT",
                   labelA: "Group Programs",
                   docB: "CLI", labelB: "Chronic Condition Programs"),
        RubricPair(group: "should-not-merge", index: 20, docA: "CLI",
                   labelA: "Substance use disorder treatment",
                   docB: "COM", labelB: "distinct consent and disclosure framework"),
    ]
}
