# ETR on Gemini 3.1 Pro — vitacare

**Date:** 2026-05-18 17:55–18:05
**Branch:** `feature/etr-cross-doc` (HEAD `4b5b113`); two uncommitted changes during the sweep — `PromptTemplates.swift` delegator flipped v4→v5 (reverted after scoring) and `HeadlessRunner.swift` gained a 5-line env-var-gated model override (kept for commit).
**Cost:** ~$0.30–0.50 Gemini Pro 3.1 (estimated — 18 calls @ ~15k input + variable output).
**Status:** Closes the open question "does Pro change the ETR picture?" Answer: **yes, dramatically — Pro collapses all prompt-iteration noise on vitacare.**

## TL;DR

On Pro 3.1, **v4 and v5 produce byte-identical, perfectly deterministic output** across 3 runs each on the vitacare baseline. Both prompts approve exactly the same 3 pairs (all 3 MUST-MERGE rubric pairs: #3, #11, #45). Zero MUST-REJECT trips. Zero borderline approvals. Zero union flapping. The prompt distinction that mattered on Flash — v4 precision-biased vs v5 noisy — disappears entirely. Pro fixes v5's vitacare-risk concern that broke today's v4→v5 promotion path.

## Setup

- Baseline: same 4-doc vitacare graphs from `/tmp/atlas_snaps/postextract/` used for every vitacare ETR run today (214n / 405e / 185 eligible).
- Model override path: added `ATLAS_GEMINI_MODEL` env-var-gated override in `HeadlessRunner.run()` (5 lines, after the `aiService.isConfigured` check). When set, replaces `aiService.selectedModel` after preferences load. Production unaffected.
- 6 runs total: v4 ×3 + v5 ×3, every run preceded by `atlas_etr_sweep.sh restore postextract` (baseline reset).
- Delegator flipped v4→v5 between the two sweeps, build green, reverted to v4 after scoring (clean — `git diff` shows zero change on `PromptTemplates.swift`).

## Raw results

| Run | Model | Prompt | Approved | M caught | R tripped | Wall-clock |
|---|---|---|---|---|---|---|
| v4_pro run 1 | Pro 3.1 | v4 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 70s |
| v4_pro run 2 | Pro 3.1 | v4 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 81s |
| v4_pro run 3 | Pro 3.1 | v4 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 72s |
| v5_pro run 1 | Pro 3.1 | v5 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 76s |
| v5_pro run 2 | Pro 3.1 | v5 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 93s |
| v5_pro run 3 | Pro 3.1 | v5 | 3/52 | 3/3 (#3, #11, #45) | 0/43 | 77s |

Sidecars pinned at `/tmp/atlas_sidecar_v{4,5}_pro_run{1,2,3}_*.json`.

Per-batch latency: 17–26s for 18-pair adjudication on Pro vs 5–10s on Flash. UX cost is real for live runs but irrelevant for headless sweeps.

## Stable + worst-case + union

| Variant | Stable P / R / T | Worst-case trap | Union (instability) |
|---|---|---|---|
| Flash v4 (today) | 100 / 100 / 0 | 0/43 | 6 unique |
| Flash v5 (today) | 100 / 100 / 0 | **3/43** (#17, #19 in run 3) | 10 unique |
| **Pro v4 (this run)** | 100 / 100 / 0 | **0/43** | **0** |
| **Pro v5 (this run)** | 100 / 100 / 0 | **0/43** | **0** |

Pro doesn't just reduce noise — it **eliminates** it. Union = stable = 3 for both prompts, both fully deterministic across 3 runs.

## Interpretation

1. **Pro fixes v5's substitution-test discriminator.** The failure mode that tripped #17 and #19 on Flash run 3 was "the rule is correct but the LLM sometimes misapplies it." Pro applies the rule reliably. v5's brand-value↔canonical-implementation MERGE category is viable on Pro where it wasn't on Flash.
2. **v4 and v5 converge on Pro.** Same 3 approvals, same response patterns. The "v4 precision-biased, v5 ambitious" distinction is a Flash-only phenomenon — at Pro's reasoning quality, the prompts don't pull in meaningfully different directions on this corpus.
3. **Pro changes the per-run cost-benefit of multi-run averaging.** On Flash today, 3-run stable intersection was the only way to filter noise from real signal. On Pro, **one run is sufficient** because there's no noise to filter. So Pro's ~13× higher per-call cost is partially offset by needing fewer runs for verification (3× fewer for stable reads).
4. **The harvest_hearth picture is now ambiguous.** Today's holdout (v3 wins recall, v4 wins precision, v5 marginal) was a Flash result. If Pro collapses prompt distinctions on harvest the same way it did on vitacare, the morning's "per-project prompt selection" backlog item becomes much less interesting — Pro + any prompt might dominate.

## What changes in the backlog

- `[next 2026-05-18] Per-project ETR prompt selection (v3|v4|v5)` becomes lower priority. Should be re-evaluated after a Pro-on-harvest test (~$0.40, not done in this session).
- New entry worth logging: **ETR-on-Pro harvest holdout** — does Pro also collapse prompt distinctions on the brand-voice corpus? If yes, the prompt iteration arc is functionally complete and the production question becomes "Pro vs Flash per-run cost-benefit" rather than "which prompt."
- New entry worth logging: **production model-selection decision for ETR** — Flash works well at ~$0.03/run with v4; Pro is deterministic at ~$0.40/run with any prompt. User-facing prefs already have a model picker; default model for ETR-only could differ from extraction default.

## What did NOT change

- v4 is still the public delegator for ETR adjudication on Flash. No reason to change it; v4 is already perfect-stable on Flash for vitacare and precision-leading on harvest.
- The Pro 3.1 default is **not** committed for ETR. The env-var override (`ATLAS_GEMINI_MODEL`) is kept as a sweep affordance — production model selection remains via the user's saved preferences.

## Production model recommendation

Use whatever model the user picks in Settings. For dev/research sweeps, prefer Pro 3.1 — 1 deterministic run replaces 3 Flash runs and the absolute Pro cost is still <$1 per sweep. For prod usage where extraction happens once and adjudication wall-clock matters for UX, Flash is fine (and 13× cheaper per call).

## Reproduction

```sh
# Prereqs: test_proj exists in UI with 4 vitacare PDFs; Atlas app quit.
# HeadlessRunner.swift must contain the ATLAS_GEMINI_MODEL override (5 lines).
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v4_pro 1
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v4_pro 2
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v4_pro 3
# Flip delegator to mergeAdjudicationV5, rebuild
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v5_pro 1
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v5_pro 2
ATLAS_GEMINI_MODEL=gemini-3.1-pro-preview /tmp/atlas_run_etr.sh v5_pro 3
python3 /tmp/atlas_score_pro_vitacare.py
# Revert delegator to v4. ATLAS_GEMINI_MODEL override stays in HeadlessRunner.
```
