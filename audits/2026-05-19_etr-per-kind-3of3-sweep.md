# ETR per-kind threshold split — 3-of-3 stability sweep (2026-05-19)

> **Pairs with:** `audits/2026-05-19_etr-per-kind-threshold-baseline.md` (mechanism verification + single-run baseline).
> **Branch:** `feature/etr-cross-doc` @ `4fb811a`.
> **Corpus:** `test_proj` (4 vitacare PDFs, 211 ETR-eligible nodes after the 12:38–12:49 fast extraction).
> **Backend:** Gemini 2.5 Flash adjudication, `gemini-embedding-2-preview` (3072-dim), new project Gemini API key, warm embedding cache (no fresh embed calls — `embeddings_C167BC85-…json` 7.6 MB, 211 vectors).
> **Cost:** ~$0.05 / run × 6 runs = ~$0.30.
>
> **TL;DR:** Tightening `conceptConcept` floor from 0.80 → 0.85 **hurts** on this corpus. Baseline stable-intersection (approvals in all 3 runs) = 3 pairs; cc=0.85 stable = 1 pair. The two pairs lost are a regulatory-subset cc pair (`Behavioral Health Privacy ↔ Substance Use Disorder Records`, 0.817) that aligns with v4's MERGE rules, and a cross-level pair lost to Flash noise rather than the cc threshold itself. No false-positives were avoided in the stable intersection — the suspect umbrella pair from yesterday's single-run (`Care Coordination ↔ Excluded Services`) was already filtered by Flash noise at flat 0.80 (it landed in only 1/3 baseline runs). **Recommendation: keep flat 0.80 as the cc default; per-kind machinery stays as a tuning tool for future corpora.**

## Method

Six `--etr-only` runs against the same warm-cache project graph, alternating between configs to keep the embedding cache and graph state stable across runs:

| Run | Config | Sidecar timestamp | Per-run approvals |
|---|---|---|---|
| base-1 | flat 0.80 | `07-22-19Z` | 12 |
| base-2 | flat 0.80 | `07-28-59Z` | 8 |
| base-3 | flat 0.80 | `07-29-58Z` | 7 |
| cc85-1 | cc=0.85, ee/cl=0.80 | `07-23-46Z` | 3 |
| cc85-2 | cc=0.85, ee/cl=0.80 | `07-33-43Z` | 1 |
| cc85-3 | cc=0.85, ee/cl=0.80 | `07-35-09Z` | 1 |

(Two earlier "cc85-2/3" runs in the sweep loop dropped the per-kind flags due to a bash function quoting quirk; their sidecars are present on disk but recorded `adjudicationFloorPerKind: nil`, so they were excluded from analysis. The three runs above all confirm `adjudicationFloorPerKind: { conceptConcept: 0.85 }` in their JSON.)

Method match with `audits/2026-05-18_v4-prompt-experiment.md`: stable intersection = pairs approved by Flash in *all three runs of the same config*; this is the regression-resistant signal that ignores Flash's per-run noise.

## Adjudication band size (mechanism check)

| Run | cc band | ee band | cl band | total |
|---|---|---|---|---|
| base-1 | 36 | 23 | 4 | 63 |
| base-2 | 33 | 18 | 5 | 56 |
| base-3 | 34 | 11 | 6 | 51 |
| cc85-1 | 1 | 18 | 5 | 24 |
| cc85-2 | 1 | 8 | 7 | 16 |
| cc85-3 | 1 | 8 | 7 | 16 |

The cc-band collapse (≈34 → 1) is consistent across all cc=0.85 runs — the per-kind override fires only on cc pairs as designed. Embedding-noise drift on ee/cl pairs near the 0.80 boundary explains the run-to-run jitter (23/18/11 ee in baseline, 18/8/8 in cc85; same vectors but the boundary is right where cosines are noisiest).

## Stable approvals (intersection across 3 runs of each config)

**Baseline stable (3 pairs):**

```
[0.883] ee  Patient Consent ↔ explicit patient consent
[0.817] cc  Behavioral Health Privacy ↔ Substance Use Disorder Records
[0.817] cl  Continuity matters ↔ Primary Care Model
```

**cc=0.85 stable (1 pair):**

```
[0.883] ee  Patient Consent ↔ explicit patient consent
```

**Δ:**
- Shared: 1 (the entity-entity `Patient Consent` pair — both configs agree, both Flash-stable).
- Lost: 2.
- Gained: 0.

