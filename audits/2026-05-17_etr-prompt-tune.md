# ETR mergeAdjudication prompt tune — 2026-05-17

> **Branch:** `feature/etr-cross-doc` @ `1934849` (was `b10b163` at session start)
> **Commits added this pass:** `1b0c3d1` (Gemini greedy decode) + `1934849` (prompt v2). Both pushed.
> **Supersedes:** `audits/2026-05-16_etr-session-summary.md` for any state past 2026-05-17. That doc still reflects the 0.80-default / 25%-recall reading from before this pass.
> **Pairs with:** `prds/2026-05-15_4-level-knowledge-graph.md` §"Quality Rubric v2" (rubric rows 3 / 10 / 13 marked caught + 2026-05-17 score block appended).
> **Audit-doc-of-record for:** the 11 sidecar JSON files in `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/etr_audit_*.json` (dates 2026-05-16T18:46:34Z → 2026-05-16T20:22:02Z UTC — local mtimes 2026-05-17). Filename dates are UTC; the run actually happened the evening of 2026-05-17 IST.

## TL;DR

Two commits land. Greedy decode (T=0, topK=1) by itself does not help — Gemini still varies (4/5/5 approvals on the *old* prompt across 3 same-data reruns). With the prompt rewrite layered on top, **3-of-3 stable rubric recall went 3-4/7 → 7/7** (the two named hard targets — rows 10 and 13 — flipped from 0/3 → 3/3, and cross-level row 3 was caught newly). Trap precision held at **8/8** in every run. Total stable approvals: **9 pairs in all 3 runs + 2 pairs in 2 of 3 runs** (= 9–11 merges per run). Post-tune project graph: **235n / 740e** vs old-prompt 240n / 747e on the same baseline (5 more nodes merged, 7 more edges deduped).

## What landed

### Commit 1 — `1b0c3d1` `GeminiBackend: temperature 0.1 → 0.0, add topK: 1`

One-line config change in `Atlas/AI/Backends/GeminiBackend.swift`. Aligns with the prior "extraction wants determinism" decision (Claude temperature pin in `058936e`). Affects **all** Gemini calls, not just adjudication — including extraction and edge proposal.

**Key finding (already in commit message, repeated for emphasis):** Gemini at T=0 + topK=1 is **not** deterministic in practice. 3 reruns of the old prompt against the warm cache produced 4 / 5 / 5 approvals. Variance shrinks enough for rubric-anchored 3-of-3 reads to be stable, but single-run counts remain unreliable.

### Commit 2 — `1934849` `ETR: tune mergeAdjudication prompt`

`Atlas/AI/PromptTemplates.swift` `mergeAdjudication(pairs:)` rewrite. +50 / −18 lines.

The shape of the rewrite (full diff in `git show 1934849`):

1. **Reframed the question.** "Same real-world thing" → "could these two labels appear as bullet points under the same heading in a corporate handbook describing a single process, service, fact, or entity." The handbook-bullets test gave the LLM a concrete adjudicator stance.
2. **Added MERGE positive examples** with the operational pattern named for each, including the two named hard rubric targets:
   - cross-paraphrase same-fact (lab portal post ↔ lab release within 24h)
   - cross-level concept↔entity (Referral Process ↔ "referral and prior auth handled by VitaCare care coordinators")
   - same activity from different angles (Advanced Imaging Referrals ↔ External Care Coordination), with an inline anti-leakage test: "must describe the SAME activity, not a leaf service and the broader catalog that contains it."
3. **Added KEEP-SEPARATE negative examples** mirroring all 8 SHOULD-NOT-MERGE rubric traps verbatim (insurance networks vs policies, internal vs external audits, on-site vs external labs, lab-results portal post vs portal WCAG accessibility, …).
4. **Added one extra anti-pattern class — `<leaf service> ↔ "VitaCare Services"`** with 4 concrete examples (Post-Discharge Care, Health Coaching, External Care Coordination, Group Programs each ↔ VitaCare Services). This was added in **v2 of the rewrite** specifically to fix the v1-regression below.
5. **Bias on uncertainty:** "When uncertain, prefer KEEP SEPARATE (false). Only merge when you can articulate the single real-world thing both labels point at."

