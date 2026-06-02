# Cross-Document Extraction Branch Comparison

Date: 2026-06-01

Branches inspected:

- `feature/sce-cross-doc` at `f56716e` in `/Users/yashagrawal/Documents/pdf_projects/atlas`
- `feature/etr-cross-doc` at `fa0bce9` in `/Users/yashagrawal/Documents/pdf_projects/atlas-etr-cross-doc`
- `feature/hybrid-cross-doc` at `7272f09` in `/Users/yashagrawal/Documents/pdf_projects/atlas-hybrid-cross-doc`

Important caveat: this is not a fresh apples-to-apples benchmark. The evidence below combines branch code inspection, existing audit runs, recent SCE run analysis, and previous headless evals. The ETR and Hybrid sibling worktrees currently contain uncommitted LAN embedding-gateway changes, and live model comparison is blocked until the gateway at `http://192.168.1.14:8200/v1` is reachable.

## Executive Summary

Atlas now has three distinct approaches to cross-document graph quality:

1. **SCE: Sequential Cumulative Extraction** (`feature/sce-cross-doc`)
   Each document is extracted while the model sees prior-document graph context. It can directly reuse labels, create same-entity merges, and create typed cross-document relationship edges during extraction.

2. **ETR: Extract Then Resolve** (`feature/etr-cross-doc`)
   Documents are extracted independently. A later resolver embeds eligible concept/entity nodes, generates cross-document candidate pairs, asks an LLM to adjudicate ambiguous pairs, and applies node merges.

3. **Hybrid: ETR Backbone + SCE Relationship Taxonomy** (`feature/hybrid-cross-doc`)
   Documents are still extracted independently, but the resolver can return either `merge`, `keep`, or typed relation verdicts (`instance_of`, `attribute_of`, `process_for`). It preserves ETR's post-pass architecture while keeping SCE's non-equivalence relationship signal.

The current evidence supports a combined direction, not a single winner:

- **SCE is strongest at adding relationship density** because it lets the extraction model say "this new item is an instance/attribute/process of a prior item" while it is reading the source text.
- **ETR is strongest at controlled same-entity node merging** because candidates, thresholds, audits, and merge application are separate and testable.
- **Hybrid is the best production shape if backed by good candidate generation** because it can separate "same thing" from "related thing" after extraction. Its current lexical fallback proves plumbing, not quality.

The recommended target is: independent per-document extraction, embedding-backed candidate generation, hybrid adjudication, and typed relation display. SCE should remain useful as a relationship-discovery experiment or optional deep mode, but the cumulative prompt should not be the only production merge mechanism.

## Common Baseline

All branches depend on the same base graph model:

- PDF pages are extracted in batches.
- The model returns document/chapter/concept/entity-like output.
- `ExtractionPipeline` anchors raw concepts/entities back to source text.
- `KnowledgeGraph.node(matching:)` performs exact lowercase-label reuse when adding nodes to the live graph.
- Concept/entity nodes are the semantic units that matter for cross-document merging and relationship formation.

This baseline exact-label reuse is important. Some older notes that attributed cross-document baseline merges to `GraphMergeEngine` were wrong; the dormant merge engine is not the active mechanism. Baseline cross-document sharing mostly happens when identical labels are emitted and the live graph's label index reuses the node.

## Branch 1: SCE

### How It Works

SCE changes the extraction loop itself. For document N > 1, `ExtractionPipeline` detects prior-document nodes in the live graph and builds a cumulative prior-docs header. That header is passed into every batch for the current document.

The prompt asks the model to use two optional fields:

- `prior_label_match`: a character-for-character copy of a prior label
- `match_kind`: one of `same_entity`, `instance_of`, `attribute_of`, `process_for`

During graph integration:

- `same_entity` resolves to a canonical-label lookup and can merge by reusing an existing node.
- The non-equivalence kinds keep both nodes and add typed cross-document edges.
- Invalid prior-label matches are discarded by parser/action resolution.
- Recent work also preserves extraction-response edges (Step 5.5) and runs an extra edge proposal pass over batch candidates (Step 6).

Relevant code surfaces:

