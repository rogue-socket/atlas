# ETR mergeAdjudication v3 prompt — abstract-pattern A/B against v2

> **Branch:** `feature/etr-cross-doc`
> **Pairs with:** `audits/2026-05-17_etr-prompt-tune.md` (the v2 baseline), `prds/2026-05-15_4-level-knowledge-graph.md` §"Quality Rubric v2" (the obsolete rubric).
> **Code state:** both v2 and v3 prompts live in `Atlas/AI/PromptTemplates.swift` as `mergeAdjudicationV2` / `mergeAdjudicationV3`. Public `mergeAdjudication(...)` routes to v2 (the published behavior). Swap to v3 by changing one line in `mergeAdjudication`.

## Why v3 exists

Per `audits/2026-05-17_etr-prompt-tune.md` §E (the "hardcoding caveat"), the v2 prompt embeds vitacare-specific labels inline as both MERGE positives and KEEP-SEPARATE negatives. The concern: when the prompt runs against extractions that produce *different* labels than the exemplars, the patterns underneath might not generalize.

That concern became testable when we re-extracted vitacare on 2026-05-18 and observed the new extraction produces **chapter-style aggregated concepts** ("VitaCare Overview & Service Model", "Care Model & Cultural Principles") rather than the **fact-level entities** the v2 prompt's exemplars were grounded in. The v2 prompt's vitacare exemplars don't match any node label in the new graph — an accidental holdout-corpus test.

## v3 design

Same scaffolding as v2 (handbook-bullet-test framing, MERGE/KEEP-SEPARATE categories, "prefer KEEP-SEPARATE on uncertainty" stance). All vitacare-specific label exemplars stripped. Each pattern is described abstractly with its failure-mode criterion explicit.

New pattern category v3 adds (vs v2): **"Object ↔ property of object"** — split out from v2's catch-all "shared noun, different aspects" rule, named explicitly because the new extraction surfaces this pattern often (e.g., "Patient Portal" the channel ↔ "Patient Portal" WCAG accessibility).

New explicit heuristic v3 adds: **leaf-of-catalog word-list test** — "if label A is a single concrete offering and label B uses words like 'overview', 'services', 'portfolio', 'model', 'framework', 'principles', 'areas' — it is almost certainly leaf-of-catalog. Default to false." v2 had this anti-pattern but only via 4 vitacare-specific examples.

## Test setup

- **Corpus:** 4-PDF vitacare set, fresh extraction at 2026-05-18 02:16–02:28 (deep mode, Gemini 2.5 Flash, T=0+topK=1).
- **Baseline graph:** 214n / 405e total, 185 eligible (concept+entity), 12,628 cross-doc pairs. Snapshotted at `/tmp/atlas_snaps/postextract`.
- **Cache:** warm 185/185 (the same fresh-cold cache that filled during the 0.80 v2 run earlier in the session — contentHash re-keying preserves it across v2 and v3 runs).
- **Floor:** 0.80 (52-pair adjudication band — same band size as v2 since embedding stage is deterministic).
- **Determinism caveat:** single-run reading per prompt. Gemini at T=0+topK=1 is still slightly non-deterministic (`audits/2026-05-17_etr-prompt-tune.md` §"Methodology"). The 3-of-3 stable read isn't budget-feasible here yet — what follows is a 1-of-1 result.

## Headline result

| Prompt | Approvals / 52 | Eyeball clean | Eyeball borderline | Eyeball wrong | Est. precision |
|---|---|---|---|---|---|
| v2 | 12 | 4 | 2 | 6 | ~33% |
| v3 | **4** | 2 | 2 | 0 | **~50–100%** |

v3 is ~3× more conservative and qualitatively cleaner. **Hardcoding was hurting more than helping on novel-label extractions.**

## v2 → v3 transition (all 12 v2 approvals classified)

