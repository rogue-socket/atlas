# Glossary

Project-specific shorthand: jargon, acronyms, internal IDs, module names that an outside agent wouldn't recognize. Each entry: term, one-line definition, optional reference to where it's used (e.g., `see pam/retrieval/ranker.py`).

- **SCE** — Sequential Cumulative Extraction. Cross-doc approach: each doc's extraction batches carry cumulative state (all prior-doc nodes) so the LLM reuses entities instead of duplicating. Branch `feature/sce-cross-doc`.
- **ETR** — Extract-Then-Resolve. Cross-doc approach: extract docs independently, then embed + brute-force pairwise-compare + LLM-adjudicate near-duplicate pairs. Branch `feature/etr-cross-doc`; see `Atlas/AI/Embeddings/`.
- **Hybrid resolver** — Third cross-doc approach, `feature/hybrid-cross-doc`: ETR's pipeline with SCE's typed-relation taxonomy in the adjudicator. See `audits/2026-05-22_hybrid-cross-doc.md`.
- **Typed relation** — A hybrid-adjudicator verdict other than merge/keep: `instance_of` / `attribute_of` / `process_for`, materialized as a directed `EdgeType` between two nodes that are related but not the same thing.
- **Lexical candidate path** — Embedding-free candidate generation for the hybrid resolver: cross-doc pairs scored by shared-label-token Jaccard. `EmbeddingResolver.resolveLexical`, `HeadlessRunner --lexical`. Runs Claude-only, no embedding provider.
- **Claude sidecar** — `claude-sidecar/server.mjs`, a local Node HTTP server (port 8765) wrapping the `claude` CLI headless. `AIBackendType.claudeSubscription`. The project's sole AI backend as of 2026-05-22.
- **vitacare** — The 4-PDF cross-doc test corpus (`sample_pdfs/files/vitacare_*.pdf`).