- `Atlas/AI/ExtractionPipeline.swift`
- `Atlas/AI/PromptTemplates.swift`
- `Atlas/AI/AtlasModelProtocol.swift`
- `Atlas/Models/ConceptTypes.swift`
- `Atlas/Models/KnowledgeGraph.swift`
- `Atlas/Renderer/*` for displaying SCE cross-document relationship context
- `scripts/analyze_sce_run.py`

### Evidence

Earlier VitaCare SCE audit:

- Baseline: 214 nodes, 4 cross-doc edges, 2 shared nodes.
- Post-fix SCE: 246 nodes, 137 cross-doc edges, still 2 shared nodes.
- Stronger prompt increased prompt tokens roughly 30% but did not improve shared-node count.
- Step 3/v5 SCE with `prior_label_match` and `match_kind`: 8 same-entity shared nodes plus 46 typed edges, zero post-filter typed-edge errors in that audit.

Recent SCE relationship/display run:

- Full test suite passed: 386/386.
- Benchmark with Codex sidecar `gpt-5.3-codex-spark`: live graph 327 nodes / 499 edges versus prior Fast graph 314 nodes / 463 edges.
- Step 5.5 preserved 46/46 extraction-response edges.
- Step 6 added 77/77 proposal edges.
- Visual smoke showed semantic edge lines/labels and off-level entity endpoints.

Known sidecar/model behavior:

- `gpt-5.4-mini` regressed on cumulative SCE context in earlier pp1 runs: HTTP 504 around a large prompt and several multi-minute calls.
- `gpt-5.3-codex-spark` handled early SCE batches more stably in that evidence set.

### Strengths

- Captures relationships the app can render immediately, instead of relying only on node collapse.
- Natural fit for "related but not same" concepts, such as catalog-to-leaf, attribute-to-entity, process-to-program, and implementation-to-policy links.
- Low separate infrastructure: no vector store, no embedding model, no resolver pass required.
- Easy to debug through extraction logs: claims, renames, merges, and typed edges are logged per batch.
- Recent Step 5.5 and Step 6 work directly addresses the user's reported issue that extracted relationships were not the relationships shown in the app.

### Weaknesses

- Same-entity merging is structurally fragile because the model must copy a prior label exactly.
- The source `textSpan` requirement pulls labels toward current-document wording, while `prior_label_match` asks for exact prior wording. Those objectives conflict.
- Cumulative prompts grow with prior graph size. That increases latency, cost, truncation risk, and model anchoring.
- Sequential processing makes document order matter.
- A wrong early canonical label can anchor later outputs.
- The model may produce broad "related" claims that are not valid typed relationships unless direction and endpoint constraints are strict.
- Cross-document matching quality is hard to isolate because extraction, matching, and relationship formation happen in one LLM call.

### Scope Of Improvement

- Treat SCE primarily as relationship discovery, not as the main same-entity merge system.
- Keep using `5.3-codex-spark` for SCE sidecar runs until a newer sidecar model beats it on cumulative-context stability.
- Compress and rank the prior-doc header instead of passing a broad cumulative list. Include only likely prior candidates for the current document/batch.
- Add a hard budget for prior context by token count, not just line count.
- Separate same-entity claims from typed relationship claims in output validation and reporting.
- Add a post-pass verifier for typed edge direction. The current direction rule helps, but wrong-direction edges remain a known failure mode.
- Add corpus-level SCE evals that separately score:
  - exact/same-entity merges
  - typed relation precision
  - typed relation recall
  - display survival in the app
- Consider using SCE only in Deep mode, or as a second pass after independent extraction, so Fast mode stays cheaper and less order-sensitive.

## Branch 2: ETR

### How It Works

ETR keeps extraction independent, then resolves cross-document semantic duplicates afterward:

1. Collect eligible nodes: concepts and entities only.
2. Build embedding text as `label: type summary`.
3. Cache vectors by content hash, model identifier, and dimension.
4. Generate cross-document candidate pairs.
5. Classify each pair by cosine similarity:
   - exact label or high similarity can auto-merge
   - middle band goes to LLM adjudication
   - below floor is rejected
