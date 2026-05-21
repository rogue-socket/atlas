# Hybrid cross-doc resolver — 2026-05-22

Branch `feature/hybrid-cross-doc` (off `main`). A third cross-doc merging
approach alongside SCE and ETR, plus an embedding-free path so it runs
Claude-only.

## Why a third approach

A review of SCE and ETR found each has one dominant, fixable weakness:

- **SCE** — the merge depends on the LLM copying a prior node's label
  verbatim from a list that grows every document; ~62–74% of reuse claims
  on Pro reference labels that don't exist and are silently dropped. The
  cumulative-state prompt header also grows unbounded (no token guard).
- **ETR** — recall is capped *before* the LLM runs: ~12 of 20 should-merge
  rubric pairs sit below the 0.80 cosine floor, so they never reach the
  adjudicator — which is otherwise the strong part (92–100% precision).

The hybrid takes ETR's architecture (the stronger base — cheap to re-tune,
no quadratic prompt) and folds in SCE's one keeper: the typed-relation
taxonomy. SCE's cumulative-prompt mechanism was deliberately *not* carried.

## Design

**ETR backbone + SCE typed-relation taxonomy.** ETR's adjudicator decided
only merge/keep and discarded every "related but distinct" pair. SCE's
`match_kind` taxonomy says those discards are often real relationships. The
hybrid adjudicator returns one of five verdicts per candidate pair:

- `merge` — same real-world entity; collapse the pair (unchanged ETR path).
- `instance_of` / `attribute_of` / `process_for` — keep both nodes, record
  a directed typed `GraphEdge`.
- `keep` — no relationship.

Three new `EdgeType`s back the typed verdicts: `.instanceOf`,
`.attributeOf`, `.processFor`.

## Implementation

- `Atlas/Models/ConceptTypes.swift` — 3 new `EdgeType` cases (+ displayName/color).
- `Atlas/AI/Embeddings/EmbeddingResolver.swift` — `AdjudicationVerdict`,
  `PairDirection`, `AdjudicationResult`, `RelationDecision`;
  `MergePlan.relations`; `resolve()` routes verdicts to merges + relations.
- `Atlas/AI/PromptTemplates.swift` — `mergeAdjudicationHybrid` (v4 catalog +
  typed verdicts + direction) and `parseHybridAdjudicationResponse` — a
  lenient object-array parser keyed by 1-based pair index, no hard-fail on a
  length mismatch (unlike the old positional bool parser).
- `Atlas/AI/Embeddings/EmbeddingMergeApplier.swift` — stage 4 materializes
  `plan.relations` as typed edges, endpoints remapped through the merge
  idRemap, self-relations dropped, deduped against rewritten edges.
- `HeadlessRunner.swift` — `--hybrid-resolve <dir>` self-contained e2e mode
  (loads + merges per-doc graph JSON; no project or bookmarks needed).

## Embedding-free lexical path (Claude-only)

ETR's stage-2 candidate generation needs embeddings. With the project
Claude-only and Gemini blocked (below), `EmbeddingResolver.resolveLexical`
generates candidate pairs by shared-label-token Jaccard instead of cosine,
then runs the same hybrid Claude adjudication. `HeadlessRunner --lexical`
routes through it. Runs entirely on the Claude sidecar — no embedding
provider, no quota.

## Verification

- **234 unit tests pass** (full suite), incl. 18 `HybridResolverTests`
  (verdict parser, verdict→EdgeType mapping, typed-relation application +
  endpoint remapping, resolve-produces-relations, direction, lexical
  candidate generation).
- **End-to-end run on the Claude sidecar** (`--hybrid-resolve <dir>
  --lexical`, Opus): 4 per-doc graphs → 205 nodes / 239 edges merged → 60
  lexical candidates → 4 Claude adjudication batches → 0 merges, **4 typed
  relations** → applied → 205n / 243e. Zero Gemini calls.

The 0-merge / 4-relation result demonstrates the pipeline end to end; it is
**not** a quality benchmark. The lexical candidate set is weaker than
embedding-based, and Claude correctly typed 4 token-overlap pairs as
relationships rather than forcing merges.

## The Gemini blocker

The first e2e attempt (embedding-based ETR path) died at the embedding call:
`HTTP 429 RESOURCE_EXHAUSTED` — **the Gemini API project's monthly spending
cap is exhausted.** Not a rate limit; it does not clear on retry or by
switching models, and it blocks the embedding endpoint too. No alternative
embedding provider is available (Claude has no embedding API; Ollama is not
installed; no OpenAI key). The lexical path is the response — it removes the
embedding dependency entirely.

## Open items

- 3-way comparison (SCE / ETR / hybrid) on a shared corpus + rubric — still
  pending. The ETR/SCE arms need a working embedding provider; the hybrid
  arm can run today via `--lexical`.
- The lexical candidate generator is demonstration-grade (token Jaccard,
  sorted, capped at 60). A production candidate channel would add structural
  signals (shared edges, acronym expansion) or restore embeddings.
- Branch not pushed; not merged to `main`. Relation to Decision #11
  ("winner merges to `main`") undecided.
