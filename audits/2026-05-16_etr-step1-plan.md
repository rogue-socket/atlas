# ETR Step 1 — Implementation Plan (2026-05-16)

> ⚠️ **STALE as of 2026-05-16 PM.** This plan was the file-touch list before stages 3+4 landed. Everything in the plan has shipped (and more). For current state read **`audits/2026-05-16_etr-session-summary.md`**; for sweep results read **`audits/2026-05-16_etr-live-verification.md`**. This plan is preserved as historical record of the pre-implementation thinking.

> **Branch:** `feature/etr-cross-doc` (this doc lives here, not on `main`)
> **Baseline:** `main` at `8225e37` (same as SCE branch)
> **Cherry-picked:** `e1cf898` (headless harness + dev-keys) from SCE branch — pure tooling, no SCE semantics
> **Authoritative spec:** `atlas/prds/2026-05-15_4-level-knowledge-graph.md` §"Approach 2: Extract-Then-Resolve (ETR)" + §"Locked-in prep items — 2026-05-16"

## Goal

Implement ETR — the second cross-doc merging approach — so it can be A/B'd against SCE on the vitacare corpus. ETR runs **after** independent per-doc extraction; it does NOT modify the prompt or per-doc pipeline. The work is a separable post-processing pass.

## Architecture (4 stages, per PRD)

1. **Independent per-doc extraction.** Existing `processPages` pipeline, no SCE header. Run for each doc, save per-doc graphs as today.
2. **Embed + pool.** For every node in the project-wide graph, build the embedding text (`label + ": " + type + summary`), call the embedding backend in batches, store the vectors keyed by node UUID.
3. **Tiered resolution.** Brute-force all pairs (n²/2 for n nodes — at ~250 nodes, that's 31k pairs; cheap with vector ops). For each pair, compute cosine similarity:
    - `sim ≥ 0.95` OR exact label match (case-insensitive) → auto-merge
    - `0.85 ≤ sim < 0.95` → batched LLM adjudication (15-20 pairs/call)
    - `sim < 0.85` → auto-reject (no merge)
4. **Apply merges.** Pick a canonical UUID per merge group; rewrite anchors / edges / canonical label to that UUID. Promote level if any constituent node is higher (concept > entity). Dedup edges by tuple.

## What ETR step 1 covers (this work)

Just stage 2 + the supporting embedding infrastructure. Stage 3 / 4 come in later slices once stage 2 is solid.

### File-touch list for step 1

| File | Change |
|---|---|
| `Atlas/AI/Embeddings/AtlasEmbeddingBackend.swift` | NEW. Protocol `AtlasEmbeddingBackend { func embed(_ texts: [String]) async throws -> [[Float]]; var displayName, modelIdentifier, vectorDimension: Int { get } }`. |
| `Atlas/AI/Embeddings/GeminiEmbeddingBackend.swift` | NEW. Hits `text-embedding-2-preview` via `https://generativelanguage.googleapis.com/v1beta/models/{model}:batchEmbedContents?key=...`. Batches up to 100 texts per call (Gemini limit). Returns `[[Float]]` parallel to input. |
| `Atlas/AI/Embeddings/EmbeddingMath.swift` | NEW. Pure `func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float`. Brute-force pairwise candidate generator helper to come in step 2. |
| `Atlas/AI/AIServiceManager.swift` | Add `selectedEmbeddingBackendType: AIBackendType?` (nil = none) and `selectedEmbeddingModel: String` (default `"gemini-embedding-2-preview"`), persistent via UserDefaults `atlas.ai.embedding.backendType` / `.model`. New `createEmbeddingBackend() -> (any AtlasEmbeddingBackend)?` factory. |
| `Atlas/AI/AtlasLogger.swift` | Add `embedding` category. |
| `pdf_app1Tests/EmbeddingTests.swift` | NEW. Unit tests for: cosine similarity (orthogonal=0, identical=1, opposite=-1, dimension-mismatch=throws); `GeminiEmbeddingBackend` mock for `embed()` shape (one input → one vector, etc.); no live API hit in unit tests. |

### Out of scope for step 1 (deferred to later slices)

- Stage 3 (resolution thresholds + LLM adjudication)
- Stage 4 (apply merges to graph)
- Settings UI for embedding model selector
- OpenAI / Ollama embedding backends (Gemini-only v1 per integration decision #4 symmetry)
- Trigger via headless harness (`--etr` flag) — comes after stage 3/4 land

### Open questions to confirm before stage 3

1. **Where does the embedding cache live?** Per-project? Per-doc? On disk so re-runs don't re-embed unchanged nodes? Recommend: project-wide JSON keyed by `nodeID:contentHash`, in the existing graphs directory.
2. **What's "the embedding text"?** PRD says `label + ": " + type + summary`. Confirm — does summary missing/nil break anything? Recommend: `summary ?? "(no summary)"`.
3. **Brute-force vs blocking?** PRD says brute-force pairwise. At ~250 nodes per project, 31k pair evaluations × 1 cosine op = trivial. No blocking strategy needed unless corpus scales.
4. **Cross-doc vs in-doc pairs?** Should ETR only merge cross-doc pairs (matching SCE's natural scope), or also allow merging within a single doc? Recommend: cross-doc only for symmetry, in-doc dedup is already handled by `graph.node(matching:)`.

### Verification plan (when all 4 stages land)

Same harness pattern as SCE:
1. Wipe vitacare graphs
2. Run headless extract in **independent mode** (no SCE header) — this is just baseline 4-PDF extraction
3. Trigger ETR resolver — separate command or `--etr` flag
4. Compare against SCE Run 2's headline metrics (137 cross-doc edges, 2 shared nodes) — ETR's value-add should show as MORE shared nodes (semantic merging via embeddings catches what exact-label-match misses)
5. Score against the 40-pair quality rubric — but THE RUBRIC IS STILL NOT WRITTEN in the PRD. Block ETR scoring on freezing that.

## Cost expectations (rough)

- Embedding: Gemini `gemini-embedding-2-preview` at 3072-dim. ~250 nodes × 1 embed call each (in batches). Cost: ~free at this scale.
- LLM adjudication: batched 15-20 pairs/call. If 100 pairs hit the 0.85-0.95 band, that's ~5-7 LLM calls. ~5k-7k tokens. Cheap.
- Total ETR overhead per project run: ~10k tokens, ~30s wall-clock. Much cheaper than SCE's 22k tokens / 17min.

## Risk register

1. **Gemini embedding API contract drift** — `gemini-embedding-2-preview` is preview, may change. Have `gemini-embedding-001` as fallback (per locked-in prep items). Will hardcode primary in v1, add fallback retry later if 2-preview returns 5xx.
2. **Pairwise resolution exploding on large projects** — fine at ~250 nodes; would need blocking at >5k nodes. Out of scope for v1.
3. **Threshold tuning** — 0.95 / 0.85 are placeholders per PRD. Re-tuning is cheap (re-run stages 2-4, no re-extraction). v1 ships defaults; tune from real vitacare data.
4. **Type-canonicalization** — when merging nodes with different types (e.g., concept vs entity), pick the higher level. PRD's "level promotion" addresses this. Implement in stage 4.

## Pickup for resuming this work

1. Read this plan
2. Read PRD §"Approach 2: Extract-Then-Resolve (ETR)" + §"Locked-in prep items — 2026-05-16"
3. Check `git log --oneline -5` on `feature/etr-cross-doc` to see what's landed
4. Step 1 implementation lands as separate commits per file