6. Apply merge decisions through `EmbeddingMergeApplier`.

The applier takes transitive closure, picks a canonical survivor, unions source anchors, rewrites edges, deduplicates edges, and removes merged-away nodes.

Relevant code surfaces:

- `Atlas/AI/Embeddings/EmbeddingResolver.swift`
- `Atlas/AI/Embeddings/EmbeddingCache.swift`
- `Atlas/AI/Embeddings/EmbeddingMergeApplier.swift`
- `Atlas/AI/Embeddings/EmbeddingMath.swift`
- `Atlas/AI/PromptTemplates.swift`
- `pdf_app1Tests/Embedding*Tests.swift`

### Evidence

VitaCare ETR sweep:

- Eligible nodes: 218.
- Cross-doc pairs: 17,810.
- Floor 0.85: 5 candidates, 2 approved merges, recall 2/20.
- Floor 0.80: 50 candidates, 4 approved merges, recall 5/20.
- Floor 0.75: 387 candidates, 9 approved merges, recall 8/20.
- Precision was 100% across completed runs in that audit.

Prompt tuning:

- Temperature/topK changes did not create deterministic Gemini behavior.
- Tuned adjudication prompt improved stability on the in-band hard subset.
- The tuned prompt carried VitaCare-specific examples, so generalization risk was explicitly noted.

Harvest Hearth holdout:

- 278 nodes, 246 eligible, 12,628 pairs.
- 106 in-band pairs at 0.80.
- v3 prompt: stable approvals 15, precision 93%, recall 70%, trap 10%.
- v4 prompt: stable approvals 11, precision 100%, recall 55%, trap 0%.
- v4 is safer but more conservative; v3 is more recall-oriented and corpus-dependent.

Embedding-gateway branch work:

- ETR now has local LAN OpenAI-compatible gateway support in the dirty sibling worktree.
- Configured models include `bge-base-en-v1.5`, `e5-base-v2`, `nomic-embed-text-v1`, and `all-minilm-l6-v2`.
- Cache files are namespaced by project, model, and dimension to avoid mixing 384-dim and 768-dim vectors.
- Live quality/latency numbers still require the LAN gateway to be reachable.

### Strengths

- Clear separation of concerns: extraction, candidate generation, adjudication, and merge application can be tested independently.
- Much better auditability than SCE for same-entity merges. Every interesting pair can carry similarity, band, LLM verdict, and final reason.
- Thresholds provide a practical precision/recall dial.
- Cache makes repeated evaluation cheaper after initial embedding.
- Merge application is deterministic and handles transitive groups, anchor union, edge rewrite, and edge dedupe.
- Candidate generation is not tied to document order.

### Weaknesses

- Recall is capped by candidate generation. If a true duplicate sits below the cosine floor, the LLM never sees it.
- Lowering the floor quickly increases candidate volume and adjudication cost.
- Embedding model choice materially affects results, and the historical evidence was constrained by Gemini spend/gateway availability.
- Pure node merging cannot preserve "related but not same" signals. If two nodes should stay separate but be linked, ETR's original merge/keep verdict loses that relationship.
- Prompt tuning can overfit one corpus. The VitaCare-tuned prompt did not generalize cleanly to Harvest Hearth.
- Requires more infrastructure than SCE: embedding backend, cache invalidation, threshold management, audit output, and optional LLM adjudicator.

### Scope Of Improvement

- Complete the LAN embedding-gateway live eval once reachable:
  - compare `bge-base-en-v1.5` against `all-minilm-l6-v2`
  - include `e5-base-v2` or `nomic-embed-text-v1` if available
  - report candidate counts, merge counts, precision/recall, latency, and failures
- Build a task-specific eval set of realistic app queries and expected nodes/actions so model choice is tied to downstream product quality, not only cosine pair recall.
- Add structural candidate features beyond embeddings:
  - shared parent/chapter context
  - acronym expansion
  - overlapping source spans
  - shared neighboring entities
  - normalized label aliases
