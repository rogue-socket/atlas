# ETR Session Summary — 2026-05-16

> **Branch:** `feature/etr-cross-doc` at `b10b163` (13 ahead of `main`, NOT pushed)
> **Companion docs (all on this branch):**
> - `audits/2026-05-16_etr-step1-status.md` — initial status + 5 design questions, all resolved
> - `audits/2026-05-16_etr-step1-plan.md` — initial file-touch plan
> - `audits/2026-05-16_etr-live-verification.md` — live run + threshold sweep results
> - `prds/2026-05-15_4-level-knowledge-graph.md` §"Quality Rubric v2" — frozen scoring rubric
> **Cross-branch reference:** `feature/sce-cross-doc` at `8c69c32` — SCE step 1 (parallel approach), also not pushed

## What this doc is

A single-page index of everything that landed in the 2026-05-16 ETR session. Read this first if you're coming back cold and need to understand what's in place before adding anything.

## What got built

ETR (Extract-Then-Resolve) cross-doc node merging, end-to-end. Four stages of the design (per PRD §"Approach 2") realized in code:

1. **Stage 1 — Independent per-doc extraction.** Unchanged; uses the existing `ExtractionPipeline`. No new code.
2. **Stage 2 — Embed + pool** (`Atlas/AI/Embeddings/`). Already landed in prior session: `AtlasEmbeddingBackend` protocol, `GeminiEmbeddingBackend`, `EmbeddingMath.cosineSimilarity`, `AIServiceManager.createEmbeddingBackend()` factory.
3. **Stage 3 — Tiered resolution** (this session): `EmbeddingResolver` with pure helpers + async orchestrator + `EmbeddingCache` per-project on-disk cache + `PromptTemplates.mergeAdjudication` for LLM batched adjudication.
4. **Stage 4 — Apply merges** (this session): `EmbeddingMergeApplier` with union-find transitive closure, canonical pick rule, anchor union, edge rewrite + dedup.

Plus: headless harness `--etr` / `--etr-only` flags with CLI threshold overrides, 40-pair quality rubric (v1 and v2) in the PRD, live verification on vitacare with threshold sweep, three follow-up commits (default bump, retry-with-backoff, structured audit JSON sidecar).

## Commit chain (12 commits since `4736993`)

```
b10b163 EmbeddingResolver: structured per-pair audit trail JSON sidecar
f87fc60 PRD: Quality Rubric v2 — clean cross-doc tables grounded in real extraction
812f7e1 EmbeddingResolver: default adjudicationFloor 0.85→0.80 + retry on LLM failure
864eb68 Audit: ETR threshold sweep 0.85/0.80/0.75 — recommend 0.80 default
cdb875b Audit: ETR live verification on vitacare — 2/2 precision, ~17% recall
099a873 PRD: freeze 40-pair quality rubric (vitacare 2026-05-16)
b8bb570 HeadlessRunner: --etr / --etr-only flags + threshold overrides
8cc897d EmbeddingMergeApplier: ETR stage 4 — apply MergePlan in place
ab58592 EmbeddingResolver: ETR stage 3 pure helpers + async orchestrator
f275e43 EmbeddingCache: project-wide on-disk vector cache for ETR stage 3
3aff2fa PromptTemplates: mergeAdjudication prompt + response parser for ETR
be33ad9 Audit: lock in 5 ETR open questions before stage 3 code
```

## Code surfaces

### New files

| Path | Lines | Purpose |
|---|---|---|
| `Atlas/AI/Embeddings/EmbeddingCache.swift` | ~95 | Codable cache struct + `EmbeddingCacheStore` (load/save/retain) |
| `Atlas/AI/Embeddings/EmbeddingResolver.swift` | ~420 | Pure helpers + result types + async orchestrator + audit + retry |
| `Atlas/AI/Embeddings/EmbeddingMergeApplier.swift` | ~165 | Stage 4 — applies `MergePlan` to graph |
| `pdf_app1Tests/EmbeddingCacheTests.swift` | 8 tests | Cache round-trip + on-disk |
| `pdf_app1Tests/EmbeddingResolverTests.swift` | 25 tests | Pure helpers + prompt parser |
| `pdf_app1Tests/EmbeddingResolverOrchestratorTests.swift` | 14 tests | Async path (fake backends) + retry + audit |
| `pdf_app1Tests/EmbeddingMergeApplierTests.swift` | 11 tests | Stage 4 mutation + edge dedup |
| `pdf_app1Tests/HeadlessRunnerConfigTests.swift` | 14 tests | CLI flag parsing |
| `audits/2026-05-16_etr-live-verification.md` | — | Run results + threshold sweep |
| `audits/2026-05-16_etr-session-summary.md` | — | This doc |

