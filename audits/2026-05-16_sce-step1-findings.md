# SCE Step 1 — End-to-End Findings (2026-05-16)

> **Branch:** `feature/sce-cross-doc` (this doc lives here, not on `main`)
> **Baseline:** `main` at `8225e37` (post-α 4-level migration + B-series + L2)
> **Test corpus:** vitacare 4-PDF set (`sample_pdfs/files/vitacare_*.pdf`)
> **Backend:** Gemini `gemini-2.5-flash`, Fast pipeline (per integration decision #4)

## TL;DR

SCE step 1 is implemented, end-to-end verified on the vitacare corpus via a new headless harness. Two SCE-introduced bugs were caught mid-verification and fixed. A subsequent attempt to lift cross-doc node merging via prompt strengthening produced **a useful negative result**: SCE is structurally capped at ~2 exact-label cross-doc merges per 4-doc run, regardless of prompt wording. The headline win is on **edges, not node merges**: 4 → 137 cross-doc edges (33× lift) while shared nodes stayed at 2. Node merging is ETR's natural domain.

## Headline metrics — pre-SCE baseline vs post-fix SCE

| Metric | Pre-SCE baseline | Post-fix SCE (Run 2) |
|---|---|---|
| Total unique nodes | 214 | 246 |
| Document nodes | 4 | 4 |
| Chapter nodes | 24 | 24 |
| Concept nodes | 37 | 48 |
| Entity nodes | 149 | 170 |
| **Cross-doc shared nodes (anchored in ≥2 PDFs)** | **2** | **2** |
| **Cross-doc edges (between nodes in different docs)** | **4** | **137** |
| Label-dup-different-UUID failures | 0 | 0 |
| Wall clock (4 docs, Fast mode) | (n/a) | ~17 min |
| Total prompt tokens (4 docs) | (n/a) | ~22k |

## What landed on this branch

Five SCE-feature commits before this session's work (already on branch as of `2a8c01b`):

```
2a8c01b SCETests: 8 unit tests covering header builder + buffer-then-commit
40a416d ExtractionPipeline: per-doc buffer-then-commit + SCE header threading
43e50c0 GeminiBackend: capture usageMetadata.promptTokenCount per response
14ab423 SCE: ExtractionContext.priorDocsContext + cumulative-state header
```

Three commits from this session (2026-05-16 PM):

```
c609a4a PromptTemplates: strengthen SCE prior-docs block with worked examples
6c3e01a ExtractionPipeline: revert per-doc buffer, restore label-match merge
6cf38e2 Headless extraction harness + dev-keys API key source
```

Branch is **7 commits ahead of `main`**, working tree clean, **not pushed** to origin.

## Headless harness (`6cf38e2`)

Invocation:

```bash
~/Library/Developer/Xcode/DerivedData/pdf_app1-giytzhghgxnvaderrgxenmypwjxy/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1 \
  --headless-extract --project test_proj --mode fast
```

- Drives `processPages` sequentially for every file in the named project, in alphabetical-by-displayName order. Flushes pending saves and exits cleanly with `exit(0)`.
- Triggered from `applicationDidFinishLaunching` via `NSApplicationDelegateAdaptor` — `.onAppear` is unreliable for background launches. **Must invoke the binary directly**, not via `open(1)` — `open --wait-apps` hangs on SwiftUI scene installation.
- New `AtlasLogger.headless` category; `[Headless]` lines are filterable from `log show`.
- Window appears briefly during launch (SwiftUI WindowGroup creates one); vanishes on exit. Cosmetic only.

### Dev-keys file (Keychain workaround)

`AIServiceManager.getAPIKey(for:)` resolution order:
1. Env var `ATLAS_<BACKEND>_API_KEY` (e.g. `ATLAS_GEMINI_API_KEY`) — per-invocation override
2. **Dev-keys JSON** at `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` — **authoritative when present**; never falls through to Keychain. Case-insensitive key lookup (`"gemini"` or `"Gemini"` both work).
3. Keychain — only consulted when no dev-keys file exists at all.

File format: `{"gemini": "AIzaSy..."}`. Plaintext, sandbox-only — fine for local dev, never commit or copy off-machine.

Authoritative semantics are intentional: the test host loads with `selectedBackendType = .claude` (default) before its own UserDefaults domain is read. Without the short-circuit, the test host would still trigger a Keychain ACL prompt looking for a Claude key that isn't there.

## Bugs found and fixed mid-verification

### Bug 1 — cross-doc merge broken by buffer-then-commit (`6c3e01a`)

The original SCE implementation (`40a416d`) collected per-batch results into an intermediate `KnowledgeGraph` buffer and committed to the live graph via `graph.merge(from: buffer)` at end-of-doc (integration decision #3). Problem: in `processBatch`, `graph.node(matching: rawConcept.label)` runs against the **buffer's** `labelIndex` — empty at the start of each doc. So when the LLM produced a label identical to one already in the live graph from a prior doc, the buffer had no match, the node was added with a fresh UUID, and the subsequent UUID-keyed merge didn't collide with the existing live node. **Duplicate labels under different UUIDs landed in the live graph.**

Reproduced on vitacare (broken-SCE run): 4 label-dup-different-UUID failures (`"patient outcomes"`, `"primary care model"`, `"same-day access"`, `"asynchronous messages"`).

Fix: revert the buffer; write per-batch results directly to the live graph (pre-SCE behavior). Keep all other SCE work — cumulative-state header detection, threading via `ExtractionContext.priorDocsContext`, `[SCE]` telemetry, GeminiBackend token capture. Cost: doc-level atomicity (integration decision #3) is gone. Mid-doc cancel now leaves partial state on the live graph. Acceptable cost — the SCE cumulative-state model already accepts partial-state-as-prior-context for subsequent docs, and the cross-doc-merge value greatly outweighs the rare bad-LLM-mid-doc protection. Can reintroduce atomicity later as a label-aware merge if needed.

Post-fix verification: 0 label-dup failures.

### Bug 2 — per-doc files missing chapter/document/L2 nodes (`6c3e01a`, bundled)

`processBatch` Step 7 (`scheduleSave`) was the only save site during fast extraction. It encodes the subgraph synchronously at call time — meaning it captures `graph` state *right then*. The pipeline then calls chapter extraction → `appendDocumentSummary` → `ChapterEdgeAggregation.synthesize` **after** processBatch returns, adding chapter and document nodes to the live graph. **No further save fires.** The on-disk per-doc file ends up missing all chapter and document nodes.

This is a **pre-existing latent bug** (predates SCE). It was masked by users re-extracting docs across sessions — the chapter/document state from a prior run survived in memory and was captured by the next run's first-batch save. The headless harness ran fresh from disk and exposed the gap.

Reproduced on vitacare (broken-SCE run): per-doc files showed `{entity: 201, concept: 49}` only — zero chapter or document nodes. Project total of 250 unique nodes lacked any chapter/document level.

Fix: add a trailing `GraphStore.shared.scheduleSave(graph, for: documentURL)` (or `saveProjectGraph` when `projectID != nil`) at the very end of `processPages` after all enrichments.

Post-fix verification: `{document: 4, chapter: 24, concept: 47, entity: 178}` in the saved project file.

## Negative result — prompt strengthening did not lift cross-doc node merging (`c609a4a`)

After verifying the bug fixes, ran a diagnostic: of the ~200 cross-doc concept candidates, only 2 had ended up with identical labels (the merge mechanism's prerequisite). The LLM was "improving" labels across docs — `"Behavioral health"` → `"Behavioral Health Services"`, `"Telehealth Platform"` → `"National Telehealth Platform"`, etc.

Hypothesis: strengthen the prior-docs prompt block with explicit worked examples showing exactly what NOT to do (titles, expansions, articles, pluralization) plus a counterexample where creating a new node IS correct (genuinely distinct concept, overlapping topic area). LLMs follow examples more reliably than imperative instructions.

End-to-end re-run on vitacare with the strengthened prompt:

| Metric | SCE Run 1 (weak prompt) | SCE Run 2 (strong prompt) |
|---|---|---|
| Total nodes | 253 | 246 |
| Cross-doc shared nodes | 2 | 2 |
| Cross-doc edges | 131 | 137 |
| Avg per-batch tokens | ~2100 | ~2775 (+30%) |
| Wall clock | ~16 min | ~17 min |

The 2 cross-doc merges in Run 2 are **different concepts** than Run 1 — Run 1 caught `"Annual Wellness Visit"` + `"Asynchronous messaging"`, Run 2 caught `"Video visits"` + a verbatim clinic-hours quote. Suggests the 2 per run are essentially noise from happenstance identical phrasing, not signal driven by the cumulative-state header.

### Why the prompt strengthening didn't work

Hypothesized root cause: the concept-extraction prompt also requires `textSpan` to be a **verbatim quote from the current text**. So the LLM is anchored to current-doc wording — `existingConcepts` and the prior-docs header have to compete with the verbatim-quote constraint, and verbatim wins. When current text says `"wellness visits"`, the LLM produces label `"Wellness Visits"` not `"Annual Wellness Visit"` regardless of the prior-docs instruction, because it needs a `textSpan` matching current-doc surface form.

The strengthened prompt is kept anyway — net-neutral-or-positive, token overhead modest, worked-examples is the right shape. Future iteration could relax the textSpan-verbatim constraint, but that may hurt anchor resolution downstream.

## What SCE is actually good for

**Edges, not node merges.** The 4 → 137 cross-doc edge lift (33×) is the real headline. The LLM, given a 100-200 line cumulative-state header on docs 2-4, will *propose relationships* between current-doc concepts and prior-doc concepts even when not reusing labels for the prior nodes themselves. Pre-SCE this almost never happened (4 cross-doc edges across the entire corpus, likely accidental). Post-SCE it's a structural feature (~33 cross-doc edges per added doc on average).

**ETR's natural domain:** the node-merge side. Embedding-based similarity will catch the `"Wellness Visit"` / `"Annual Wellness Visit"` / `"Wellness Visits"` family that exact-string-match can never bridge.

## Token costs (Run 2, Gemini 2.5 Flash)

Visible per-batch (from `[SCE] prompt_tokens=N` log lines after the `privacy: .public` fix):

| Doc | Batch 1 | Batch 2 | Doc total |
|---|---|---|---|
| clinical_services | (evicted from log) | (evicted) | ~5000 (est) |
| compliance | 2383 | 1844 | 4227 |
| organization | 3203 | 2241 | 5444 |
| patient_experience | 3813 | 3163 | 6976 |
| **Total** | | | **~22k** |

Per-doc tokens grow as the cumulative-state header gets longer (138 lines for doc 3, 196 lines for doc 4). With the strengthened prompt block (~600-1000 tokens of worked examples), totals are ~30% higher than Run 1.

## Bugs known but not fixed in this session

1. **Orphan-sweep deletes valid graphs on app restart.** Reproduced earlier in this session: user opened the app after a previous extraction, and `clinical_services_and_pricing` graph file disappeared. `GraphStore.sweepOrphans` (from 2026-05-15) treats per-doc graph files as orphaned when their URL isn't in the alive-set built from project file bookmarks. If bookmark resolution fails at startup (consistent with the "file not readable" errors seen earlier), the sweep deletes graphs for URLs the user can still see in the project sidebar. **User-facing data-loss bug.** Best fixed on `main`, not this branch. Fix shape: sweep should distinguish "URL confirmed not in any project" (delete) from "couldn't resolve URL this launch" (retain).

2. **Per-doc files not written when `projectID` is set.** The current save logic is either-or: `if let projectID { saveProjectGraph } else { scheduleSave per-doc }`. The harness (which always passes `projectID`) only writes the project-graph file; B4's per-doc files are dormant in project-context runs. May or may not matter depending on whether per-doc files are still relied on for cross-tab loading. Worth confirming whether this is intentional architectural narrowing or accidental.

## Verification methodology — for the eventual rerun

1. **Wipe** `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/*.json` (baseline snapshot at `/tmp/atlas_graphs_baseline_pre_sce_2026-05-16/`)
2. **Confirm** dev-keys file at `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` has current Gemini key
3. **Build** (`xcodebuild -project atlas/pdf_app1/pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build`)
4. **Run** headless: `~/Library/Developer/Xcode/DerivedData/pdf_app1-.../pdf_app1.app/Contents/MacOS/pdf_app1 --headless-extract --project test_proj --mode fast` (background; ~17 min)
5. **Analyze** the resulting `project_*.json` (or per-doc files if logic changes): count cross-doc shared nodes (`sourceAnchors.documentURL` set ≥ 2), count cross-doc edges (source/target nodes primary-anchored in different docs), spot-check label-dup-different-UUID failures (should be 0).

## What's open for the next session

- ETR branch off `8225e37` (same baseline). Embedding-model selector + 4-stage pipeline. The 20+20 quality pairs are still NOT written down in the PRD (line 327 still marks them as open) — that needs to happen before ETR can be scored against SCE.
- Optional: investigate per-doc-files-not-written-in-project-context behavior; decide whether to also write per-doc files alongside the project graph.
- Optional: orphan-sweep restart bug fix on `main`.
- Push `feature/sce-cross-doc` to origin so it isn't local-only.

## Files for the next /start to read first

1. This file
2. `atlas/prds/2026-05-15_4-level-knowledge-graph.md` §"Cross-Doc Merging" + §"Locked-in prep items — 2026-05-16"
3. `git log --oneline -10` on `feature/sce-cross-doc` (should show the 7-commit lead)
4. `atlas/backlog.md` — the `[next 2026-05-16]` SCE/ETR section
