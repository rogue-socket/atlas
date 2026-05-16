# ETR Step 1 — Status (2026-05-16)

> **Branch:** `feature/etr-cross-doc` (this doc lives here, not on `main`)
> **Baseline:** `main` at `8225e37` (same as SCE branch — integration decision #6)
> **HEAD:** `b32f376` (3 commits ahead of `main`, not pushed)
> **Companion plan:** `atlas/audits/2026-05-16_etr-step1-plan.md` (also on this branch)

## Branch state

```
b32f376 ETR step 1: embedding backend protocol + Gemini impl + factory wiring
c59ccda Audit: ETR step 1 implementation plan (vitacare verification target)
e1cf898 Headless extraction harness + dev-keys API key source  ← cherry-picked from SCE branch
8225e37 Backlog: 2026-05-16 done block + carry-forward for B-series + L2  ← main baseline
```

Working tree clean. Branch is local-only — NOT pushed to origin.

## What's done

ETR stage 2 foundation (embed + pool). Code is in place; nothing yet calls it end-to-end (stages 3 + 4 are not implemented).

### Files added / modified

| Path | Purpose |
|---|---|
| `Atlas/AI/Embeddings/AtlasEmbeddingBackend.swift` | Protocol: `embed([String]) async throws -> [[Float]]` + `displayName` / `modelIdentifier` / `vectorDimension` / `isAvailable` |
| `Atlas/AI/Embeddings/GeminiEmbeddingBackend.swift` | Calls `gemini-embedding-2-preview` via the `batchEmbedContents` endpoint. Chunks inputs to 100/HTTP call (Google's documented limit). Throws on dimension mismatch. 3072-dim default. |
| `Atlas/AI/Embeddings/EmbeddingMath.swift` | `cosineSimilarity(_:_:) -> Float`. Pure. Returns 0 on zero-magnitude input. Precondition on dimension match. |
| `Atlas/AI/AIServiceManager.swift` | Added `selectedEmbeddingBackendType: AIBackendType?` (default `.gemini`) + `selectedEmbeddingModel: String` (default `"gemini-embedding-2-preview"`) + `isEmbeddingConfigured` + `createEmbeddingBackend()` factory. Loaded/saved via two new UserDefaults keys. |
| `Constants.swift` | Two new UserDefaults keys: `atlas.ai.embedding.backendType` / `.model` |
| `Atlas/AI/AtlasLogger.swift` | Added `embedding` category (`[Embed]` log lines) |
| `pdf_app1Tests/EmbeddingTests.swift` | 9 unit tests — cosine math (identical / opposite / orthogonal / zero / scaled / known-angle) + GeminiEmbeddingBackend protocol shape (empty input short-circuits without key, non-empty without key throws `noAPIKey`, metadata reflects construction). All green. No live API hits. |

### Embedding defaults baked in

Per PRD §"Locked-in prep items — 2026-05-16":
- **Gemini** → `gemini-embedding-2-preview` (3072-dim, live-tested 2026-05-16); `gemini-embedding-001` is the fallback once preview deprecates (not yet wired)
- **OpenAI** → would use `text-embedding-3-large` (deferred — not implemented in v1)
- **Ollama** → would use `nomic-embed-text` (deferred)
- **Claude** → none (no Anthropic embedding API; `createEmbeddingBackend()` returns nil for Claude)

`createEmbeddingBackend()` currently returns non-nil ONLY for Gemini (with `warning` logs for OpenAI/Ollama). This mirrors SCE's integration decision #4 ("Gemini-only v1") for symmetry — expand once ETR proves end-to-end.

### Cherry-picked from SCE branch

`e1cf898` is the headless harness + dev-keys file commit from `feature/sce-cross-doc`. Pure tooling, no SCE semantics — ETR will need the same workflow for verification. Will need cherry-picking again when fresh tooling lands on SCE.

## What's NOT done

These are the next slices to land on this branch:

### Stage 3 — Tiered Resolution

- New `Atlas/AI/Embeddings/EmbeddingResolver.swift`. Pure functions on `KnowledgeGraph` + an `AtlasEmbeddingBackend`:
  - Build embedding text per node: `label + ": " + type + summary` (per PRD §"Approach 2"). Confirm `summary ?? "(no summary)"` is the right fallback.
  - Call `backend.embed(...)` once for the whole project (250 nodes fits in 3 batches of 100).
  - Brute-force pairwise candidate generation (n²/2 — at 250 nodes, 31k pairs, ~25ms).
  - Tiered classification per pair:
    - `sim >= 0.95` OR exact lowercase label match → **auto-merge**
    - `0.85 <= sim < 0.95` → **LLM adjudication** (batched ~15-20 pairs per call to the existing LLM backend)
    - `sim < 0.85` → **auto-reject**
- LLM adjudication uses a new `PromptTemplates.mergeAdjudication(pairs:)` that takes 15-20 candidate pairs and returns a `[Bool]` decision per pair. JSON output.
- Output: `[(canonicalUUID, mergeIntoUUID, reason)]` list. No graph mutation in this stage — just the merge plan.

### Stage 4 — Apply Merges

- New `Atlas/AI/Embeddings/EmbeddingMergeApplier.swift`. Takes the stage-3 merge plan + `KnowledgeGraph` and:
  - Picks a canonical UUID per merge group (deterministic — e.g., lexicographically smallest, or oldest by `lastModified`).
  - Rewrites all `sourceAnchors` from merged-away nodes onto the canonical node.
  - Rewrites all edges referencing merged-away IDs to point at the canonical UUID.
  - Dedupes edges by tuple after rewrite (some merges create duplicate edges).
  - Promotes level if any constituent was higher (e.g., concept > entity).
  - Removes the merged-away nodes from the graph.

### Integration

- Headless harness `--etr` flag. When present, after `processPages` completes for all 4 docs, run `EmbeddingResolver` + `EmbeddingMergeApplier` against the project-wide graph, then save.
- Optionally: persist the merge plan to disk (audit trail / debugging).

### Open questions to resolve before stage 3 lands

1. **Embedding cache.** Re-running ETR over and over would burn embedding API quota. Recommend a project-wide JSON file `embeddings_<projectID>.json` in the existing graphs directory, keyed by `nodeID:contentHash` where `contentHash` is `sha256(label + ":" + type + ":" + summary)`. Invalidate per-entry when the content hash changes.
2. **Embedding text composition.** PRD says `label + ": " + type + summary`. Confirm `summary ?? "(no summary)"` fallback is acceptable — or if `nil` summary should be `label + ": " + type` only (no synthetic placeholder, less noise in the embedding).
3. **Pair scope.** Cross-doc only or cross-doc + in-doc? Recommend: cross-doc only. In-doc dedup is already handled by `graph.node(matching:)` during extraction. ETR exists specifically to bridge cross-doc cases the extraction-time merge misses.
4. **Level-mixing pairs.** Should `concept` vs `entity` even be considered as merge candidates? PRD allows level promotion in stage 4, but the candidate generator can be stricter. Recommend: cross-level pairs eligible, but the LLM adjudication should be told about the level mismatch ("these are at different abstraction levels — only merge if genuinely same thing").
5. **What's the LLM adjudication threshold-band exit criteria?** Auto-merge above 0.95 might be too aggressive on the upper end. Recommend: keep the PRD's defaults (0.95 / 0.85) as starting point, plan a tuning pass after first end-to-end run.

### Verification plan (when all 4 stages land)

Same pattern as SCE verification:
1. Wipe vitacare graphs (`rm ~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/*.json`). Baseline snapshot is at `/tmp/atlas_graphs_baseline_pre_sce_2026-05-16/`.
2. Confirm dev-keys file at `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` has current Gemini key.
3. Build (`xcodebuild -project atlas/pdf_app1/pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build`).
4. Run headless with `--etr`: `~/Library/Developer/Xcode/DerivedData/pdf_app1-.../pdf_app1.app/Contents/MacOS/pdf_app1 --headless-extract --project test_proj --mode fast --etr` (flag name TBD).
5. Compare against SCE Run 2's metrics (137 cross-doc edges, 2 shared nodes, 246 total nodes). ETR's value-add should be MORE shared nodes (semantic merging via embeddings catches what exact-label-match misses).
6. Score against the 40-pair quality rubric — **still not in the PRD** (line 327 still has it as open action item). **Block ETR scoring on freezing those 40 pairs first.** The candidate pairs were discussed in chat but never persisted to the PRD.

## SCE branch reference (separate work — for context)

`feature/sce-cross-doc` at `8c69c32` (8 commits ahead of `main`). SCE step 1 is end-to-end verified on vitacare. Findings doc at `atlas/audits/2026-05-16_sce-step1-findings.md` (on that branch). Headline: cross-doc edges 4 → 137 (33× lift), cross-doc node merges 2 → 2 (no change). SCE's natural ceiling on node merging is what ETR is designed to break through.

## Files for the next session to read first

1. This file
2. Companion plan: `atlas/audits/2026-05-16_etr-step1-plan.md`
3. PRD §"Approach 2: Extract-Then-Resolve (ETR)" + §"Locked-in prep items — 2026-05-16" in `atlas/prds/2026-05-15_4-level-knowledge-graph.md`
4. SCE findings (for A/B context): switch to `feature/sce-cross-doc` and read `atlas/audits/2026-05-16_sce-step1-findings.md`
5. `git log --oneline -5` on `feature/etr-cross-doc` to confirm the 3-commit lead is still there

## Outstanding (unrelated to ETR — for awareness)

These bugs / followups are tracked elsewhere; do NOT confuse with ETR work:

- **Orphan-sweep deletes valid graphs on app restart** — confirmed during SCE verification. User-facing data-loss bug. Best fixed on `main`, not on either feature branch. See SCE findings doc.
- **Per-doc files not written when `projectID` is set** — pipeline takes either-or save path. May or may not matter; audit when convenient.
- **40-pair quality rubric not in PRD** — blocks A/B verdict. Highest-priority "before the next big push" item. Pairs were discussed but never written down.
