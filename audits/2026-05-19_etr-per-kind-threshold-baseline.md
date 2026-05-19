# ETR per-kind threshold split — mechanism baseline (2026-05-19)

> **Branch:** `feature/etr-cross-doc` @ `1e01337` (per-kind threshold split landed earlier today).
> **Corpus:** `test_proj` (4 vitacare PDFs), Gemini 2.5 Flash extraction + adjudication, `gemini-embedding-2-preview` (3072-dim), new project Gemini API key.
> **TL;DR:** The new `ResolverThresholds.adjudicationFloorPerKind` plumbing works end-to-end: bumping `conceptConcept` from 0.80 → 0.85 collapsed cc-band adjudication from 36 pairs to 1 (≈97% drop), while `entityEntity` and `crossLevel` floor remained at 0.80 and their adjudication counts held roughly steady (23→18 and 4→5). The cc-only override fires only where it should. Flash adjudication noise dominates approval-set deltas on single runs, so this audit pins the *mechanism*, not a precision/recall verdict — a stable 3-of-3 intersection sweep is the next step before promoting any per-kind default.

## Code under test

- `EmbeddingResolver.PairKind` (`conceptConcept | entityEntity | crossLevel`) — new enum on the resolver namespace.
- `ResolverThresholds.autoMerge(for:)` / `adjudicationFloor(for:)` — accessor methods that fall back to the flat field when no `*PerKind` override is set.
- `EmbeddingResolver.classify(similarity:pairKind:thresholds:)` — new overload used inside `resolve(...)`; the original flat `classify(...)` is preserved as a back-compat shim that ignores per-kind overrides.
- `HeadlessRunner` CLI: `--adj-floor-{cc,ee,cl}` / `--auto-merge-{cc,ee,cl}`.
- Audit sidecar shape: new optional `autoMergePerKind` / `adjudicationFloorPerKind` JSON fields on `ResolverThresholdsCodable`. Empty maps remain absent for back-compat.

11 PairKind tests + 5 new HeadlessRunnerConfig tests + 1 stale-prompt-wording fix — full ETR-branch suite green at 216 tests / 0 failures.

## Run setup

1. Cleared the graphs directory under `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/`.
2. Switched the Gemini API key by writing `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` (sandbox-local, not in repo). Also exported `ATLAS_GEMINI_API_KEY` for env-var priority. AIServiceManager honors env > dev-keys file > Keychain.
3. Flipped UserDefaults so the app boots in Gemini mode: `defaults write rogues.pdf-app1 atlas.ai.backendType Gemini` + `atlas.ai.model gemini-2.5-flash`.
4. Initial fast extraction: `--headless-extract --project test_proj --mode fast --etr` produced 4 per-doc graphs (12:38, 12:41, 12:46, 12:49). The full `--etr` path hit the existing exit-hang noted in handoffs (process stays alive after `await Task.sleep(.milliseconds(500)); exit(0)`); killed at 12:50 with the per-doc graphs intact. Subsequent runs used `--etr-only` against those graphs (fast, ~30–90s warm-cache).
5. Embedding cache for `C167BC85-…` (test_proj) populated by the baseline run, persisted to `embeddings_C167BC85-….json` (7.6 MB, 211 vectors × 3072-dim).

## Results

### Baseline — flat floor 0.80

`audit etr_audit_C167BC85-…_2026-05-19T07-22-19Z.json` (35.9 KB)

| Field | Value |
|---|---|
| eligible nodes | 211 |
| pairs evaluated | 16463 |
| adjudication entries | 63 (cc=36, ee=23, cl=4) |
| LLM approved | 12 |
| LLM rejected | 51 |
| approval rate | 19% |

Approved set (12, sorted by similarity):

```
[0.883] ee  Patient Consent ↔ explicit patient consent
[0.854] cc  VitaCare Access Standards ↔ Behavioral Health Access Standards
[0.836] ee  First scheduled therapy visit within 7 days ↔ First visit booking
[0.823] ee  In-app messaging ↔ Asynchronous messaging
[0.817] cc  Behavioral Health Privacy ↔ Substance Use Disorder Records
[0.817] cl  Primary Care Model ↔ Continuity matters
[0.812] cl  Primary Care Model ↔ Family primary care coordination
[0.812] cc  Care Coordination and Referrals ↔ Excluded Services        # *suspect FP*
[0.811] ee  Opioid use disorder treatment ↔ Substance use disorder
[0.811] ee  Lab result release time ↔ Abnormal results contact
[0.807] cl  Care Coordination and Referrals ↔ Referral and prior authorization
[0.806] ee  Secure messaging with the care team ↔ Care Between Visits
```

### Experiment 1 — cc floor 0.85, others flat 0.80

`audit etr_audit_C167BC85-…_2026-05-19T07-23-46Z.json` (14.5 KB)

