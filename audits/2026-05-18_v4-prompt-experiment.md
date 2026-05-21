# ETR v4 prompt — A/B vs v3 with 3-of-3 stability

> **Branch:** `feature/etr-cross-doc` (delegator restored to v2 in working tree).
> **Pairs with:** `audits/2026-05-18_rubric-v3-vitacare.md` (the scoring rubric); `audits/2026-05-18_v3-prompt-experiment.md` (the v3 baseline and the recommendation that produced v4); `PromptTemplates.swift` (`mergeAdjudicationV4` lives alongside v2 / v3).

## What v4 changes vs v3

Two targeted edits, both motivated by the v3 audit (`audits/2026-05-18_v3-prompt-experiment.md` §"What v3 still gets wrong" and §"What v3 gave up"):

1. **Leaf-of-catalog rule recast as asymmetric scope containment.** v3's rule fired when label B carried umbrella-style words ("overview", "model", "framework", "principles", "areas"); v4's rule fires whenever one side's scope is strictly inside the other's — explicitly including umbrella ↔ umbrella pairs where one umbrella is broader than the other. The trigger word list is retained as a hint but not the test; the test is scope containment.
2. **New MERGE category "Regulatory subset."** Names the pattern where one label is a regulatory regime and the other is a stricter subset of that regime layered on top (HIPAA ↔ SUD heightened protections under 42 CFR Part 2, GDPR ↔ minor-data overlay, baseline access controls ↔ regulated-class consent regime). Distinguishes itself from a new KEEP-SEPARATE pattern: "Parallel regimes that share a noun" (corporate-insurance ↔ patient-insurance, internal-audit ↔ external-audit).

Everything else from v3 — the handbook-bullet-test framing, all other MERGE/KEEP-SEPARATE patterns, the "prefer KEEP-SEPARATE on uncertainty" stance, the JSON-array output format — is unchanged.

## Test setup

- **Corpus / baseline / cache:** identical to `audits/2026-05-18_v3-prompt-experiment.md` — 4-doc vitacare fresh extraction, 214n / 405e, 185 eligible, 12,628 pairs, `/tmp/atlas_snaps/postextract` restored between every run, warm contentHash-keyed embedding cache (185/185 hit).
- **Floor:** 0.80 (52 in-band pairs).
- **Runs:** 3× v3 + 3× v4 = 6 runs total. Each run preceded by `restore postextract` so the input graph is byte-identical across runs.
- **Cost:** ~$0.60 total Gemini API spend (warm cache, 3 LLM batches × 6 runs).
- **Wall-clock:** 70-86s per run.
- **Rubric:** `audits/2026-05-18_rubric-v3-vitacare.md` — 3 MUST-MERGE (M), 43 MUST-REJECT (R), 5 borderline (B), 1 in-doc (X, excluded from scoring).

Pinned sidecars: `/tmp/atlas_sidecar_v{3,4}_run{1,2,3}_*.json`. Scoring script: `/tmp/atlas_score.py`.

## Headline

| | 3-of-3 stable | Single-run worst case | Single-run best case |
|---|---|---|---|
| **v3** | 3 approvals — **P 100%, R 100%, T 0.0%** | 10 approvals (run 3): P 30%, R 100%, T 14% | 4 approvals (runs 1, 2): P 75%, R 100%, T 2% |
| **v4** | 3 approvals — **P 100%, R 100%, T 0.0%** | 4 approvals (all runs): **P 75%, R 100%, T 2%** | 4 approvals (all runs): **P 75%, R 100%, T 2%** |

P = Precision = (must-merge approvals) / (total approvals)
R = Recall = (must-merge approvals) / 3
T = Trap rate = (must-reject approvals) / 43

**v4 ties v3 on the stable intersection and wins decisively on worst-case stability.** v4's three runs are byte-stable on approval count (4 each); v3's runs swing from 4 to 10. v4's union of approvals across 3 runs is 6 pairs; v3's union is 11 pairs (a 45% smaller noise envelope).

## Per-run breakdown

| Prompt | Run | Approvals | Must-merge caught | Must-reject tripped | In-doc | Eyeball |
|---|---|---|---|---|---|---|
| v3 | 1 | 4 | #3, #11, #45 | #13 | — | one borderline trap |
| v3 | 2 | 4 | #3, #11, #45 | #10 | — | one borderline trap |
| v3 | 3 | 10 | #3, #11, #45 | #2, #4, #13, #17, #19, #38 | #6 | runaway: 6 umbrella/philosophy traps + in-doc leak |
| v4 | 1 | 4 | #3, #11, #45 | #19 | — | one borderline trap |
| v4 | 2 | 4 | #3, #11, #45 | #13 | — | one borderline trap |
| v4 | 3 | 4 | #3, #11, #45 | #4 | — | one borderline trap |

**The 3 stable approvals across all 6 runs are the same pairs:**
- #3 Corporate & Provider Compliance ↔ Legal Structure & Clinical Services (paraphrase)
- #11 SUD Record Protections ↔ Behavioral Health Record Privacy (regulatory subset)
- #45 Consent Framework ↔ Behavioral Health Record Privacy (partial overlap)

**Stable rejection rate** (pairs rejected in all 3 runs) = 46/52 for v4 vs 41/52 for v3. v4 is meaningfully more decisive.

## Pair-by-pair flapping (approved in some but not all runs)

### v3 flapping (8 pairs)