| # | Pair | v2 | v3 | Eyeball verdict |
|---|---|---|---|---|
| 1 | Corporate & Provider Compliance ↔ Legal Structure & Clinical Services | ✓ | ✓ | **Kept — valid** (both = company-level compliance/legal scope) |
| 2 | VitaCare Overview & Service Model ↔ Care Model & Cultural Principles | ✓ | ✓ | **Kept — over-merge** (umbrella ↔ aspect; v3's leaf-of-catalog rule failed because both sides have umbrella-y words) |
| 3 | VitaCare Overview & Governance ↔ Company Identity | ✓ | ✗ | Dropped — ambiguous (could be either) |
| 4 | VitaCare Overview & Service Model ↔ Core Care Principles | ✓ | ✓ | **Kept — over-merge** (same pattern as #2) |
| 5 | Diagnostic & Pharmacy Partners ↔ On-site & Ancillary Services | ✓ | ✗ | **Dropped — correct reject** (external partners vs internal facilities) |
| 6 | SUD Record Protections ↔ Behavioral Health Record Privacy | ✓ | ✗ | **Dropped — REAL LOSS** (SUD privacy IS a subset of BH privacy under 42 CFR Part 2; v3's abstract patterns don't surface "regulatory subset") |
| 7 | Telehealth Availability & Response Times ↔ Clinic & Telehealth Hours | ✓ | ✗ | Dropped — borderline (operational hours vs SLA; arguably distinct facts) |
| 8 | Core Care Principles ↔ Primary Care & Chronic Condition Management | ✓ | ✗ | **Dropped — correct reject** (philosophy vs service offering) |
| 9 | Group Programs & Newsletters ↔ Chronic Disease Management Programs | ✓ | ✗ | **Dropped — correct reject** (different program types) |
| 10 | Strategic Partnerships ↔ On-site & Ancillary Services | ✓ | ✗ | **Dropped — correct reject** (external partnerships vs internal services) |
| 11 | Consent Framework ↔ Behavioral Health Record Privacy | ✓ | ✓ | **Kept — valid** (consent ⊂ privacy framework) |
| 12 | VitaCare Overview & Service Model ↔ VitaCare Patient Experience Design | ✓ | ✗ | **Dropped — correct reject** (umbrella ↔ design aspect) |

**Score: v3 corrected 5 false positives, dropped 1 valid merge (#6), and left 2 false positives unaddressed (#2, #4).**

v3 did not introduce any new approvals — every v3 approval is also a v2 approval.

## What v3 still gets wrong (and why)

The two surviving over-merges (#2 and #4) share a pattern: **both sides of the pair contain umbrella-style words**. v3's leaf-of-catalog rule fires when label B uses "overview / model / services / portfolio / framework / principles / areas". But:

- #2 "VitaCare Overview & Service Model" ↔ "Care Model & Cultural Principles" — both have those trigger words
- #4 "VitaCare Overview & Service Model" ↔ "Core Care Principles" — same

The rule was implicitly designed assuming label A is a *concrete leaf* (e.g., "Post-Discharge Care") and label B is umbrella-y. When both sides are umbrella-y, the asymmetry test the rule depends on collapses.

**v4 candidate fix (one-line prompt change):** rewrite the leaf-of-catalog rule to fire whenever *either* side contains umbrella-words AND the other side is more specific than the umbrella side. I.e., make the test "is one side strictly contained within the other's scope" rather than "do the trigger words appear on the right side." Estimated cost to test: ~$0.10 (warm cache, 3 LLM batches).

## What v3 gave up (the real loss)

#6 (SUD ↔ BH privacy) is a regulatory-subset relationship: SUD records have heightened protections under 42 CFR Part 2, layered *on top of* the broader Behavioral Health record privacy regime. v2 caught this because the prompt happened to have "Insurance Networks ↔ Insurance Policies" as a negative example, and the LLM inferred "X protections ↔ X privacy" as the *inverse* positive pattern.

v3's abstract patterns don't have an explicit "regulatory subset" or "subordinate framework" category. This is a real recall loss, not a noise reduction.

**Repair shape for v4:** add a MERGE category "Regulatory subset" — "one label is a regulatory regime; the other is a stricter subset of that regime applying to a narrower population/data class." This is corpus-neutral; works for HIPAA + SUD (vitacare), GDPR + minor-data (any consumer app), tax law + jurisdiction overlays, etc.

## Cost

- v3 ETR run at 0.80: ~$0.10 (warm cache, 3 LLM batches). Total wall-clock ~2 min.

## On-disk artifacts (preserved per "don't delete anything")

| Path | What |
|---|---|
| `/tmp/atlas_snaps/postextract/` | The 4 per-doc graph files immediately after re-extraction (the baseline every ETR variant ran against) |
| `/tmp/atlas_snaps/post080/` | Per-doc files after v2 ETR @ 0.80 |
| `/tmp/atlas_snaps/post075/` | Per-doc files after v2 ETR @ 0.75 |
| `/tmp/atlas_snaps/post070/` | Per-doc files after v2 ETR @ 0.70 |
| `/tmp/atlas_snaps/postv3_080/` | Per-doc files after v3 ETR @ 0.80 |
| `/tmp/atlas_sidecar_v3_080_*.json` | Pinned copy of the v3 sidecar (the live one in `Atlas/graphs/` will be overwritten by the next ETR run) |
| `/tmp/atlas_embcache_2026-05-17_*.json` | Frozen copy of the 2026-05-17 embedding cache from before the contentHash re-key (legacy UUID schema) |
| `Atlas/graphs/etr_audit_*.json` (live) | 4 new sidecars from the 2026-05-18 sweep: 0.80 v2, 0.75 v2, 0.70 v2, 0.80 v3 — most-recent-4 by mtime |

The live project graph in `Atlas/graphs/` is whatever the most recent ETR run left behind. `/tmp/atlas_etr_sweep.sh restore postextract` puts the baseline back.

## Recommended next moves (ranked)

1. **v4 with corrected leaf-of-catalog rule + regulatory-subset MERGE category.** ~$0.10 to test, addresses both unfixed over-merges and the one real-loss recall regression. Highest leverage.
2. **Re-ground the rubric** against the 2026-05-18 fresh-extraction labels. Manual ~1 hr. Without this, any future precision/recall comparisons remain qualitative eyeball-only.
3. **3-of-3 stability read on v3** (run 0.80 twice more). ~$0.20. Necessary before treating any single-run v3 result as the final answer.
4. **Holdout corpus run** — extract a non-vitacare corpus (harvest_hearth was held out per the locked-in prep items) and compare v2 vs v3 on a corpus with zero overlap with v2's hardcoded exemplars.

The "off-rubric extras" framework from the 2026-05-17 doc is now obsolete — the new extraction produces no pairs that match the old rubric labels, so there are no "off-rubric extras" to promote. The whole rubric needs re-grounding (item 2 above) before that framework comes back online.