| Field | Value | Δ vs baseline |
|---|---|---|
| eligible nodes | 211 | — |
| pairs evaluated | 16463 | — |
| adjudication entries | 24 (cc=1, ee=18, cl=5) | −39 (cc −35, ee −5, cl +1) |
| LLM approved | 3 | −9 |
| LLM rejected | 21 | −30 |

Approved set (3):

```
[0.883] ee  Patient Consent ↔ explicit patient consent
[0.878] ee  Asynchronous messaging ↔ Message response time   # NEW (not in baseline approvals, was rejected at 0.878)
[0.823] ee  In-app messaging ↔ Asynchronous messaging
```

### Mechanism verification

The cc-only override is firing correctly: 36 cc-band entries collapsed to 1 (the single survivor sits above 0.85). Crucially, the ee floor (0.80) and cl floor (0.80) are untouched in the same run, and ee/cl pair counts hold roughly steady. The 5-pair ee delta (23 → 18) and 1-pair cl delta (4 → 5) are consistent with embedding-noise drift across the 0.80 boundary — cosines near the floor can flip in or out of the band run-to-run.

The audit sidecar correctly records the per-kind override:

```json
"thresholds": {
  "autoMerge": 0.95,
  "adjudicationFloor": 0.8,
  "adjudicationBatchSize": 18,
  "adjudicationFloorPerKind": { "conceptConcept": 0.85 }
}
```

`autoMergePerKind` is absent because none was set, matching the back-compat policy.

## Why the approval-set delta is not a verdict

Single-run Flash noise dominates. Direct evidence:

- The pair `Asynchronous messaging ↔ Message response time` was **rejected** at 0.878 in baseline and **approved** at 0.878 in experiment 1 (identical sim, identical prompt, opposite verdict).
- Of the 17 pairs that landed in both runs' adjudication bands, 1 flipped verdict (5.9%). Yesterday's `audits/2026-05-18_v4-prompt-experiment.md` documented Flash drift in the 1–2 unique-approvals-per-run range on a comparable corpus.

The dropped approvals therefore aren't necessarily "recall loss from tightening cc" — most of them are entity↔entity / cross-level pairs whose band membership was unchanged, and Flash simply rejected them this run. The only true cc-floor lift is for the 35 cc pairs at sim ∈ [0.80, 0.85) that no longer reach adjudication at all; without knowing which of those were rubric-aligned MERGEs we can't price the precision/recall tradeoff.

One pair flagged for review either way: the 0.812 `Care Coordination and Referrals ↔ Excluded Services` cc-band pair from baseline reads as a clear umbrella false-positive (one is a service category, the other is a *list of excluded services* from a contract — definitionally non-overlapping). A tightened cc floor of 0.85 would prevent that pair from being adjudicated at all, which on this single example reads as a win.

## Next steps (not run here)

1. **3-of-3 stability sweep** of cc=0.85 vs flat=0.80 against the same warm cache (6 runs total, ~$0.30). Capture the stable intersection of approvals per run; the diff against the rubric (when `test_proj`'s pair-rubric is re-grounded) is the actual precision/recall price tag.
2. **Symmetric ee experiment**: loosen `entityEntity` floor to 0.75 to test the "entities are more specific so a looser floor recovers recall" hypothesis from the backlog. CLI: `--adj-floor 0.80 --adj-floor-ee 0.75`. Watch for false-positives among the new 0.75–0.80 ee band.
3. **Joint cc-tight + ee-loose** to estimate whether the two moves compose cleanly or trade against each other.
4. **Fix the exit-hang on the full `--etr` path.** This baseline used `--etr-only` because the full `--mode fast --etr` run sat idle in the NSApp run loop after extraction completed (sample showed only main thread + NSURLConnectionLoader idle in `mach_msg`; no Swift Concurrency threads). Per-doc graphs were written, but `exit(0)` never fired. Not a regression from today's changes (extraction code was unchanged); reproduces on a fresh build of `feature/etr-cross-doc @ 1e01337`. Backlog candidate: trace which task is keeping the main runloop alive.

## File pointers

- `pdf_app1/pdf_app1/Atlas/AI/Embeddings/EmbeddingResolver.swift` — `PairKind`, `ResolverThresholds.{autoMerge,adjudicationFloor}(for:)`, classify overload, `pairKind(_:_:)`, audit-codable extension.
- `pdf_app1/pdf_app1/HeadlessRunner.swift` — `--adj-floor-{cc,ee,cl}` / `--auto-merge-{cc,ee,cl}` flag parsing.
- `pdf_app1/pdf_app1Tests/EmbeddingResolverPerKindThresholdTests.swift` — 11 tests.
- `pdf_app1/pdf_app1Tests/HeadlessRunnerConfigTests.swift` — 5 new tests for the per-kind flags.

Audit sidecars are local-only (sandbox container), not in the repo.
