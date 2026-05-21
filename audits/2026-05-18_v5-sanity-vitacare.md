# v5 prompt — vitacare sanity check

**Date:** 2026-05-18 15:49–15:53
**Branch:** `feature/etr-cross-doc` (HEAD `7050680`); delegator flipped v4→v5 for the sweep, reverted after scoring (no commits, no push, working tree clean).
**Cost:** ~$0.10 Gemini (3 runs × 52 in-band pairs × 3 batches, warm embedding cache).
**Status:** Closes `[next 2026-05-18] v5 vitacare sanity check`. **v5 stays inactive.**

## TL;DR

v5's stable scores on vitacare tie v4 perfectly (P/R/T = 100/100/0). But v5's **worst-case single-run envelope is meaningfully worse** than v4 — and the misses are exactly the pairs the backlog flagged as v5-risk. v5 is not safe to promote on vitacare; combined with its marginal harvest result, v5 has no corpus where it dominates v4.

## Setup

- Baseline: 4-doc vitacare graphs from `/tmp/atlas_snaps/postextract/` (the 2026-05-18 02:28 fresh re-extraction). 214n / 405e / 185 eligible. Same baseline used for every prior vitacare ETR run today.
- `test_proj` recreated in UI (had been removed when `harvest_hearth` was created earlier today). 4 vitacare PDFs added; no extraction (script restores graphs from snapshot before each run).
- Delegator flipped: `PromptTemplates.mergeAdjudication` → `mergeAdjudicationV5(pairs:)` for the sweep; reverted to v4 immediately after scoring.
- 3 runs at floor 0.80 via `/tmp/atlas_run_etr.sh v5 {1,2,3}`. Each restored baseline first.

## Raw results

| Run | Approved | MUST-MERGE caught | MUST-REJECT tripped | In-doc tripped |
|---|---|---|---|---|
| v5 run 1 | 6/52 | 3/3 (#3, #11, #45) | 3/43 (#5, #10, #13) | — |
| v5 run 2 | 4/52 | 3/3 (#3, #11, #45) | 1/43 (#10) | — |
| v5 run 3 | 7/52 | 3/3 (#3, #11, #45) | **3/43 (#4, #17, #19)** | #6 |

Sidecars pinned at `/tmp/atlas_sidecar_v5_run{1,2,3}_20260518T155*.json`.

## 3-of-3 stable intersection

| | Approved | M / R / B | Precision | Recall | Trap rate |
|---|---|---|---|---|---|
| v5 stable | 3 (#3, #11, #45) | 3 / 0 / 0 | **100%** | **100%** | **0.0%** |
| v4 stable (audit baseline) | 3 | 3 / 0 / 0 | 100% | 100% | 0.0% |

Stable picture: **dead tie with v4.**

## Worst-case envelope (the load-bearing finding)

| | Worst-case trap (single run) | Union flapping |
|---|---|---|
| v4 vitacare (from `audits/2026-05-18_v4-prompt-experiment.md`) | 0/43 | 6 unique approvals |
| v5 vitacare (this run) | **3/43** (run 3) | 8 unique approvals (`{3, 4, 5, 6, 10, 11, 13, 17, 19, 45}`) |

**Run 3 tripped the two pairs the backlog explicitly flagged as v5-risk:** #17 (`Cultural Principles ↔ Primary Care Management`) and #19 (`Core Care Principles ↔ Primary Care Management`). v5's "Brand value ↔ canonical implementing program" MERGE category catches them, and the paired substitution-test discriminator that's supposed to reject "one-of-many implementations" only sometimes saves them. The risk hypothesis turned out to be real, just sample-dependent.

Run 3 also approved in-doc pair #6 (rubric category X, excluded). v4 hasn't been observed approving an in-doc pair on this corpus.

## Cross-corpus picture (v5 has no domain win)

| Corpus | v3 stable | v4 stable | v5 stable | v4 worst-case trap | v5 worst-case trap |
|---|---|---|---|---|---|
| vitacare | 100 / 100 / 0 | 100 / 100 / 0 | 100 / 100 / 0 | 0/43 | **3/43** |
| harvest_hearth | 93 / 70 / 10 | 100 / 55 / 0 | 92 / 60 / 0 | 0/43 | 5/43 |

v5 ties v4 on stable scores in vitacare and loses on noise envelope. v5 also doesn't beat v4 on harvest stable (1 recall point recovered, 5 percent precision lost, worst-case trap regressed 4→5). **v5 has no corpus where it dominates** — its theoretical lift (brand-value↔implementing-program MERGE) is real on a few pairs but the substitution-test gate is too noisy to make it usable in production.

## Verdict

**v4 stays the public delegator. v5 stays in `PromptTemplates.swift` as `private static` for archival.** The delegator was reverted in this session (uncommitted edit, no diff vs HEAD).

The risk flag in the backlog was vindicated: v5 *does* trip vitacare's #17 / #19. Closing the line item with this result.

## What's still open after this

- The recall gap on harvest's brand-value↔split-implementation pattern is a corpus-structural problem, not a prompt-iteration problem. Already tracked: `[next 2026-05-18] Corpus-structural recall mechanism (post-LLM clustering)`.
- Per-project prompt selection (`etr.prompt = v3 | v4 | v5`) becomes more attractive now that the cross-corpus picture is conclusive. Still deferred until users have multiple corpora live. Already tracked.
- A v6 attempt would need a different discriminator for the brand-value→one-of-many case — the current substitution test is the proven weak link. Not on the active backlog; would be a fresh experiment if reopened.

## Reproduction

Already encoded:

```sh
# Prereqs: test_proj exists in UI with 4 vitacare PDFs; Atlas app quit.
# Delegator must be flipped to mergeAdjudicationV5 + rebuilt.
/tmp/atlas_run_etr.sh v5 1
/tmp/atlas_run_etr.sh v5 2
/tmp/atlas_run_etr.sh v5 3
python3 /tmp/atlas_score_v5_vitacare.py
# Revert delegator to mergeAdjudicationV4. No commit needed — was never committed.
```