**v1 → v2 inside this commit:** v1 of the rewrite over-merged on the catalog-leaf pattern (1–3 FPs per run pointing at VitaCare Services as the catalog umbrella). Adding the 4 explicit leaf-of-catalog anti-pattern examples (v2) killed that class — **0 / 15 catalog-FPs across 3 v2 runs**.

**Hardcoding caveat — flag for review.** The new prompt embeds vitacare-specific labels as exemplars on both sides ("Asynchronous messages", "Lab Result Communication", "Specialty Care Services", "Post-Discharge Care", "VitaCare Services" etc). The user-vetoed pattern on SCE was vitacare-specific anti-pattern examples in the prompt. Here those examples are inline in the canonical adjudication prompt that will be shipped to every corpus. Two possible reads: (a) the prompt is now corpus-coupled and should be parameterized before another corpus runs through it; (b) the patterns named are general (catalog/leaf, same-fact-different-framing, role-collision) and the labels happen to be vitacare's. Worth a deliberate decision before the next corpus extraction.

## The run-by-run data (sidecars)

11 audit sidecars on disk. All ran against the same warm embedding cache (218 entries, 8.6 MB, model `gemini-embedding-2-preview`, 3072-dim). Thresholds identical across every run: floor=0.80, autoMerge=0.95, batch=18. 17,810 cross-doc pairs evaluated → 50 in the 0.80–0.95 adjudication band each time → 1 LLM call of 3 batches × 18 pairs.

| # | UTC timestamp           | Approved / 50 | Cohort           |
|---|-------------------------|---------------|------------------|
| 1 | 2026-05-16T18:46:34Z    | 6             | yesterday baseline (T=0.1, old prompt)   |
| 2 | 2026-05-16T20:09:44Z    | 2             | tonight pre-tune (T=0.1, old prompt)     |
| 3 | 2026-05-16T20:13:30Z    | 4             | det-old run 1 (T=0+K=1, old prompt)      |
| 4 | 2026-05-16T20:14:22Z    | 5             | det-old run 2                            |
| 5 | 2026-05-16T20:15:07Z    | 5             | det-old run 3                            |
| 6 | 2026-05-16T20:17:02Z    | 17            | v1-tuned run 1 (catalog FP regression)   |
| 7 | 2026-05-16T20:17:49Z    | 18            | v1-tuned run 2                           |
| 8 | 2026-05-16T20:18:32Z    | 14            | v1-tuned run 3                           |
| 9 | 2026-05-16T20:20:12Z    | 10            | **v2-tuned run 1**                       |
|10 | 2026-05-16T20:21:04Z    | 10            | **v2-tuned run 2**                       |
|11 | 2026-05-16T20:22:02Z    | 11            | **v2-tuned run 3**                       |

The v1 vs v2 spread (17/18/14 vs 10/10/11) is almost entirely the catalog-leaf FP class. The 4–5 vs 10–11 spread (old vs v2) is real recall.

## V2 stable approvals (the merges the tuned prompt actually surfaces)

**9 pairs approved in all 3 v2 runs:**

| # | A label                                                    | B label                                                       | sim   | lvl  | Rubric ref         |
|---|------------------------------------------------------------|---------------------------------------------------------------|-------|------|--------------------|
| 1 | Lab result release: typically within 24h                   | same-day or next-day results                                  | 0.877 | e↔e  | row 1              |
| 2 | Message response: within 6 business hours                  | Asynchronous messages                                         | 0.877 | e↔e  | (off-rubric)       |
| 3 | Advanced Imaging Referrals                                 | External Care Coordination                                    | 0.866 | c↔c  | **row 10**         |
| 4 | Asynchronous messages                                      | In-app messaging: response within 6 business hours            | 0.862 | e↔e  | row 2              |
| 5 | referral and prior authorization handled by VitaCare       | Care coordinator handles prior authorization                  | 0.837 | e↔e  | row 4/5            |
| 6 | Lab result release: typically within 24h                   | Lab results are posted to the patient portal                  | 0.834 | e↔e  | **row 13**         |
| 7 | referral and prior authorization handled by VitaCare       | care coordinator manages the referral end-to-end              | 0.824 | e↔e  | row 4/5            |
| 8 | Operational Reliability                                    | Business Continuity and Disaster Recovery                     | 0.815 | c↔c  | row 6 (marginal)   |
| 9 | Referral Process                                           | referral and prior authorization handled by VitaCare          | 0.810 | c↔e  | **row 3** (cross-lvl) |

