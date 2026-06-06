# Decisions

Durable architectural and methodological decisions for this project, with rationale. Each entry: dated heading, the decision in one line, then **Why:** and **How to apply:** lines. Append-only — supersede old entries with new ones rather than rewriting.

## 2026-05-22 — Claude is the sole AI backend; Gemini dropped

All AI-pipeline work (extraction, cross-doc resolution) and every test run uses the Claude sidecar (`AIBackendType.claudeSubscription`). Gemini is no longer used.

**Why:** The Gemini API project hit its monthly spending cap — `HTTP 429 RESOURCE_EXHAUSTED`, which does not clear on retry or by switching models and which also blocks the embedding endpoint. The Claude sidecar (subscription auth, no API key) is unaffected.

**How to apply:** Run extraction/adjudication through the Claude sidecar (`http://127.0.0.1:8765`); do not add Gemini to a test path. Embedding-dependent ETR has no usable provider (Claude has no embedding API; Ollama not installed) — use the hybrid resolver's embedding-free `--lexical` path.

## 2026-05-22 — Hybrid is a third cross-doc approach (ETR backbone + SCE taxonomy)

`feature/hybrid-cross-doc` adds a third approach beside SCE and ETR: ETR's extract-then-resolve pipeline with SCE's typed-relation taxonomy folded into the adjudicator.

**Why:** A review found ETR is the stronger architecture (cheap to re-tune, no quadratic prompt) but discards every "related but distinct" pair; SCE's one keeper is its `match_kind` taxonomy, which names those relationships. The hybrid adjudicator returns `merge / instance_of / attribute_of / process_for / keep` — merges collapse nodes, the three typed verdicts become directed edges. SCE's cumulative-prompt mechanism was deliberately not carried.

**How to apply:** Decision #11's "build SCE + ETR, A/B, winner merges to `main`" now spans three approaches — any cross-doc A/B must include the hybrid arm. Detail: `audits/2026-05-22_hybrid-cross-doc.md`.