### Loss analysis

1. **`Behavioral Health Privacy ↔ Substance Use Disorder Records` (cc, 0.817).** This is the one structurally explained by the cc threshold change — at floor 0.85 the pair never enters adjudication. Under v4's "Regulatory subset" MERGE rule this *should* merge: SUD privacy (42 CFR Part 2) is a stricter overlay on the general behavioral-health privacy regime. Losing this is a real recall hit.

2. **`Continuity matters ↔ Primary Care Model` (cl, 0.817).** Cross-level pair. The cl floor was unchanged at 0.80, so this pair was in adjudication in all 3 cc85 runs. Flash simply didn't approve it in all 3. This loss is **not** caused by the cc tightening — it's pure Flash noise. (Why it stably approved in baseline but flapped in cc85 with the same band: the cc=0.85 runs had ~3× fewer in-band pairs in the prompt, which may have changed Flash's framing; either way, not a structural threshold effect.)

### The umbrella false-positive from yesterday was already noise-filtered

The single-run baseline write-up flagged `Care Coordination and Referrals ↔ Excluded Services` (cc, 0.812) as a clear umbrella false-positive that cc=0.85 would prevent. The 3-of-3 reveal: that pair was approved by Flash in only 1 of 3 baseline runs (the original base-1). It was *not* in the baseline stable intersection — Flash already declined to merge it in runs 2 and 3 of baseline. So the "FP avoidance" credit cc=0.85 might have claimed on a single-run reading is unearned; baseline plus stability filtering handles it.

## Recall picture (union across runs)

| Config | Stable | Union | Avg per run |
|---|---|---|---|
| Baseline (flat 0.80) | 3 | 19 | 9.0 |
| cc=0.85 | 1 | 3 | 1.67 |

The cc=0.85 configuration removes 5–6× the approvals across the noise envelope, in addition to the 2 lost stable pairs. While the stable count is the regression-resistant metric, the union shrinkage tells us the cc band 0.80–0.85 is contributing real candidate volume, not just noise.

## Verdict

Per-kind threshold split is sound infrastructure and the cc=0.85 override fires precisely where it should. But on the test_proj corpus with v4 + Gemini Flash, cc=0.85 trades 1 stable-correct regulatory-subset merge for zero stable false-positives avoided — net negative.

Possible reasons cc=0.85 doesn't pay off here:

- **v4 already handles cc-band false-positives.** The "leaf-of-catalog" and "parallel regimes that share a noun" anti-patterns in v4 cover the umbrella-style FPs that cc-tightening would otherwise need to filter. The prompt is doing the discrimination the threshold would.
- **Flash noise already filters single-occurrence FPs.** Three runs with stable intersection naturally drops pairs that approved by accident, including the suspect `Care Coordination ↔ Excluded Services` pair.
- **The cc band has real MERGE signal at 0.80–0.85.** Specifically the regulatory-subset / cross-level conceptual overlap pairs that v4 is designed to catch.

Default stays at **flat 0.80** for cc. The per-kind override remains the right primitive — different corpora (especially brand-voice corpora like harvest_hearth where v4's recall is the weak axis) may want different per-kind floors. The harvest_hearth analog of this sweep is the natural follow-up.

## Open follow-ups

1. **Symmetric ee experiment.** Loosen `entityEntity` floor to 0.75 (`--adj-floor 0.80 --adj-floor-ee 0.75`) and re-run 3-of-3 against test_proj. Hypothesis: entity-entity pairs at 0.75–0.80 may include real paraphrase merges that the current floor excludes. Watch for false-positives among the new band.
2. **Re-run cc=0.85 against harvest_hearth.** If the harvest corpus has different cc-band dynamics (v4 has known recall weakness there per `audits/2026-05-18_v4-holdout-harvest-hearth.md`), the threshold tradeoff may flip.
3. **Bash sweep-script fix.** The `local extra_flags="$@"` pattern in the run_one function dropped the per-kind flag in 2/4 runs. Direct invocations (`--adj-floor 0.80 --adj-floor-cc 0.85` typed inline) worked every time. Don't rely on the wrapper for future sweeps; use a per-config invocation block instead.
4. **Carries from yesterday's audit:** `--mode fast --etr` exit-hang trace still open. Not touched today — every sweep run used `--etr-only` against the on-disk per-doc graphs from the 12:38–12:49 extraction.