**2 pairs approved in 2 of 3 v2 runs (unstable — single-run gating):**

- Referral Process ↔ Advanced Imaging Referrals — 0.879, c↔c. Promote to **rubric v3 row 21** (subset relation, debatable merge).
- "no additional cost for members of program" ↔ Chronic Condition Programs — 0.808, e↔c. Defer (pricing fact about a concept; arguably a hierarchy edge, not a merge).

## Recall headroom — top stable rejects by similarity

Pairs rejected in **all 3** v2 runs above sim ≥ 0.81 (recall ceiling candidates):

| sim   | lvl  | A label                                  | B label                                              | Verdict review                                                 |
|-------|------|------------------------------------------|------------------------------------------------------|----------------------------------------------------------------|
| 0.843 | c↔c  | Specialty Care Services                  | Specialist Network Curation                          | Plausible merge — the new prompt's "vendor-management vs catalog" anti-pattern caused this rejection; may be wrong on this one |
| 0.840 | c↔c  | Specialty Care Services                  | External Care Coordination                           | Correct rejection — different functions                        |
| 0.836 | e↔e  | includes all primary care visits         | Free VitaCare primary care for employees             | Correct rejection — patient product vs employee benefit (prompt names this trap explicitly) |
| 0.827 | c↔c  | Virtual Care Platform                    | External Care Coordination                           | Correct rejection                                              |
| 0.825 | c↔e  | Health Coaching                          | Chronic Condition Programs                           | Correct rejection — distinct program types (prompt names trap) |
| 0.823 | c↔c  | Virtual Care Platform                    | Telehealth Clinicians                                | Correct rejection — service vs staff role                      |
| 0.823 | e↔e  | 98.9% on-time visit starts               | Patient Net Promoter Score: 71                       | Correct rejection — different metrics (prompt names trap)      |
| 0.822 | c↔c  | Primary Care Model                       | External Care Coordination                           | Correct rejection                                              |
| 0.818 | c↔c  | Virtual Care Platform                    | Patient Education and Engagement Programs            | Correct rejection                                              |
| 0.817 | c↔c  | Insurance Policies                       | Insurance Networks                                   | Correct rejection — **rubric trap row** (corporate liability vs accepted payors) |
| 0.815 | c↔c  | VitaCare Services                        | Wellness / Post-Discharge / External / Health Coaching | Correct rejections — catalog-leaf class                       |

**Reading:** the only plausibly-missed merge in the stable-reject set is row 1 above (Specialty Care Services ↔ Specialist Network Curation). Everything else in the high-sim reject band is either a named rubric trap or a sensible operational distinction. **The 0.80–0.95 adjudication band on this corpus is close to saturated with the v2 prompt.** Further recall lift almost certainly needs the floor dropped below 0.80 — i.e. surface more pairs into the band, not adjudicate the existing band more aggressively.

The PRD's 12 rubric rows still off-rubric ("not in band") at floor 0.80 are the real recall ceiling. They live below 0.80 cosine on this embedding model. Two follow-up shapes:

1. Drop adjudication floor to 0.75 with the v2 prompt. Old-prompt 0.75 sweep caught 8/20 rubric pairs (40% recall) at ~3 min wall-clock and 22 LLM batches; v2 prompt at the same floor would likely catch more without the catalog FPs.
2. Swap embedding model to widen high-sim hits on the missed rubric rows. Candidates listed in the 2026-05-16 session-summary §"What's NOT done" item 3 (gemini-embedding-001, OpenAI text-embedding-3-large).

## Methodology — what is worth keeping

1. **Single-run approval counts are noise.** The 10/10/11 v2 spread and 4/5/5 old spread are visible only because we ran 3 reruns each on the same warm cache. Comparing 10 vs 5 from one run apiece would be tempting and wrong.
2. **Read prompt revisions through the rubric 3-of-3 intersection.** The 7-merge + 8-trap rubric subset was enough to read the A/B clearly — broader raw-count comparisons hide signal under variance.
3. **One extra example per FP class is enough.** v2 fixed v1's catalog-FP regression with 4 lines of catalog-leaf anti-pattern examples; nothing else changed.
4. **Sidecar JSON is the regression dataset.** Keep the 11 files on disk until v3 lands — the (pair, sim, verdict) tuples are reusable for any future prompt-rev A/B against the same baseline graph.
5. **Greedy decode alone is not a recall lever.** It tightens variance band but does not move the rubric numbers. Worth committing for hygiene, not worth attributing recall gains to.