### Modified files

| Path | Change |
|---|---|
| `Atlas/AI/PromptTemplates.swift` | +75 lines: `mergeAdjudication(pairs:)` + `parseMergeAdjudicationResponse(_:expectedCount:)` |
| `HeadlessRunner.swift` | +75 lines: `--etr` / `--etr-only` flags, `runETR` method, audit sidecar wiring |
| `audits/2026-05-16_etr-step1-status.md` | "Open questions" → "RESOLVED" with the 5 locked decisions |
| `prds/2026-05-15_4-level-knowledge-graph.md` | +200 lines: Quality Rubric v1 (with self-acknowledged structural flaws) + v2 (clean tables, cross-doc only, grounded in real extraction) |

### Test totals

**81 tests across the ETR-adjacent bundle, all green.**

| Suite | Count |
|---|---|
| EmbeddingTests | 9 (pre-existing) |
| EmbeddingResolverTests | 25 |
| EmbeddingResolverOrchestratorTests | 14 |
| EmbeddingCacheTests | 8 |
| EmbeddingMergeApplierTests | 11 |
| HeadlessRunnerConfigTests | 14 |

## Locked-in design decisions

| # | Decision | Reasoning |
|---|---|---|
| 1 | One JSON cache per project: `Atlas/graphs/embeddings_<projectID>.json` | Mirrors GraphStore's per-project file pattern. Access pattern is "all-at-once for pairwise comparison" — one read beats N reads. |
| 2 | Top-level model+dim invalidation; per-entry SHA-256 content hash | Guards against mixing embedding models; partial invalidation when individual node label/summary changes |
| 3 | Embedding text: `"<label>: <type> <summary>"`, drop summary when nil | No synthetic `"(no summary)"` placeholder (would pool nil-summary nodes in vector space). Empirical: 0 of 246 vitacare nodes have nil summary — defensive case only |
| 4 | Pair scope: cross-doc only (skip identical source-doc sets) | A/B symmetry with SCE; "extending to in-doc later is a one-line filter change" |
| 5 | Levels: only concept+entity eligible; document/chapter never; cross-level promotes to higher | Document = filename label (no semantic match); chapter = container. Cross-level catches LLM inconsistency where same real-world thing lands at different abstraction level |
| 6 | Thresholds: `ResolverThresholds` struct, PRD defaults baked in, CLI overridable | Tuning loop is dev-only in v1 — no UI debt. Audit-friendly: each run logs its thresholds |
| 7 | Default `adjudicationFloor` 0.85 → 0.80 (bumped 2026-05-16 PM after sweep) | Doubled merges over 0.85 with no precision cost; caught rubric row 8 (care-coordinator cluster) |
| 8 | Retry-with-backoff (1s, 3s; 3 attempts) on `generateRawResponse` | Transient Gemini "network connection was lost" lost a multi-minute 0.70 sweep run. Logical errors bypass retry |
| 9 | Audit JSON sidecar opt-in via `auditOutputDir: URL?` | Privacy-redacted logs hid which pairs the LLM rejected. Sidecar gives inspectable per-pair record. Best-effort — failure logs but doesn't throw |
| 10 | Canonical pick: higher `NodeLevel` → oldest `lastModified` → lowest UUID | Level promotion per PRD; oldest preserves original over merged-in additions; UUID for determinism |
| 11 | Snapshot+clear all edges before node removal in applier | `KnowledgeGraph.removeNode` cascades to connected edges; caught during test writing |

## Live verification on vitacare (test_proj, 218 eligible nodes, 17,810 cross-doc pairs)

| `--adj-floor` | Cold/warm | Candidates | LLM batches | Approved | Merges | Post graph |
|---|---|---|---|---|---|---|
| 0.85 (old default) | cold 22s / warm 13s | 5 | 1 | 2 (40%) | 2 | 244n/750e |
| **0.80 (new default)** | cold 57s / warm est. 45s | 50 | 3 | 4 (8%) | 4 | 242n/750e |
| 0.75 | warm ~3min | 387 | 22 | 9 (2.3%) | 9 | 237n/741e |
| 0.70 | — | est. 1000+ | RUN FAILED | — | — | baseline (pre-apply failure) |

