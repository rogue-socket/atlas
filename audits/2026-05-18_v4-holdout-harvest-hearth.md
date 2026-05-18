# ETR v4 vs v3 — harvest_hearth holdout

> **Branch:** `feature/etr-cross-doc` (delegator restored to v4 in working tree).
> **Pairs with:** `audits/2026-05-18_v4-prompt-experiment.md` (vitacare in-corpus result), `audits/2026-05-18_rubric-v3-vitacare.md` (vitacare rubric), `PromptTemplates.swift` (`mergeAdjudicationV4`).
> **TL;DR:** v4's in-corpus win on vitacare does NOT generalize. On harvest_hearth, v3 wins on recall (70% stable vs 55% v4 stable) while v4 wins on precision (100% stable vs 93% v3 stable) and trap rate (0% vs 10%). The trade-off is real and corpus-dependent.

## Why this exists

The vitacare A/B (`audits/2026-05-18_v4-prompt-experiment.md`) recommended flipping the public delegator to v4 based on a single-corpus result. The locked-in repeat-run holdout corpus is `harvest_hearth` (per `audits/2026-05-16_etr-step1-plan.md` §3 — "harvest_hearth held as repeat-run holdout"). This audit runs the same 6-run sweep on it.

## Test setup

- **Corpus:** 4-PDF `harvest_hearth` set (`sample_pdfs/files/harvest_hearth_{company_and_people, customer_experience_and_operations, product_lines_and_pricing, sustainability_security_and_compliance}.pdf`). New `harvest_hearth` project created in UI (test_proj was replaced — vitacare per-doc graphs remain on `/tmp/atlas_snaps/postextract/`).
- **Extraction:** deep mode, Gemini 2.5 Flash, T=0+topK=1. Result: 278 nodes total, 246 eligible (concept + entity), 12,628 pairs (the resolver evaluated 12,628 — same as vitacare; this is the in-doc/cross-doc evaluation count, not strictly cross-doc).
- **Floor:** 0.80. In-band pairs: **106** (vs vitacare's 52 — harvest_hearth is denser in cross-doc semantic similarity, mostly because the brand-voice content repeats across docs).
- **Runs:** 3× v3 + 3× v4, baseline snapshot restored between every run (`/tmp/atlas_snaps/harvest_postextract/`). Warm-cache after first run.
- **Cost:** ~$1 extraction (14 min wall-clock) + ~$1.20 for the 6 ETR runs. Total ~$2.20.
- **Rubric:** hand-graded from the 39-pair **union** of all 6 runs (no rubric for the 67 silently-rejected pairs — they're presumed correct by 6/6 consensus and excluded from scoring denominator). Source data: `/tmp/harvest_grading.txt`. Counts: 20 MUST-MERGE, 10 MUST-REJECT, 9 BORDERLINE.

## Headline

| | Stable approvals | Precision | Recall (of 20 M) | Trap rate (of 10 R) | Worst-run traps |
|---|---|---|---|---|---|
| **v3** | 15 | 93% | **70%** | 10% (1/10) | 3 |
| **v4** | 11 | **100%** | 55% | 0% (0/10) | 4 |

The vitacare-headline framing ("v4 wins decisively") does not hold here. On harvest_hearth:

- **v3 wins recall by 15 points** in stable intersection (70% vs 55%).
- **v4 wins precision by 7 points** and trap rate by 10 points.
- **v4 worst-case is no better** than v3 — same 4-trap-floor in the highest-trap single run.
- **v4 actually flaps more** on harvest: 22 flapping pairs vs v3's 16. The vitacare "v4 has half the noise envelope" relationship inverts here.

## Per-run breakdown

| Prompt | Run | Approvals | Must-merge caught | Must-reject tripped | Borderline | Precision | Recall |
|---|---|---|---|---|---|---|---|
| v3 | 1 | 24 | 18 | 2 | 4 | 75% | 90% |
| v3 | 2 | 21 | 17 | 3 | 1 | 81% | 85% |
| v3 | 3 | 22 | 17 | 3 | 2 | 77% | 85% |
| v4 | 1 | 23 | 18 | 3 | 2 | 78% | 90% |
| v4 | 2 | 23 | 13 | 4 | 6 | 57% | 65% |
| v4 | 3 | 19 | 15 | 1 | 3 | 79% | 75% |

v3's per-run profile is tighter (P 75-81%, R 85-90%); v4 has wider per-run swings (P 57-79%, R 65-90%) — exactly the opposite of vitacare.

## What v4 misses that v3 catches

The 6 must-merges in v3-stable but NOT in v4-stable (out of v4-missed-9):

| # | Pair | Why v4 likely rejects |
|---|---|---|
| #3 | Supply Chain & Operations ↔ Supply Chain & Logistics | Both umbrella concepts on the same topic — v4's leaf-of-catalog rule fires on "umbrella ↔ umbrella where one might be broader" |
| #4 | Logistics & Inventory Management ↔ Supply Chain & Logistics | Same pattern |
| #35 | Repair and Resell (brand value) ↔ Product Lifecycle & Sustainability (concept) | Brand-value vs program — v4's scope-containment rule reads brand-value as "inside" the program scope, classifies as leaf-of-catalog |
| #45 | Repair and Resell ↔ Product Lifecycle & Sustainability Programs | Same |
| #65 | Repair and Resell ↔ Hearth Again Resale Program | Brand-value vs specific implementing program |
| #66 | Company Philosophy & Principles ↔ Company Mission | Both umbrella, slight scope difference — v4 reads as "principles contained in mission" |

**Common pattern across these:** harvest_hearth is structured around brand values that are then implemented as concrete programs. A "brand value" label and its "implementing program" label are tightly paraphrased ("Repair and Resell" / "Hearth Again Program") but v4's scope-containment rule treats the brand value as a leaf inside the program umbrella.

This is the SAME asymmetric-scope-containment rewrite that fixed vitacare's umbrella↔umbrella over-merges (#4 and #8). On vitacare the rule correctly rejected "service catalog ↔ care philosophy"; on harvest_hearth the same rule incorrectly rejects "brand value ↔ implementing program."

## What v4 wins

- **All 11 stable v4 approvals are MUST-MERGE.** Precision 100%, zero traps in any stable approval, zero borderlines.
- v4's stable set is a strict subset of v3's stable set + 0 — every v4 stable merge is also a v3 stable merge.

So v4 is the **conservative subset** of v3: never wrong, but misses cases v3 would catch.

## Worst-case stability

v4's 4-trap worst run includes #38 (Product Lifecycle ↔ Customer Programs & Services — LEAF↔CATALOG, the exact failure mode v4 was supposed to fix). v3's 3-trap worst run includes #57 and #52 (Pay Fairly trap variants).

Both prompts hit traps at similar rates on harvest. The vitacare-style "v3 runaway, v4 calm" doesn't repeat — both produce ~20 approvals per run with similar precision floors.

## Cross-corpus summary

| Metric | vitacare (52 in-band) | harvest (106 in-band) |
|---|---|---|
| v3 stable approvals | 3 | 15 |
| v4 stable approvals | 3 | 11 |
| v3 stable precision | 100% | 93% |
| v4 stable precision | 100% | 100% |
| v3 stable recall | 100% (3/3) | 70% (14/20) |
| v4 stable recall | 100% (3/3) | 55% (11/20) |
| v3 worst-run approvals | 10 (runaway) | 24 |
| v4 worst-run approvals | 4 | 23 |
| v3 union approvals | 11 | 31 |
| v4 union approvals | 6 | 33 |
| v3 worst-run traps | 6 | 3 |
| v4 worst-run traps | 1 | 4 |

The vitacare pattern (v4 strictly stabilizes v3 without recall loss) inverts on harvest: v4 trades recall for precision/trap-rate, and the trade is meaningful.

## Decision

**Hold v4 as the default**, with explicit caveat that it is **conservative-biased**.

Rationale:

- v4 retains 100% precision on both corpora — never wrong in stable intersection. v3 is 93% (one stable trap on harvest).
- v4 retains 0% stable trap rate on both corpora. v3 has 10% on harvest.
- v4's recall loss on harvest is concentrated in brand-value ↔ implementing-program paraphrases — these are also catchable downstream (via exact-label match or future "same brand value" pattern). Easier to recover than wrongly-merged nodes.
- The vitacare-style "noise envelope" win — even if it doesn't generalize — is still real for vitacare-like corpora (chapter-style, hierarchy-rich content). Reverting to v3 to gain harvest recall would re-introduce vitacare's run-3 runaway problem.

**However, the published recommendation needs revising.** The v4 audit (`audits/2026-05-18_v4-prompt-experiment.md`) framed v4 as a clean noise-reduction win. That framing was generalized from one corpus. The corrected framing: **v4 is precision-biased; v3 is recall-biased; the right choice depends on the user's corpus type.** When extraction produces a hierarchy-rich corpus, v4 is the right default; when extraction produces a paraphrase-heavy brand-voice corpus, v3 is the right default.

## Open questions for follow-up

1. **v5 candidate?** A prompt that handles "brand value ↔ implementing program" as an explicit MERGE category (analogous to v4's "Regulatory subset") might recover the harvest recall without losing vitacare precision. Cheap to test (~$1) — would re-grade the harvest rubric against v5's stable set and the vitacare rubric against v5's stable set. Two-corpus A/B from the start.
2. **Stability-vs-recall tradeoff** is now a tunable, not a binary. Could expose `--adjudication-prompt-version=v3|v4` as a setting if real-world projects show one bias is wrong for them.
3. **Borderline pairs (9 of 39 union) are an unscored noise source.** A second-rater pass on those would tighten the precision/recall numbers — currently they swing the per-run reads by 2-6 points depending on whether v3 or v4 happens to include them.
4. The vitacare "regulatory subset" win (#11 SUD ↔ BH privacy) didn't have an analogous test here — harvest_hearth has no regulatory pattern. The "Regulatory subset" MERGE category in v4 isn't doing damage on harvest, but it isn't carrying its weight either.

## On-disk artifacts

| Path | What |
|---|---|
| `/tmp/atlas_snaps/harvest_postextract/` | Harvest baseline (4 per-doc graphs from post-extraction state) |
| `/tmp/atlas_snaps/pre_harvest/` | Empty (no graphs in dir before harvest extraction — test_proj had been removed) |
| `/tmp/atlas_sidecar_harvest_v{3,4}_run{1,2,3}_*.json` | 6 per-run sidecars |
| `/tmp/harvest_grading.txt` | Pretty-printed 39-pair union with labels + summaries used to hand-grade |
| `/tmp/harvest_union_pairs.json` | Programmatic view of the same union |
| `/tmp/atlas_score_harvest.py` | Scoring script — embeds the rubric inline; re-runnable |
| `/tmp/atlas_harvest_extract.log` | Empty (extraction logs to OSLog, not stdout) |
| `/tmp/atlas_run_harvest.sh` | Per-run helper |

The live graph in `Atlas/graphs/` was restored to `harvest_postextract` at end of sweep. Vitacare baseline files remain at `/tmp/atlas_snaps/postextract/` — recoverable if test_proj is recreated in the UI.
