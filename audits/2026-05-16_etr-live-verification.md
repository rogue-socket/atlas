# ETR Live Verification — vitacare 2026-05-16

> **Branch:** `feature/etr-cross-doc` at `099a873` (10 ahead of `main`, not pushed at time of writing; current status 2026-05-26: synced to `origin/feature/etr-cross-doc` at `fa0bce9`)
> **Corpus:** vitacare 4-PDF project (test_proj), pre-existing extraction at 246n / 753e
> **Authority:** PRD §"Quality Rubric — vitacare 2026-05-16" (same branch, `099a873`)
> **Companion docs:** `2026-05-16_etr-step1-status.md` (decisions), `2026-05-16_etr-step1-plan.md` (file-touch list)

## Headline

ETR shipped end-to-end and ran cleanly on real data. **Two semantic cross-doc merges landed (both correct under the rubric; 0 false positives).** Recall against the 12 strong-merge rubric pairs is ~17% with default thresholds — the adjudication floor (0.85) appears too high for vitacare's heterogeneous label phrasing. Worth a tuning sweep before declaring a verdict.

Bonus finding: `GraphMergeEngine` (Levenshtein cross-doc dedup) is **dormant code** in the active app — its only caller (`MergeProposalView`) is never instantiated. Integration decision #2 ("disable `GraphMergeEngine` during A/B runs") is a no-op. Cross-doc merges attributed to it in prior session wraps actually came from `KnowledgeGraph.node(matching:)` doing exact-label dedup inside the shared project graph.

## Setup

- Built `pdf_app1.app` at `pdf_app1-giytzhghgxnvaderrgxenmypwjxy/Build/Products/Debug/pdf_app1.app`, 2026-05-16 14:51.
- Gemini key at `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json`.
- Embedding backend defaults: Gemini, `gemini-embedding-2-preview`, 3072-dim (confirmed via UserDefaults).
- LLM backend: Gemini (same key) for adjudication.
- `GraphMergeEngine` not active (dormant — see above).
- Pre-ETR project graph backed up to `/tmp/atlas_project_pre_etr_2026-05-16.json` for diffing.

## Run 1 — cold cache

Command: `./pdf_app1 --headless-extract --project test_proj --etr-only`

```
Pre-graph              : 246n / 753e
Eligible (concept+entity): 218 nodes
Cache state            : 0 hits / 218 misses (cold start)
Embedding API calls    : 3 batches (100 + 100 + 18) via Gemini batchEmbedContents
Embedding wall-clock   : 6.4s
Cache file written     : 8.57 MB at Atlas/graphs/embeddings_<projectID>.json
Pairs evaluated        : 17,810 cross-doc (out of 23,653 possible; cross-doc filter ~25%)
Pairwise cosine        : ~5.7s
Auto-merge band (≥0.95): 0
Adjudication band      : 5 candidates → 1 LLM batch → 2/5 approved
Apply result           : 2 groups, 2 nodes removed, 7 edges rewritten, 2 deduped
Post-graph             : 244n / 750e
Total wall-clock       : ~22s
```

## Run 2 — warm cache (convergence check)

Same command, no flag changes.

```
Pre-graph              : 244n / 750e (post-run-1 state)
Eligible               : 216 nodes
Cache state            : 216 hits / 0 misses (whole-file invalidation passed)
Cache file after save  : 8.49 MB (218 → 216 entries — 2 orphans cleaned)
Pairs evaluated        : 17,588
Adjudication band      : 3 candidates → 1 LLM batch → 0/3 approved
Apply result           : 0 changes
Post-graph             : 244n / 750e (converged)
Total wall-clock       : ~13s
```

**Validated properties:**

| Property | Result |
|---|---|
| End-to-end pipeline works on real data | ✅ |
| Embedding cache hit on rerun | ✅ 216/216 |
| Orphan cleanup before save | ✅ 218 → 216 |
| Idempotent (graph converges) | ✅ |
| Whole-file model/dim invalidation guard | not tested live; covered by unit test |
| Per-entry contentHash invalidation | not tested live; covered by unit test |
| Tuning loop is cheap | ✅ 13s warm vs 22s cold (and vs ~minutes for full re-extract) |

## What ETR actually merged

Diffed `/tmp/atlas_project_pre_etr_2026-05-16.json` against the post-ETR file on disk:

**Merge 1 — Lab result timing**

| Field | Loser (removed) | Canonical (survivor) |
|---|---|---|
| Doc | vitacare_patient_experience_and_operations.pdf | vitacare_clinical_services_and_pricing.pdf |
| Label | "Lab result release: typically within 24 hours of completion" | "same-day or next-day results" |
| Level | entity | entity |
| Summary | "The standard timeframe for releasing lab results to patients after completion." | "The typical timeframe for receiving results from most routine lab tests." |

