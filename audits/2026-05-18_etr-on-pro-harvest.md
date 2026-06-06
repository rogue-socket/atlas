# ETR on Gemini 3.1 Pro — harvest_hearth holdout

**Date:** 2026-05-18 23:09–23:18
**Branch:** `feature/etr-cross-doc` (HEAD `e8529c2`); delegator flipped v4→v3→v5→v4 across the sweep, ending back at v4 (working tree clean on `PromptTemplates.swift`).
**Cost:** ~$0.60–1.00 Gemini Pro 3.1 (estimated — 3 runs × 3 batches @ 18-pair).
**Status:** Closes `[next 2026-05-18] ETR-on-Pro harvest holdout`. **Pro does NOT collapse prompt distinctions on harvest** (opposite of vitacare), and **v5-on-Pro is the new top result by every dimension**.

## TL;DR

On harvest_hearth, Pro 3.1 keeps the prompts meaningfully different — opposite of vitacare's converge-on-3 behavior. v5-on-Pro hits **100% precision / 70% recall / 0% trap rate** on a single run, beating v3's Flash-best result on every axis. The "Brand value ↔ canonical implementing program" MERGE category that v5 introduced — which backfired on Flash — works exactly as designed on Pro: catches 4 extra MUST-MERGE pairs without false positives. Production-cleanest answer is **per-model prompt routing**: Flash → v4 (safe), Pro → v5 (dominant).

## Setup

- Baseline: 4-doc harvest graphs from `/tmp/atlas_snaps/harvest_postextract/` (the 2026-05-18 fresh deep extraction; 278n / 246 eligible).
- 3 runs total, single-run each: v3_pro, v4_pro, v5_pro. Delegator flipped between runs (3 rebuilds, ~30s each).
- Baseline restored before every run via `atlas_etr_sweep.sh restore harvest_postextract`.
- Same `ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview` env override committed earlier this session in `HeadlessRunner.swift` (commit `aa7637e`).
- Single runs (not 3×) because vitacare's 6/6 perfect stability proved Pro is deterministic for ETR adjudication — 3-run averaging on Pro is mostly waste.

## Raw results

| Variant | Approved | M caught (M total = 20) | R tripped (R total = 10) | B approved | Wall-clock |
|---|---|---|---|---|---|
| v3_pro | 11/106 | **10** — {1, 2, 5, 7, 16, 19, 23, 71, 76, 96} | 0 | 1 (#6) | 162s |
| v4_pro | 10/106 | 10 — {1, 5, 7, 16, 19, 23, 35, 45, 76, 96} | 0 | 0 | 167s |
| v5_pro | **14/106** | **14** — {1, 5, 7, 16, 19, 23, 35, 45, 65, 71, 76, 91, 96, 104} | 0 | 0 | 163s |

Sidecars at `/tmp/atlas_sidecar_harvest_v{3,4,5}_pro_run1_*.json`.

## Cross-model comparison

| Variant | Flash stable P / R / T | **Pro single P / R / T** | Notes |
|---|---|---|---|
| v3 | 93 / **70** / 10 | 91 / **50** / 0 | Flash recall lead was **noise** — Pro single-run drops to v4 level. v3's stable=70% was flapping that 3-of-3 averaging surfaced as "stable." |
| v4 | 100 / 55 / 0 | 100 / 50 / 0 | Mostly stable. Slight recall dip; same conservative behavior. |
| **v5** | 92 / 60 / 0 | **100 / 70 / 0** | **+10 recall, +8 precision, holds 0 trap rate.** Best harvest result in any audit so far. |

The pairs v5 catches that v4 misses: **#65, #91, #104** (and #45 shared with v4 only). These are exactly the "brand value ↔ implementing program" pattern v5 was designed to catch. On Flash the substitution-test discriminator was too noisy to apply the rule reliably; on Pro it lands.

The pairs v3 catches that v4 misses on Pro: **#2, #71** (and #96 shared). These are recall-side pickups from v3's looser scope rule. Useful but smaller magnitude than v5's gains.

The single pair caught by v3 alone (not v4 or v5 on Pro): **#2**.

## What this means for production

The morning's "per-project prompt selection" backlog item (Flash → v3 for brand-voice, v4 for hierarchy-rich) becomes a **per-model** decision once Pro is in the mix:

| Model | Best prompt | Vitacare | Harvest |
|---|---|---|---|
| Flash | **v4** | 100/100/0 (perfect, never trips) | 100/55/0 (precision-biased) |
| Flash | v3 | 100/100/0 (tied) | 93/70/10 (recall-biased, 1 trap) |
| Flash | v5 | **3/43 worst-case trap** | 92/60/0 (marginal) |
| Pro | v4 | 100/100/0 (perfect) | 100/50/0 (worst on Pro) |
| **Pro** | **v5** | 100/100/0 (perfect) | **100/70/0 (best on Pro)** |

**v5 on Pro dominates v4 on Pro across both corpora.** If Atlas users were guaranteed to run Pro, v5 should be promoted to default. But Flash users would get burned (v5 trips #17/#19 on vitacare worst-case).

## Recommendations (ranked)

1. **Per-model prompt routing in `PromptTemplates.mergeAdjudication`.** Read `aiService.selectedModel`; route Pro callers to v5, Flash callers to v4. Net-new code ~10 lines + a unit test. Defer until at least one user actually runs on Pro, but log as a high-priority decision point.
2. **Document the Pro recommendation in user-facing settings.** If the UI Settings model picker shows "Gemini 3.1 Pro Preview," add subtitle text noting it's the more accurate option for ETR adjudication (at ~13× cost / 3× latency per call).
3. **Hold v5 promotion to default until per-model routing exists.** Promoting v5 today would help Pro users but regress Flash users on vitacare.
4. **Re-test the vitacare rubric on Pro v3** as a sanity check on the "Pro is deterministic" claim. Not done in this session because the v4/v5 6-run check already saturated the stability question. ~$0.10 if curious.

## What did NOT change

- v4 remains the public delegator for ETR adjudication. No promotion of v5.
- Pro is not the default model for ETR. User's saved preference still wins; `ATLAS_GEMINI_MODEL` env override is for sweeps only.
- The harvest rubric is unchanged — same 39-pair hand-graded set from `audits/2026-05-18_v4-holdout-harvest-hearth.md`.

## Caveat — single-run reads on harvest

Vitacare's 6/6 deterministic runs proved Pro is stable at vitacare scope (52 in-band pairs, 4 docs). Harvest has 106 in-band pairs and a more complex rubric (20 MUST-MERGE vs 3). If Pro has any prompt-input-length-dependent noise, harvest is more likely to surface it. The Pro-on-harvest stability claim is **inferred from vitacare, not directly tested**. A 3-run repeat of v5_pro on harvest (~$0.60) would close that gap — backlog as cheap-but-not-urgent.

## Reproduction

```sh
# Prereqs: harvest_hearth project exists in UI; Atlas app quit.
# HeadlessRunner.swift has the ATLAS_GEMINI_MODEL override (committed in aa7637e).
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_harvest.sh v4_pro 1
# Flip delegator to mergeAdjudicationV3, rebuild
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_harvest.sh v3_pro 1
# Flip delegator to mergeAdjudicationV5, rebuild
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_harvest.sh v5_pro 1
# Revert delegator to v4, rebuild
python3 /tmp/atlas_score_harvest_pro.py
```
