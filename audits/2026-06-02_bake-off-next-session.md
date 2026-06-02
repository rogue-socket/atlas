# Bake-Off Next Session — START HERE

Date: 2026-06-02  
Purpose: cold-start guide after context clear. **Do not merge any branch to `main` yet.** Maximize SCE, Hybrid, and ETR independently, then compare.

Also read: `backlog.md` (`[active/next 2026-06-02]` entries), `audits/2026-06-01_extraction-branch-comparison.md`, `audits/2026-06-02_embedding-gateway-etr-hybrid-comparison.md`.

Workspace handoff (gitignored): `../handoffs/2026-06-02.md`

---

## Goal

Three cross-doc approaches compete on the same corpora with separate scorecards:

| Approach | Branch | Hypothesis |
|---|---|---|
| **SCE** | `feature/sce-cross-doc` | Cumulative extraction emits merges + typed relations while reading |
| **Hybrid** | `feature/hybrid-cross-doc` | Independent extract + post-pass resolver (merge **or** typed relation) |
| **ETR** | `feature/etr-cross-doc` | Independent extract + embedding merge resolver (identity focus) |

Pick a winner (or split product) **after** all three are tuned — not before.

---

## Repo layout (one repo, three worktrees)

```
pdf_projects/
  atlas/                   → feature/sce-cross-doc   @ f432989
  atlas-etr-cross-doc/     → feature/etr-cross-doc   @ 67ceb0b
  atlas-hybrid-cross-doc/  → feature/hybrid-cross-doc @ 230c1f2
  backlog.md               → symlink to atlas/backlog.md
  handoffs/                → gitignored session notes
```

Build (any worktree): `cd atlas/pdf_app1 && xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build`

---

## Locked next-session order

### 1. SCE first (`atlas/`)

**Worktree:** `/Users/yashagrawal/Documents/pdf_projects/atlas`  
**Branch HEAD:** `f432989` (direction verifier @ `e64a0df`; see git log)

**Already done:**
- Step 5.5/6 relationship extraction, map display, Codex spark sidecar
- Relevance-ranked prior header (`cumulativeStateHeader(relevanceText:maxLines:)`)
- Typed-edge direction verifier + log field `typed_rejected_direction=`
- SCETests 34/34; full suite was 386/386 on 2026-06-01

**Do next:**
1. Start Codex sidecar: `cd atlas/codex-agent-sidecar && python3 server.py` — use **`gpt-5.3-codex-spark`** (not gpt-5.4-mini; cumulative context regresses)
2. Headless SCE on `pp1` (Harvest Hearth 4 PDFs): built app `--headless-extract --project pp1 --mode fast`
3. Validate: `python3 atlas/scripts/analyze_sce_run.py /path/to/run-dir` (needs `atlas-run.log`, `sidecar.log`, `graphs-result/`)
4. Doc-order sensitivity: 3 doc-order permutations; report merge vs typed-edge variance separately
5. Optional: normalized-label `same_entity` fallback — do **not** try to beat ETR on merge recall inside SCE

**Key files:** `Atlas/AI/ExtractionPipeline.swift`, `Atlas/AI/PromptTemplates.swift`, `scripts/analyze_sce_run.py`

---

### 2. Hybrid second (`atlas-hybrid-cross-doc/`)

**Worktree:** `/Users/yashagrawal/Documents/pdf_projects/atlas-hybrid-cross-doc`  
**Branch HEAD:** `230c1f2`

**Already done:**
- LAN embedding gateway + headless lifecycle fixes (`a0019ec`)
- SCE relationship display ported
- Eval fixtures: `docs/evals/pp1-hybrid-adjudication-labels.json` (12 pairs, tune here)
- Holdout: `docs/evals/vitacare-hybrid-adjudication-labels.json` (10 pairs)
- Prompt baseline score **0.917** — prose prompt experiments **reverted** (all regressed)
- BGE default; Relationship Discovery preset smoke-tested

**Do next:**
1. Expand both eval JSON files to **30–50 pairs** before more prompt work
2. Frozen per-doc graphs → `--hybrid-resolve` with BGE:
   - Conservative preset (high precision, candidate-starved)
   - Relationship Discovery preset (tuned per-kind floors)
3. Add **structured post-adjudication validator** (unit-testable rules) — not more prompt examples
4. Relation audit sidecar (verdict, direction, endpoints, display survival)
5. Score with `HybridAdjudicationEvaluator` + app smoke on Concept map

**Embedding defaults:**
```sh
defaults write rogues.pdf-app1 atlas.ai.embedding.backendType EmbeddingGateway
defaults write rogues.pdf-app1 atlas.ai.embedding.model bge-base-en-v1.5
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.baseURL http://192.168.1.14:8200/v1
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.apiKey none
```

**Docs:** `docs/embedding-gateway-integration.md`

---

### 3. ETR third (`atlas-etr-cross-doc/`)

**Worktree:** `/Users/yashagrawal/Documents/pdf_projects/atlas-etr-cross-doc`  
**Branch HEAD:** `67ceb0b`

**Already done:**
- LAN gateway committed (`5e91b83`); BGE live eval done — see gateway comparison audit
- SCE display ported; VitaCare rubric + `--score-rubric` headless mode exists

**Do next:**
1. Per-kind threshold sweep on **VitaCare** (`--etr-only`, `--score-rubric`) — tune here
2. Validate best thresholds on **`pp1` holdout only** — do not tune on holdout
3. Structural candidate boosts (acronym, shared chapter, neighbor overlap)
4. Corpus-agnostic adjudication prompt (VitaCare-tuned prompt overfit Harvest Hearth)

**Do not use:** `e5-base-v2` or `nomic-embed-text-v1` at current `0.80/0.95` thresholds.

---

## Fair comparison contract

| Constant | Value |
|---|---|
| Tune corpus | VitaCare 4 PDFs (`sample_pdfs/files/vitacare_*.pdf`) |
| Holdout corpus | Harvest Hearth / project `pp1` |
| SCE adjudicator | Codex sidecar `gpt-5.3-codex-spark` |
| ETR/Hybrid embeddings | LAN gateway `bge-base-en-v1.5` |
| Metrics | Report **merge** and **typed-relation** separately |

---

## What not to do

- Merge any bake-off branch to `main` until comparison is complete
- Use lexical-only Hybrid runs for final bake-off scores (smoke/plumbing only)
- Add Hybrid prompt prose without expanding eval first (regressed below 0.917)
- Use `gpt-5.4-mini` for SCE cumulative-context runs
- Tune ETR/Hybrid thresholds on holdout (`pp1`)

---

## 2026-06-02 session commits (reference)

| Branch | Commits |
|---|---|
| SCE | `e64a0df` direction verifier, `0de5d74` audits, `3fac54c` backlog, `f29ff07` cold-start doc |
| ETR | `5e91b83` gateway, `67ceb0b` display port |
| Hybrid | `a0019ec` gateway+eval, `230c1f2` display+VitaCare labels |