Both describe the same real-world thing — the timing of lab result delivery to patients — from operations-SLA and clinical-services vantages. ✅ Good merge.

**Merge 2 — Asynchronous messaging**

| Field | Loser | Canonical |
|---|---|---|
| Doc | vitacare_patient_experience_and_operations.pdf | vitacare_clinical_services_and_pricing.pdf |
| Label | "In-app messaging: response within 6 business hours, typically much faster" | "Asynchronous messages" |
| Level | entity | entity |
| Summary | "A patient support channel offering responses to messages within 6 business hours, often sooner." | "Clinician responses to asynchronous messages are provided within 6 business hours, often faster." |

Identical SLA (6 business hours), identical service. ✅ Good merge.

## Baseline (without ETR)

The pre-ETR project graph already had **2 cross-doc shared nodes** — both via exact-label match during shared-project extraction (`KnowledgeGraph.node(matching:)`), not via `GraphMergeEngine`:

| Label | Across |
|---|---|
| "Clinic hours are 7:30 AM - 7:00 PM Monday through Friday and 8:00 AM - 2:00 PM on Saturdays" | ORG + OPS |
| "Video visits" | CLI + OPS |

**Total cross-doc shared after ETR: 4 nodes (2 exact-label + 2 ETR semantic).**

## Comparison vs SCE

SCE Run 2 (prior session, `feature/sce-cross-doc` at `8c69c32`):
- 137 cross-doc edges (vs 4 in pre-SCE baseline — 33× lift)
- 2 cross-doc shared nodes (unchanged from baseline)