- Keep prompt variants explicit: precision-biased default and recall-biased experimental mode.
- Track "should be related but not merged" pairs in the audit set. Those are exactly where original ETR under-expresses the graph.
- Surface resolver quality in app-visible diagnostics: number of eligible nodes, candidates, adjudications, merges, and dropped pairs.

## Branch 3: Hybrid

### How It Works

Hybrid keeps ETR's post-extraction resolver architecture but changes the LLM adjudication contract. For each candidate pair, the LLM returns:

- `merge`
- `keep`
- `instance_of`
- `attribute_of`
- `process_for`

Typed verdicts become directed `RelationDecision`s. `EmbeddingMergeApplier` materializes those as directed graph edges after merge remapping, dropping self-relations and deduplicating against existing edges.

Hybrid also has an embedding-free lexical mode:

- Tokenize labels.
- Drop stopwords and short tokens.
- Generate cross-doc pairs with shared significant tokens.
- Cap to the top lexical candidates.
- Run the same hybrid adjudicator.

Relevant code surfaces:

- `Atlas/AI/Embeddings/EmbeddingResolver.swift`
- `Atlas/AI/Embeddings/EmbeddingMergeApplier.swift`
- `Atlas/AI/PromptTemplates.swift`
- `pdf_app1Tests/HybridResolverTests.swift`
- Headless `--hybrid-resolve` / `--lexical` path

### Evidence

Hybrid branch audit:

- Full suite at the time: 234 tests.
- `HybridResolverTests`: 18 focused tests.
- Claude sidecar lexical E2E:
  - 4 per-doc graphs
  - 205 nodes / 239 edges before resolve
  - 60 lexical candidates
  - 4 Claude batches
  - 0 merges / 4 typed relations
  - 205 nodes / 243 edges after resolve

That run demonstrates end-to-end plumbing, relation materialization, and graph preservation. It does not prove quality because the lexical candidate generator is intentionally weak compared with embedding-backed candidates.

### Strengths

- Best conceptual fit for the user's current problem: many extracted relationships are not same-entity merges, and the app should show richer relationships than a collapsed duplicate graph.
- Preserves ETR auditability and determinism while adding SCE's typed relationship vocabulary.
- Avoids SCE's cumulative prompt growth and document-order dependence.
- Keeps "same thing" and "related thing" as separate verdicts.
- Can operate in lexical mode when embeddings are unavailable, which is useful for smoke tests and sidecar-only development.
- Merge applier correctly remaps relation endpoints through node merges before adding typed edges.

### Weaknesses

- Current quality evidence is thin. The lexical E2E is a pipeline proof, not a benchmark.
- Lexical candidates miss paraphrases and many semantic relationships.
- Embedding-backed Hybrid is blocked by the same embedding-provider availability problem as ETR.
- Typed relation precision and direction have not been measured as deeply as SCE's typed-edge audits or ETR's merge audits.
- The app/UI expectations for resolver-added typed edges need to be verified the same way SCE edge display was verified.
- It inherits ETR's candidate bottleneck: if the candidate generator misses a pair, the hybrid adjudicator cannot recover it.

### Scope Of Improvement

- Use the LAN embedding gateway as soon as reachable and run Hybrid on the same corpora as ETR.
- Compare Hybrid against ETR using both merge metrics and relation metrics:
  - correct merges
  - false merges
  - correct typed relations
  - wrong-direction typed relations
  - missed important relationships
  - app display survival
- Upgrade lexical fallback so it is more than a smoke path:
  - aliases and acronym expansion
  - token synonym tables from corpus summaries
  - parent/context token boosting
  - shared-neighbor signals
  - higher recall cap with cheap prefilters
- Add a relation-specific audit report, not just merge audit entries.
- Make relation confidence meaningful. Current relation confidence can come from candidate similarity, which is not always the same as relation correctness.
- Add UI labels/provenance for resolver-created relationships so users can distinguish extracted, proposed, and resolved edges.

## Cross-Branch Comparison

