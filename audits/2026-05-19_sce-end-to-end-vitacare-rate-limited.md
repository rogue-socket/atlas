# SCE end-to-end run on vitacare — **rate-limited, inconclusive**

**Date:** 2026-05-19 16:04–16:11 (401s wall-clock)
**Branch:** `feature/sce-cross-doc` @ `381df79`
**Command:** `pdf_app1 --headless-extract --project test_proj --mode fast`
**Backend:** Gemini (`gemini-2.5-flash` per UserDefaults)
**Project:** `test_proj` (the local rename of the 4-PDF vitacare corpus — same files, different name)

## TL;DR

The SCE end-to-end Gemini run against the vitacare corpus is **inconclusive**. Three independent issues converged:

1. **Rate-limit kill on the last doc.** Gemini returned 6× HTTP 429 during the `patient_experience_and_operations.pdf` (OPS) extraction window 16:11:47–16:11:53. OPS doc finished with **4 nodes / 3 edges** vs the ~30–40 nodes the other three docs produced. Multiple Step 4 (extraction), Step 6 (edges), Chapter-pass, and Summary-pass LLM calls failed silently into the pipeline's graceful-degrade path.
2. **Zero SCE-typed edges emitted.** No `instanceOf`, `attributeOf`, or `processFor` edges appear in any of the 4 result graphs. The full edge-type set across the run was: `cites, containsChapter, containsConcept, containsEntity, defines, dependsOn, exampleOf, extends, partOf, sameTopic, uses` — i.e., the standard pre-SCE edge vocabulary. SCE's `resolveMatchAction` path never returned a typed-edge action that landed in the graph.
3. **Label drift breaks exact-match rubric scoring.** The 20+20 rubric in `prds/2026-05-15_4-level-knowledge-graph.md` §"20+20 quality pairs" was grounded in the 2026-05-16 in-app vitacare extraction. The 2026-05-19 SCE re-extraction produced different concept labels for the same underlying entities. Every SHOULD-MERGE pair returned "MISSING" against exact-label matching; substring fallback found 1-sided matches for ~6 pairs but no 2-sided matches that would let us judge merge-vs-not.

## Graph state after run

```
                                    nodes  edges  by-doc-tag (sourceAnchors)
clinical_services_and_pricing.pdf    53    100    CLI only
compliance_quality_and_security.pdf  101   189    CMP only
organization_and_people.pdf           51    50    CLI+ORG (1 cross-doc merge)
patient_experience_and_operations.pdf  4     3    OPS only (rate-limit casualty)
---
Total (deduped by id)               208    342
Cross-doc merged nodes                 1    —     "Care Between Visits" entity (CLI+ORG)
```

The single cross-doc merge ("Care Between Visits" entity) is **not in the 20+20 rubric** — it's an opportunistic dedup, not a rubric hit. The 2026-05-16 baseline (no SCE, Levenshtein only) found 2 cross-doc merges; this run found 1.

## Rubric scoring (uninterpretable as-run)

```
TP=0  FP=0  TN=20  FN=20    Precision = nan    Recall = 0.000
```

The TN=20 column is vacuous: 17 of 20 SHOULD-NOT-MERGE pairs resolved as "MISSING" on both sides (rubric label not extracted), and the script defaulted those to TN. The result is not a precision/recall reading — it's a label-mismatch report.

## Diagnostic evidence

**os.log error stream (`subsystem == com.atlas.pdf`, 16:03–16:12):**

```
16:11:47.216 E [ai]       [Gemini] HTTP error 429
16:11:47.216 E [pipeline] [Step 6] Edge proposal failed — continuing without edges
16:11:48.673 E [ai]       [Gemini] HTTP error 429
16:11:48.673 E [pipeline] [Step 4] AI extraction failed
16:11:48.673 E [pipeline] Batch 2 FAILED
16:11:49.798 E [ai]       [Gemini] HTTP error 429
16:11:49.798 E [pipeline] [Chapter] LLM chapter pass failed — falling back to page-range chunking
16:11:50.618 E [ai]       [Gemini] HTTP error 429
16:11:50.618 E [pipeline] [Summary] LLM call failed
16:11:52.256 E [ai]       [Gemini] HTTP error 429
16:11:52.257 E [pipeline] [Step 4] AI extraction failed
16:11:52.257 E [pipeline] Batch 1 FAILED
16:11:53.280 E [ai]       [Gemini] HTTP error 429
16:11:53.280 E [pipeline] [Chapter] LLM chapter pass failed
```