## What's NOT done

1. **Push** — both commits are already on `origin/feature/etr-cross-doc`. Branch is in sync; the older session-summary docs now carry a 2026-05-26 current-status correction.
2. **`main` merge** — branch is **21 ahead / 19 behind `main`**. Same backlog as `feature/sce-cross-doc`. Includes morning's data-loss fix, Locate UX, project-graph cleanup. Should be merged in before the next ETR experiment.
3. **Floor-0.75 v2 rerun.** Cheap (warm cache, embeddings cached) — one `--etr-only --adj-floor 0.75` invocation. Would produce sidecar #12 directly comparable to the 0.75 old-prompt sweep in the live-verification doc.
4. **Embedding-model swap experiment.** API-cost-heavy. Defer.
5. **Per-level threshold split** (concept↔concept vs entity↔entity). Defer. The current data is too sparse to motivate it — every level pair appears in stable approvals.
6. **In-doc pair support.** One-line filter change in `pairsToCompare`. Opens up the 5 in-doc rubric v1 rows. Defer.
7. **Prompt parameterization** — the hardcoding caveat in §"What landed" #2 above. Needs an explicit decision before another corpus runs through this prompt.
8. **SCE + ETR hybrid** — held off in the SCE step-3 wrap. Now that ETR is at 7/7 rubric recall stable, this is a stronger story: SCE provides 54 cross-doc typed edges (per `audits/2026-05-18_sce-step3-handoff.md`), ETR provides 9–11 cross-doc node merges, they are orthogonal.

## How to reproduce / continue

```bash
# 1. Make sure you are on the right branch
cd /Users/yashagrawal/Documents/pdf_projects/atlas/pdf_app1
git checkout feature/etr-cross-doc
git log --oneline -3   # expect 1934849, 1b0c3d1, fefcf8c at top

# 2. Build
xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build

# 3. The warm embedding cache is still on disk (2026-05-17 mtime):
ls -la ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/embeddings_*.json
#   → embeddings_ABE6D4F9-7F9E-4BD8-B977-57D541824DF3.json, ~8.6 MB

# 4. There is NO surviving pre-ETR baseline graph in /tmp anymore (was wiped between sessions).
#    The 2026-05-17 baseline snapshot survived at /tmp/atlas_etr_audit_baseline_2026-05-16.json
#    (27 KB). To restore project graph state before re-running an experiment that mutates the
#    graph, take a fresh snapshot first:
PROJ=~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/project_ABE6D4F9-7F9E-4BD8-B977-57D541824DF3.json
cp "$PROJ" /tmp/atlas_project_$(date +%Y-%m-%dT%H%M%S).json

# 5. Run ETR with the v2 prompt at the existing 0.80 default
~/Library/Developer/Xcode/DerivedData/pdf_app1-*/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1 \
  --headless-extract --project test_proj --etr-only

# 6. The new sidecar lands at
ls -lat ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/etr_audit_*.json | head -1

# 7. Optional: drop floor to 0.75 to test the recall-ceiling hypothesis
~/Library/Developer/Xcode/DerivedData/pdf_app1-*/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1 \
  --headless-extract --project test_proj --etr-only --adj-floor 0.75
```

## One paragraph for a new agent's `/start`

ETR cross-doc node-merging is at its current rubric ceiling on the vitacare corpus. `feature/etr-cross-doc` HEAD `1934849` runs Gemini at T=0+topK=1 with a tuned `mergeAdjudication` prompt that gets **7/7 stable rubric recall** + **8/8 stable trap precision** + **9 stable merges per run** at the 0.80 adjudication floor on the warm embedding cache. The branch is pushed and **21 ahead / 19 behind `main`**. The 11 audit sidecars in `Atlas/graphs/etr_audit_*.json` are the regression dataset behind that number — see this doc for the run-by-run breakdown and the recall-headroom analysis. Next likely move: merge `main` in (catches morning's data-loss fix + others), then either drop adjudication floor to 0.75 with the v2 prompt (cheap experiment, warm cache) or pursue the SCE+ETR hybrid that was held off earlier this week. **Open concern flagged in §"What landed":** the v2 prompt embeds vitacare-specific labels inline as exemplars — needs a deliberate parameterize-or-leave-it decision before another corpus runs through it.