| Pair | Category | Pattern across runs 1/2/3 |
|---|---|---|
| #2  Service Model ↔ Network Overview | R (umbrella↔umbrella) | 0/0/1 |
| #4  Service Model ↔ Care Model & Cultural Principles | R (umbrella↔umbrella) | 0/0/1 |
| #6  in-doc compliance↔compliance | X (excluded) | 0/0/1 — **also a code-path leak; flag separately** |
| #10 External Partners ↔ On-site Services | R (internal/external) | 0/1/0 |
| #13 Telehealth SLA ↔ Operating Hours | R (different scope) | 1/0/1 |
| #17 Cultural Principles ↔ Primary Care Mgmt | R (philosophy↔service) | 0/0/1 |
| #19 Core Care Principles ↔ Primary Care Mgmt | R (philosophy↔service) | 0/0/1 |
| #38 Strategic Partnerships ↔ On-site Services | R (different scope) | 0/0/1 |

### v4 flapping (3 pairs)

| Pair | Category | Pattern across runs 1/2/3 |
|---|---|---|
| #4  Service Model ↔ Care Model & Cultural Principles | R (umbrella↔umbrella) | 0/0/1 |
| #13 Telehealth SLA ↔ Operating Hours | R (different scope) | 0/1/0 |
| #19 Core Care Principles ↔ Primary Care Mgmt | R (philosophy↔service) | 1/0/0 |

v4's 3 flapping pairs are a strict subset of v3's "common single-trip" failure modes — no runaway behavior, no in-doc leak.

## Headline correction to the v3 audit

The v3 audit (`audits/2026-05-18_v3-prompt-experiment.md` #6) called pair #11 (SUD ↔ BH privacy) "a real loss — dropped" with the inference that v3 systematically misses regulatory-subset relationships. **Across 3 fresh v3 runs in this session, v3 caught #11 in all 3 runs.** So:

- The original v3-vs-v2 audit was based on a single v3 run (the pinned `/tmp/atlas_sidecar_v3_080_20260518T131220.json`); that single run happened to reject #11.
- In a 3-of-3 read, v3 has the same stable recall as v4 on #11.
- This does NOT make v4's "Regulatory subset" MERGE category redundant — v4 still gives the model a more explicit reason to accept the pair, which contributes to lower noise on the broader set of pairs. But the prior framing of "v4 recovers a lost merge" should be replaced with "v4 stabilizes the same merge v3 was already catching most of the time."

## In-doc pair leak (separate finding, severity: medium)

Pair #6 (compliance: VitaCare Overview & Governance ↔ compliance: Company Identity — both in the same doc) appeared in the in-band 52 of the rubric source sidecar, and was approved by v3 run 3. The current backlog implies `pairsToCompare` is cross-doc-only; this is evidence that some in-doc pairs leak through, and at floor 0.80 they enter the LLM adjudication band.

Worth a dedicated audit: trace the path that brings same-doc pairs into the resolver pipeline. Could be benign (acceptable in-doc dedup) or a real bug (the cross-doc filter not applied in the project-wide pass). Flagged in backlog as a new item.

## Recommendation

**Flip the public delegator to v4** as the published prompt.

- Strict win on worst-case stability (3 vs 10 max approvals across 3-run sample).
- Strict win on union approval count (6 vs 11) — half the noise envelope.
- Identical 3-of-3 stable behavior, so no regression risk on the rubric.
- The "asymmetric scope containment" rewrite is corpus-neutral; the explicit "Parallel regimes that share a noun" anti-pattern strengthens the existing v2/v3 separation between corporate-insurance and patient-insurance (rubric reject pair #1's analogues).

A one-line change at `PromptTemplates.swift:409`:
```swift
return mergeAdjudicationV4(pairs: pairs)
```

If a holdout corpus is run before flipping (the `harvest_hearth` corpus in `audits/2026-05-16_etr-step1-plan.md`), defer the flip; otherwise the in-corpus 3-of-3 gain is enough to ship.

## Limitations carried over

- **Single-corpus.** All scoring is vitacare. Behavior on `harvest_hearth` not measured.
- **In-band only.** Pairs at similarity < 0.80 not surfaced.
- **3-run stability is the minimum** for noise reduction — does not guarantee 30-run stability.
- **In-doc leak excluded from precision/recall** but quantified separately. v3 hit #6 once; v4 never did.

## On-disk artifacts

| Path | What |
|---|---|
| `/tmp/atlas_snaps/postextract/` | Baseline 4-doc graph (unchanged from prior session) |
| `/tmp/atlas_snaps/pre_v4_sweep/` | Snapshot of live graph immediately before this sweep (post-v3 ETR state from prior session) |
| `/tmp/atlas_sidecar_v3_run{1,2,3}_*.json` | The 3 v3 sidecars from this sweep |
| `/tmp/atlas_sidecar_v4_run{1,2,3}_*.json` | The 3 v4 sidecars from this sweep |
| `/tmp/atlas_sidecar_v3_080_20260518T131220.json` | Original v3 sidecar used to build the rubric |
| `/tmp/atlas_etr_v{3,4}_run{1,2,3}.log` | Per-run app stdout/stderr |
| `/tmp/atlas_score.py` | Scoring script — re-runnable to reproduce this table |
| `/tmp/atlas_label_dump.txt` | Decoded label dump of the 4 baseline graph files (used to design the rubric) |
| `/tmp/atlas_run_etr.sh` | Per-run helper: restore baseline → run → pin sidecar |

Live graph in `Atlas/graphs/` was restored to `postextract` at the end of the sweep. To re-run from clean: `/tmp/atlas_etr_sweep.sh restore postextract`.