Six 429s in 6 seconds. Pattern is consistent with Gemini Flash free-tier RPM cap (15 req/min) — earlier ~6 min of the run consumed quota, and the OPS batches landed in the cooled-down window. The error path correctly logs but doesn't abort, so the process exit code (0) is misleading about run completeness.

## Open questions

### Q1: Why zero SCE-typed edges (instanceOf / attributeOf / processFor)?

`PromptTemplates.priorDocsLabelMap` + `resolveMatchAction` + `SCEMatchAction` enum landed on the SCE branch (verified in `pdf_app1/pdf_app1/Atlas/AI/PromptTemplates.swift` lines 137–296). The 11:00 wrap confirmed end-to-end wiring: `priorDocsLabelMap → ExtractionContext → processBatch → Step 5 resolveMatchAction → typed-edge creation`.

Yet none of the 342 edges in the result graphs have a typed-edge SCE type. Possible reasons (not yet investigated):

- **(a)** SCE prompts ran but the LLM consistently picked `same_entity` (which produces a merge, not a typed edge). Even so, we'd expect more than 1 cross-doc merge given the rubric has 20 SHOULD-MERGE pairs of which several are pure-merge candidates. So the same_entity path is also under-firing.
- **(b)** Cumulative-state header was empty for some structural reason (e.g., doc 1 doesn't get a prior-docs header, and rate limits killed doc 4 — but docs 2 and 3 should have built up state. Need to confirm `processBatch` receives a non-empty `priorDocsLabelMap` for the CMP and ORG runs).
- **(c)** Headless code path skips the SCE branch (e.g., flag gated on a UserDefault that isn't set in headless). Worth checking `processPages` / `processBatch` for any conditional on a UI-set flag.

A short instrumented re-run (one extra `log.info` at `resolveMatchAction` entry) would distinguish (a) from (b)/(c).

### Q2: Should the rubric move to embedding-similarity matching?

The PRD locked in the 20+20 rubric grounded in the 2026-05-16 extraction. But LLM-decided labels drift across runs — "Company Identity" vs "Company Identity & Founding" vs "VitaCare Company Identity". Exact-string match was always going to be brittle.

Two options:
- **(i)** Hand-curate a rubric label-alias map per run (~20 min of work per run).
- **(ii)** Use embeddings to match rubric pairs against current node labels at cosine threshold (≥ 0.85). Reuses existing `EmbeddingResolver.contentHash` infra. ~30 LOC change to the scoring script.

(ii) is the right long-term answer — every SCE/ETR baseline going forward will hit this drift. Worth a small follow-up before the next attempt.

## Recommendation

**Do not treat this run as the SCE baseline.** Re-run after:

1. Gemini quota window resets (typically 1 hour for free-tier RPM; user may want to switch to a Pro key per the 2026-05-19 11:00 wrap's notes on Pro determinism).
2. Add `log.info` instrumentation at `resolveMatchAction` entry + exit, so the next run produces evidence of SCE wiring firing (or not).
3. Switch rubric scoring to embedding-similarity matching (item (ii) above) — otherwise the next run will hit the same uninterpretable-against-rubric outcome.

Cost spent on this run: ~12 batches × 4 docs at Gemini Flash rates ≈ $0.30–$0.60. Not recovered.

## Files

- This audit: `audits/2026-05-19_sce-end-to-end-vitacare-rate-limited.md`
- Scoring script: `/tmp/score_sce.py` (not committed — quick-and-dirty)
- Run logs: `/tmp/sce_run.log` (empty — `log stream` failed to start), `/tmp/sce_stderr.log` (empty), `/tmp/sce_build.log` (build green)
- Result graphs: `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/{f6d69ff2,b9649e4c,46afa38f,48c11bf0}.json` (mtimes 16:07–16:11)