ETR run (this session):
- 0 new cross-doc edges (ETR doesn't propose edges)
- 2 new cross-doc shared nodes (+100% over baseline)

**Design prediction confirmed:** SCE wins on edges (the LLM proposes relationships with prior-doc context); ETR wins on node merges (embedding semantics bridge what exact-string-match misses). Combining the two — letting SCE seed edges then running ETR for node dedup — is the natural production shape, not picking a winner.

## Scoring against the rubric

PRD's 12 strong-merge cross-doc pairs (excluding the 5 in-doc rows ETR skips by design + 8 anti-examples cross-referenced for table self-documentation):

| Rubric row | Pair | ETR outcome |
|---|---|---|
| 1 | CLI "Labcorp or Quest Diagnostics" ↔ CMP "Business Associate Agreements" (implicit) | ❌ not merged (BAA reference is implicit; weak embedding signal expected) |
| 4 | ORG "Dr. Helena Vargas" ↔ CMP "Privacy Officer" | ❌ not merged (correctly — Helena is CCQO, Privacy Officer is a distinct role; rubric framing was generous) |
| 8 | OPS "care coordinator matches..." ↔ CLI "referral and prior authorization handled by VitaCare care coordinators" | ❌ not merged |
| 9 | OPS "Lab result release" ↔ CLI "Lab Result Communication" (concept) | ⚠️ partial — ETR merged the OPS side, but with "same-day or next-day results" (entity) not "Lab Result Communication" (concept). Same real-world theme. |
| 12 | CLI "MRI, CT, mammography" ↔ CLI "affiliated imaging centers" | ⏭ in-doc — ETR cross-doc-only skips |
| 19 | OPS "Specialist visit (VitaCare specialty)" ↔ CLI "Specialty Care Services" | ❌ not merged |
| 20 | CLI "discounted specialty services" ↔ OPS "Specialist visit" | ❌ not merged |

Strict scoring on 6 cross-doc strong-merge pairs (excluding the in-doc row 12):
- **Precision: 2/2 = 100%** (both ETR merges are sensible; neither hits the anti-example list)
- **Recall: ~1/6 ≈ 17%** (row 9 partial credit; 5 false negatives)
- **F1: ~0.29**

**Bonus:** ETR's 2 merges weren't in the rubric at all (the rubric didn't list "Lab result release ↔ same-day or next-day results" or "In-app messaging ↔ Asynchronous messages"). These are *legitimate* cross-doc merges the rubric author missed. Rubric v2 should be expanded with these.

## Diagnosis: why recall is low

Several strong-merge rubric pairs use very different surface labels for the same concept:
- "MRI, CT, mammography" (specific modalities) vs "affiliated imaging centers" (the facility type) — likely embedding sim ~0.5-0.7
- "Specialist visit (VitaCare specialty)" vs "Specialty Care Services" — likely ~0.75-0.85

These land *below* the 0.85 adjudication floor, so the LLM never sees them. ETR's 2 successful merges had near-identical phrasing in the SLA wording (6hr, 24hr) which embeds close.

**Hypothesis:** lowering `--adj-floor` to ~0.70 would surface more candidates and let the LLM filter them, increasing recall at the cost of more LLM batches (linear in candidate count). Precision should stay high since the LLM is the gatekeeper. **Worth the next tuning sweep.**

## Tuning sweep recommendation (next session)

```bash
# Baseline already captured above (defaults: auto-merge 0.95, adj-floor 0.85)
# Each run is ~13s warm-cache; the embed cost is amortized.

./pdf_app1 --headless-extract --project test_proj --etr-only --adj-floor 0.80
./pdf_app1 --headless-extract --project test_proj --etr-only --adj-floor 0.75
./pdf_app1 --headless-extract --project test_proj --etr-only --adj-floor 0.70
```

For each run, diff post-graph against pre-graph, log:
- Candidates in band, LLM approval rate
- New merges (label A → label B)
- Score against rubric

**Caveat about cumulative state:** running these sequentially mutates the graph each time, so candidate sets shift between runs (already converged candidates can't reappear). For a clean sweep, restore `/tmp/atlas_project_pre_etr_2026-05-16.json` between runs:

```bash
cp /tmp/atlas_project_pre_etr_2026-05-16.json \
   ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/project_ABE6D4F9-7F9E-4BD8-B977-57D541824DF3.json
# Also wipe embedding cache to force a clean run, OR keep it for the cache-hit speed
```

## Followups & corrections to prior docs

1. **`GraphMergeEngine` is dormant.** Prior session wraps (2026-05-16) attributed the 2 cross-doc shared nodes to "GraphMergeEngine (Levenshtein > 0.5)". That's wrong. `MergeProposalView` is never instantiated, so `executeMerge` never runs. The 2 shared nodes come from `KnowledgeGraph.node(matching:)`'s case-insensitive exact-label match inside the shared project graph. Worth updating the lock-in notes in `2026-05-16_etr-step1-status.md` and the integration decisions in `prds/2026-05-15_4-level-knowledge-graph.md`.

2. **Rubric should be expanded.** The 2 merges ETR actually found (lab-result-timing pair + async-messaging pair) are valid cross-doc merges that the rubric didn't list. v2 should pre-walk the actual extraction more thoroughly.

3. **In-doc pair scope deserves reconsideration.** 5 of 12 strong-merge rubric rows are in-doc concept↔entity pairs that ETR cross-doc-only skips by design. Adding in-doc support (one-line filter change in `pairsToCompare`) would close that gap, but expands LLM adjudication cost.

4. **Branch push status changed after this doc.** At time of writing both `feature/sce-cross-doc` and `feature/etr-cross-doc` were local-only. Current status 2026-05-26: both are synced to origin (`4810d41` and `fa0bce9` respectively); remote A/B comparison is no longer blocked on pushing.

## On-disk state after this session

- `project_ABE6D4F9-…json` (project graph): **mutated to 244n/750e**
- `embeddings_ABE6D4F9-…json`: new, 8.49 MB, 216 entries
- `/tmp/atlas_project_pre_etr_2026-05-16.json`: pre-ETR backup, untouched
- `/tmp/atlas_etr_live.log`: empty (logs go to unified logging, not stdout)

---

## Threshold sweep — adj-floor 0.85 / 0.80 / 0.75 (added later same session)

Each variant ran against a freshly-restored baseline (`/tmp/atlas_project_pre_etr_2026-05-16.json` → on-disk) with the embedding cache wiped before the first run and reused warm thereafter. auto-merge stayed at 0.95 (default) throughout — band was always empty because no pair embedded ≥ 0.95 sim.

| `--adj-floor` | Candidates | LLM batches | LLM-approved | Final merges | Groups (after transitive closure) | Nodes removed | Post graph |
|---|---|---|---|---|---|---|---|
| 0.85 (default) | 5 | 1 | 2 | 2 | 2 | 2 | 244n / 750e |
| 0.80 | 50 | 3 | 4 | 4 | 3 | 4 | 242n / 750e |
| 0.75 | 387 | 22 | 9 | 9 | 5 | 9 | 237n / 741e |
| 0.70 | ~1000+ (est.) | — | — | — | — | — | RUN FAILED — transient Gemini "network connection was lost" mid-adjudication; pre-apply, graph intact at baseline |

**Approval rate trends down as floor drops:** 40% → 8% → 2.3%. The LLM is doing its job — rejecting most of the additional candidates that lower thresholds surface. Precision stays high across the sweep.

### Cumulative merges discovered at each floor

Floor 0.85 (2 merges):
- "Lab result release: typically within 24 hours" (OPS) → "same-day or next-day results" (CLI)
- "In-app messaging: response within 6 business hours" (OPS) → "Asynchronous messages" (CLI)

Floor 0.80 adds 2 more (4 total):
- "Care coordinator handles prior authorization where required" (OPS) → "referral and prior authorization handled by VitaCare care coordinators" (CLI)
- "care coordinator manages the referral end-to-end" (OPS) → same CLI canonical (3-member group via transitive closure)

Floor 0.75 adds 5 more (9 total):
- "Annual wellness visit: scheduled within 14 days of patient request" (OPS) → "Annual Wellness Visit" — strong match, near-identical labels
- "Extended evening hours available at 16 clinics (open until 9:00 PM)" (OPS) → "Clinic hours are 7:30 AM - 7:00 PM ..." — debatable; extended hours are a variance from standard hours, but LLM accepted as "clinic operating hours" theme
- "Care Between Visits" (CLI) → merged into care-coordinator cluster (5-member group)
- "External Care Coordination" (OPS concept) → also into care-coordinator cluster — note this is a level-promotion (concept absorbed via cross-level merge)
- "Care coordinator matches the patient to a high-quality specialist within their insurance network" (OPS) → same cluster

### Rubric scoring across the sweep

Cross-doc strong-merge rubric pairs caught:

| Rubric row | Pair | 0.85 | 0.80 | 0.75 |
|---|---|---|---|---|
| 8 | OPS care coordinator ↔ CLI referral/prior auth handled by care coordinators | ❌ | ✅ | ✅ |
| 9 | OPS Lab result release ↔ CLI Lab Result Communication | ⚠️ partial | ⚠️ partial | ⚠️ partial |
| Bonus (not in rubric) | OPS Annual wellness visit ↔ CLI/OPS Annual Wellness Visit | ❌ | ❌ | ✅ |
| Bonus (not in rubric) | In-app messaging ↔ Asynchronous messages | ✅ | ✅ | ✅ |
| Bonus (not in rubric) | Lab result release ↔ same-day or next-day results | ✅ | ✅ | ✅ |

| Floor | Precision (true merges / total merges) | Recall (strong-merge rubric pairs caught / 6) | Wall-clock |
|---|---|---|---|
| 0.85 | 2/2 = 100% | 1/6 ≈ 17% (row 9 partial) | ~22s cold, ~13s warm |
| 0.80 | 4/4 = 100% | 2/6 ≈ 33% (rows 8 + 9 partial) | ~57s cold, ~45s warm est. |
| 0.75 | ~8/9 ≈ 89% (extended-hours merge debatable) | 2/6 ≈ 33% (no new strong-merge rubric rows caught; the additional merges are valid but not on the rubric) | ~3min warm |

### Conclusions from the sweep

1. **Lower floor finds more genuine merges**, with the LLM holding the precision line. Going from 0.85 → 0.75 quadrupled merges (2 → 9) while only one was marginal (extended hours).

2. **Diminishing returns past 0.80 for rubric coverage.** 0.80 caught row 8 (care coordinator). 0.75 added 5 more merges but none of them were strong-merge rubric pairs — they were valid merges the rubric author hadn't enumerated (rubric v2 work). So *rubric recall* plateaus at 2/6 from 0.80 onward, even as *real-world merge yield* keeps climbing.

3. **0.70 is impractical at vitacare scale** — even before the network failure, 1000+ candidates × ~12s per LLM batch would take 10-15 minutes. For larger projects this gets worse. **Add transient-failure retry** to the LLM call before sweeping below 0.75.

4. **Recommended production default: 0.80.** Doubles merges over 0.85 with no false positives, surfaces a clear rubric win (row 8), and stays under 1min wall-clock on vitacare. 0.75 is worth doing as an audit pass but not as the default.

5. **The rubric needs expansion.** Multiple legitimate cross-doc merges (annual wellness visit, the care-coordinator cluster pieces beyond row 8, extended hours debate) aren't on the rubric. Rubric v2 should be built by walking the actual extraction, not predicted from PDF text.

### Followup actions from the sweep

- Add retry-with-backoff to `generateRawResponse` in `GeminiBackend` (or in the orchestrator's batch loop) so a single network blip doesn't lose a multi-minute run.
- Bump the default `adjudicationFloor` from 0.85 → 0.80 in `ResolverThresholds.default` (small one-line change; backed by sweep data).
- Add structured logging (or write a debug-only JSON sidecar) of *which* pairs hit which band — debugging the 0.70 result without privacy redaction would be much easier with per-pair audit trail.

### On-disk state after the sweep

- `project_ABE6D4F9-…json`: **back at baseline 246n/753e** (final restore before 0.70 run; 0.70 failed pre-apply)
- `embeddings_ABE6D4F9-…json`: 218 entries, warm and reusable
- `/tmp/atlas_post_etr_floor080.json`: 0.80 run result (242n/750e)
- `/tmp/atlas_post_etr_floor075.json`: 0.75 run result (237n/741e)
- `/tmp/atlas_project_pre_etr_2026-05-16.json`: pre-ETR backup, still untouched