| Dimension | SCE | ETR | Hybrid |
| --- | --- | --- | --- |
| Primary output | Nodes + typed edges during extraction | Same-entity node merges after extraction | Merges + typed edges after extraction |
| Best current strength | Relationship density | Controlled duplicate collapse | Right abstraction for merge-vs-relation |
| Main bottleneck | Exact prior-label copying and cumulative context | Embedding candidate recall | Candidate quality and limited benchmark evidence |
| Order sensitivity | High | Low | Low |
| Infrastructure | Low | Medium/high | Medium/high |
| Auditability | Moderate; logs embedded in extraction | High | High if relation audit is added |
| Cost shape | Sequential LLM calls with growing prompt | Embedding pass + bounded LLM adjudication | Same as ETR; lexical fallback cheaper but weaker |
| App display fit | Strong after recent edge preservation/display work | Merge-focused; relationships underrepresented | Strong intended fit, needs app smoke verification |

## Improvement Priorities

### Priority 1: Make Hybrid The Main Product Direction

Hybrid should become the target architecture because it matches the domain distinction users care about:

- Some duplicate labels should merge.
- Some similar labels should stay separate but be related.
- Some labels should stay entirely separate.

SCE has already shown that typed relation vocabulary is valuable. ETR has already shown that post-pass resolution is more controllable. Hybrid combines those lessons.

### Priority 2: Finish Embedding-Gateway Evaluation

The ETR/Hybrid branches need real embedding-backed comparison before defaults are chosen.

Minimum eval:

- Same extracted project graph.
- Same candidate/adjudication settings.
- At least:
  - `bge-base-en-v1.5`
  - `all-minilm-l6-v2`
- Prefer also:
  - `e5-base-v2`
  - `nomic-embed-text-v1`

Report:

- embedding latency
- candidate count
- LLM adjudication count
- merge count
- typed relation count for Hybrid
- failures/errors
- manual/rubric quality on the app task

Do not mix vector dimensions or model namespaces. The dirty ETR/Hybrid gateway work already moves in the right direction by storing model, dimension, source metadata, chunk id, and chunk text with cached vectors.

### Priority 3: Define A Shared Evaluation Set

The audits are useful but not yet a durable benchmark. Add a small task-specific eval set:

- 20-100 realistic Atlas user queries.
- Expected matching nodes, documents, tools/actions, or graph paths.
- Expected merge/relation outcomes for known cross-document pairs.
- Separate labels for:
  - must-merge
  - must-keep
  - should-link
  - borderline

This is necessary because node/edge counts alone can be misleading. SCE can create many edges; ETR can preserve precision; Hybrid can add typed relations. The real question is whether the app retrieves, displays, and explains the right concepts.

### Priority 4: Keep SCE As Deep/Experimental Or Relationship Discovery

SCE should not be discarded. It found a real product gap: extracted relationship information was being lost or under-displayed. But SCE's cumulative context is expensive and brittle as the main production resolver.

Best near-term role:

- Deep extraction option.
- Relationship-discovery pass on selected documents.
- Source of relation taxonomy/prompt examples for Hybrid.
- Debugging baseline for what the extraction model sees when prior graph state is available.

## Concrete Next Steps

1. When the LAN gateway is reachable, run ETR and Hybrid with `bge-base-en-v1.5` and `all-minilm-l6-v2` on the same saved graph.
2. Add a relation audit for Hybrid that mirrors ETR's merge audit but records relation verdict, direction, endpoints, and source docs.
3. Add a small hand-labeled eval sheet from VitaCare and Harvest Hearth:
   - 20 must-merge pairs
   - 20 must-keep pairs
   - 20 should-link pairs
4. Run SCE, ETR, and Hybrid on the same corpus and report separate merge and relationship metrics.
5. Promote Hybrid only after embedding-backed candidate generation beats lexical fallback and app display verifies resolver-created typed edges.

## Bottom Line

The extraction problem is not just "merge more nodes." Atlas needs both entity resolution and relationship formation.

ETR is the better foundation for entity resolution. SCE is the better evidence source for relationship vocabulary and relationship density. Hybrid is the most promising shape because it can use ETR's controlled post-pass while preserving SCE's typed relationships.

The main unresolved work is not another prompt tweak. It is a shared eval set plus embedding-backed Hybrid/ETR comparison using the LAN gateway once reachable.