**Precision: 100% across all three completed runs.**

**Recall against Rubric v2 (20 cross-doc should-merge pairs):**

| Floor | Caught | Recall |
|---|---|---|
| 0.85 | 2/20 (rows 1, 2) | 10% |
| 0.80 | 5/20 (rows 1, 2, 4, 5, 7-partial) | 25% |
| 0.75 | 8/20 (rows 1, 2, 4, 5, 6, 7, 10 + debatable 14) | 40% |

Headroom is clearly on **recall**, not precision.

## Major correction to prior session docs

**`GraphMergeEngine` is dormant code.** `MergeProposalView` is never instantiated anywhere in the active codebase. Prior session wraps (early 2026-05-16) attributed the 2 baseline cross-doc shared nodes to "GraphMergeEngine (Levenshtein > 0.5)". That's wrong. The 2 shared nodes come from `KnowledgeGraph.node(matching:)` doing case-insensitive exact-label match inside the shared project graph.

**Implication:** Integration decision #2 ("disable `GraphMergeEngine` during A/B runs") is a no-op. The baseline has been exact-label-only all along. The 2 ETR merges measured today are pure semantic value-add over that baseline — exactly what the design predicted.

**ETR vs SCE design prediction confirmed:**
- SCE Run 2: 137 cross-doc edges (33× lift), 2 shared nodes (unchanged from baseline) — wins on edges via prior-doc prompt context
- ETR Run today: 0 new cross-doc edges (doesn't propose edges), +2 shared nodes (+100% over baseline) — wins on node merges via embedding semantics

Combine the two in production, not pick a winner.

## What's NOT done

1. **Branches not pushed.** Both `feature/sce-cross-doc` (8 commits) and `feature/etr-cross-doc` (13 commits) are local-only. Push needs explicit user sign-off (visible action).
2. **No audit sidecar generated yet.** Audit logging landed after the sweep. Next `--etr-only` run will produce one. Useful for prompt-tuning the adjudication template based on what the LLM rejected.
3. **No recall-improvement experiments.** Each is its own session, API-cost-heavy. Candidates: prompt tuning, embedding model swap, per-level threshold split, in-doc pair support.
4. **Side-track bugs on `main` untouched all session.** (a) Orphan-sweep deletes valid graphs when bookmark fails to resolve at startup — data-loss bug. (b) Per-doc save dormant when `projectID` is set.
5. **Pre-α carries unchanged.** Annotation corner/edge resize (active since 2026-05-12), `rogue-socket/issue-11` guided tour port, B3 Stage 2 band-Y clamp, L2 renderer style for aggregated edges.

## On-disk state after session

| File | State |
|---|---|
| `~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/project_<UUID>.json` | Restored to baseline 246n/753e |
| Same dir / `embeddings_<UUID>.json` | 218 entries, 8.57 MB, warm (next ETR run hits cache 218/218) |
| `/tmp/atlas_project_pre_etr_2026-05-16.json` | Pre-ETR backup, untouched |
| `/tmp/atlas_post_etr_floor080.json` | 0.80 sweep snapshot (242n/750e) |
| `/tmp/atlas_post_etr_floor075.json` | 0.75 sweep snapshot (237n/741e) |
| `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` | Gemini key, ready for future runs |

## How to resume (concrete commands)

```bash
# 1. Verify branch state
cd /Users/yashagrawal/Documents/pdf_projects/atlas/pdf_app1
git checkout feature/etr-cross-doc
git log --oneline -5  # should show b10b163 at HEAD

# 2. Build (if needed)
xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build

# 3. Run ETR with default thresholds, audit-on, against existing extraction
~/Library/Developer/Xcode/DerivedData/pdf_app1-*/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1 \
  --headless-extract --project test_proj --etr-only

# 4. Inspect logs
/usr/bin/log show --predicate 'subsystem == "com.atlas.pdf"' --info --last 5m | rg "ETR"

# 5. Inspect audit sidecar (new this session)
ls -la ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/etr_audit_*.json
python3 -c "import json; print(json.dumps(json.load(open('<path>')), indent=2)[:2000])"

# 6. Tune threshold (warm cache makes this cheap)
... --etr-only --adj-floor 0.78 --auto-merge 0.93

# 7. Restore baseline between sweep runs
cp /tmp/atlas_project_pre_etr_2026-05-16.json \
   ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/project_<UUID>.json
```
