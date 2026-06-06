# Embedding Gateway ETR/Hybrid Comparison

Date: 2026-06-02

Scope: compare the LAN embedding gateway models on the existing `pp1` Harvest Hearth graph set. This is a resolver/candidate-generation comparison over the same already-extracted graph, not a fresh PDF extraction benchmark.

Gateway:

- Base URL: `http://192.168.1.14:8200/v1`
- Endpoint: OpenAI-compatible `POST /v1/embeddings`
- Source: `lv:/opt/embedding-gateway/app.py`
- Service: `lv` system service `embedding-gateway.service`, enabled and active

Input graph:

- Project: `pp1`
- Corpus: 4 Harvest Hearth PDFs
- Decoded graph files: 4 per-doc graph JSONs from the app container
- Eligible nodes: 136
- Levels: 108 entities, 28 concepts
- Cross-document pairs evaluated: 5,846
- Embedding text shape: `label: type summary`
- Thresholds: `autoMerge=0.95`, `adjudicationFloor=0.80`

## Model Results

| Model | Dim | Embed Time | Auto-Merge Candidates | Adjudication Candidates | Assessment |
| --- | ---: | ---: | ---: | ---: | --- |
| `bge-base-en-v1.5` | 768 | 3.27s | 0 | 2 | Best default candidate. Small, plausible candidate set. |
| `all-minilm-l6-v2` | 384 | 2.40s | 0 | 1 | Good fast baseline. Lower recall than BGE on this graph. |
| `e5-base-v2` | 768 | 2.88s | 1 | 5,329 | Not usable with current thresholds; similarity distribution is too compressed/high. |
| `nomic-embed-text-v1` | 768 | 3.47s | 1,555 | 4,291 | Not usable with current thresholds; almost every cross-doc pair becomes interesting. |

## Candidate Details

### `bge-base-en-v1.5`

Adjudication candidates:

- `Revenue share` <-> `E-commerce revenue share`, similarity `0.8849`
- `Hardwood sourcing` <-> `FSC wood sourcing`, similarity `0.8317`

No auto-merge candidates.

### `all-minilm-l6-v2`

Adjudication candidates:

- `Revenue share` <-> `E-commerce revenue share`, similarity `0.9077`

No auto-merge candidates.

### `e5-base-v2`

Top candidates:

- `Revenue share` <-> `E-commerce revenue share`, similarity `0.9759`, auto band
- `E-commerce revenue share` <-> `Revenue channel split`, similarity `0.9455`
- `Repair and event workshops` <-> `Repair workshops`, similarity `0.9444`
- `Hardwood sourcing` <-> `FSC wood sourcing`, similarity `0.9369`

The good pairs are present, but they are buried in 5,330 interesting pairs. This model would need separate threshold calibration, likely far above `0.95`, before it can be used for ETR/Hybrid.

### `nomic-embed-text-v1`

Top candidates include obvious false positives such as:

- `Personal care line` <-> `Apprentice program`, similarity `0.9818`
- `Customer service operations` <-> `Program scope`, similarity `0.9812`
- `Email responsiveness` <-> `Premium shift pay`, similarity `0.9812`

This model is not compatible with the current cosine thresholds. It may still be useful with normalization or model-specific thresholds, but it should not be the default.

## ETR vs Hybrid Implication

ETR and Hybrid share the same embedding candidate bottleneck. On this graph, the gateway-backed candidate generator says:

- BGE gives Hybrid two useful opportunities:
  - one likely same-entity merge: `Revenue share` / `E-commerce revenue share`
  - one likely typed relationship or possible merge: `Hardwood sourcing` / `FSC wood sourcing`
- MiniLM finds the obvious revenue-share pair but misses the sourcing pair at the current floor.
- E5 and Nomic would overload both ETR and Hybrid adjudication unless thresholds are model-specific.

For ETR, candidate quality determines merge opportunities.

For Hybrid, the same candidate set is also the ceiling for typed relationship formation. BGE is better for Hybrid because it surfaces both an identity-style pair and a sourcing relationship-style pair without flooding the adjudicator.

## Hybrid Adjudication Smoke

Ran Hybrid headless against a copied `pp1` graph directory with:

- Embeddings: `EmbeddingGateway` + `bge-base-en-v1.5`
- Adjudicator: Codex Agent sidecar + `gpt-5.3-codex-spark`
- Default thresholds: `autoMerge=0.95`, `adjudicationFloor=0.80`

Result:

- Eligible nodes: 136
- Pairs evaluated: 5,846
- Adjudication candidates: 2
- LLM verdicts: 1 merge, 1 typed relation

Default-threshold verdicts:

- `Revenue share` <-> `E-commerce revenue share`: `merge`
- `Hardwood sourcing` <-> `FSC wood sourcing`: `instance_of`

This confirms the gateway and Hybrid typed-relation path work end to end, but the default floor is candidate-starved for relationship discovery.

Then ran a bounded threshold sweep and a tuned smoke:

- `--adj-floor-ee 0.72`
- `--adj-floor-cc 0.72`
- `--adj-floor-cl 0.65`
- `autoMerge` remained `0.95`

Tuned result:

- Adjudication candidates: 15
- LLM verdicts: 2 merges, 6 typed relations, 7 keep
- Sidecar request size: 7,484 chars
- Sidecar time: 7.4s

Tuned non-keep verdicts:

- `Revenue share` <-> `E-commerce revenue share`: `merge`
- `Hardwood sourcing` <-> `FSC wood sourcing`: `merge`
- `Revenue channel split` <-> `E-commerce revenue share`: `instance_of`
- `Repair and event workshops` <-> `Repair workshops`: `instance_of`
- `Repair and event workshops` <-> `Flagship Hearth format`: `instance_of`
- `Distribution and sourcing footprint` <-> `Supplier network scale`: `instance_of`
- `Revenue share` <-> `Fiscal 2025 revenue`: `attribute_of`
- `Furniture assortment` <-> `FSC wood sourcing`: `attribute_of`

The tuned floor materially improves relationship volume, but it is not ready to become a global ETR default from one corpus. Some verdicts are semantically debatable, so this should become a configurable Hybrid relationship-discovery preset and be validated against a labeled pair set.

After the preset was implemented, the Hybrid adjudication prompt was enriched with pair kind, similarity, document/page evidence, and source snippets. This targets the main adjudication weakness found above: the previous prompt only had labels, type, level, and summary.

Prompt-context smoke:

- Adjudication candidates: 15
- Sidecar request size: 13,744 chars
- Sidecar time: 9.0s
- LLM verdicts: 2 merges, 6 typed relations, 7 keep

Prompt-context non-keep verdicts:

- `Revenue share` <-> `E-commerce revenue share`: `merge`
- `Hardwood sourcing` <-> `FSC wood sourcing`: `merge`
- `Revenue channel split` <-> `E-commerce revenue share`: `instance_of`
- `Distribution and sourcing footprint` <-> `Supplier network scale`: `instance_of`
- `Repair and event workshops` <-> `Flagship Hearth format`: `instance_of`
- `Revenue share` <-> `Fiscal 2025 revenue`: `attribute_of`
- `Distribution and sourcing footprint` <-> `Distribution and replenishment operations`: `process_for`
- `Revenue share` <-> `Kitchen revenue share`: `instance_of`

Net effect: the richer context fixed at least one likely false positive (`Furniture assortment` <-> `FSC wood sourcing` moved to `keep`) and stabilized `Hardwood sourcing` <-> `FSC wood sourcing` as a merge in this run. It also became too conservative on one plausible pair (`Repair and event workshops` <-> `Repair workshops` moved to `keep`). The next improvement should not be more threshold tuning; it should be a small labeled adjudication set and prompt scoring against expected verdicts.

That labeled-eval path is now started in the Hybrid worktree:

- Seed fixture: `docs/evals/pp1-hybrid-adjudication-labels.json`
- Initial labels: 12 `pp1` pairs covering `merge`, `instance_of`, `attribute_of`, `process_for`, and `keep`
- Scorer: `HybridAdjudicationEvaluator`, matching unordered audit-label pairs and reporting exact-match accuracy plus per-verdict precision/recall
- Focused tests: fixture decoding, unordered matching, missing predictions, and wrong typed verdict accounting
- Headless CLI scorer:
  - `--score-hybrid-adjudication <etr_audit.json> --eval <labels.json>`
  - Because the app is sandboxed, the eval JSON must be inside the app container or another sandbox-readable location when run through the app binary.

Score for the prompt-context smoke audit (`bge-base-en-v1.5`, 15 adjudication entries):

- Total labels: 12
- Matched labels: 12
- Exact matches: 11
- Missing labels: 0
- Accuracy: 0.917
- `merge`: precision 1.000, recall 1.000
- `instance_of`: precision 1.000, recall 0.667
- `attribute_of`: precision 1.000, recall 1.000
- `process_for`: precision 1.000, recall 1.000
- `keep`: precision 0.833, recall 1.000
- Mismatch: `Repair and event workshops` <-> `Repair workshops`, expected `instance_of`, predicted `keep`

This is intentionally not final product truth yet; it is a measurement harness. The next useful quality step is to expand the fixture to 30-50 hand-checked pairs and use it to compare prompt variants. The first concrete prompt target is to recover conservative `instance_of` verdicts where the narrower node is a named subset, offering, workflow, or event format under the broader node, without reopening the earlier `Furniture assortment` / `FSC wood sourcing` false positive.

Follow-up prompt experiments tried to recover the missed `Repair and event workshops` / `Repair workshops` `instance_of` label:

- A broad subset/channel/workflow rule regressed score to `0.750`; it changed `Revenue share` / `E-commerce revenue share` from `merge` to `instance_of` and still kept the workshop pair.
- A narrower workflow/process rule regressed score to `0.583`; it recovered `Distribution and sourcing footprint` / `Distribution and replenishment operations` as `process_for`, but introduced false positives such as `Furniture assortment` / `FSC wood sourcing` as `attribute_of` and `Worksite options` / `Customer service operations` as `instance_of`.
- A compact calibration-example block also failed to recover the workshop pair and regressed the merge labels.

Those prompt edits were reverted. The current best measured prompt remains the prior prompt-context baseline at `0.917`. The next improvement should not be more one-off prose in the prompt; it should either expand the eval labels first or add a structured post-adjudication validator that can be scored before being enabled.

## Operational Notes

- The app defaults were set back to `Gemini` for chat and `EmbeddingGateway`/`bge-base-en-v1.5` for embeddings after the run.
- The four per-doc graph JSON files were backed up before resolver runs and restored afterward.
- ETR/Hybrid branch focused tests passed after the headless-run guard fix:
  - ETR: 26/26
  - Hybrid: 44/44
- A headless lifecycle issue was found and patched in both ETR and Hybrid worktrees: the runner could start from both `applicationDidFinishLaunching` and SwiftUI `.onAppear`, causing duplicate resolver runs.
- A Hybrid headless harness bug was found and patched in the Hybrid worktree: `--hybrid-resolve` parsed threshold flags but dropped them before invoking ETR. After the fix, per-kind threshold flags are reflected in the audit JSON.
- The Hybrid worktree now has a persisted resolver preset setting. `Conservative` keeps the existing default thresholds; `Relationship Discovery` applies the tuned per-kind floors and was smoke-tested through `--hybrid-resolve` without explicit threshold flags.
- The Hybrid prompt now includes candidate metadata and source evidence. Focused prompt tests and a full prompt-context smoke passed.
- A seed `pp1` Hybrid adjudication eval, headless CLI scorer, and mismatch logging were added so future prompt changes can be scored against expected typed verdicts.
- Three prompt variants targeting the workshop false negative were tested and reverted because all scored below the `0.917` baseline.

## Recommendation

Use `bge-base-en-v1.5` as the default LAN gateway embedding model for ETR and Hybrid.

Keep `all-minilm-l6-v2` as a fast baseline, especially for quick smoke tests or UI workflows where lower recall is acceptable.

Do not use `e5-base-v2` or `nomic-embed-text-v1` with the current `0.80/0.95` thresholds. If we want to evaluate them seriously, first add per-model threshold sweeps and compare precision/recall against a labeled pair set.

The configurable Hybrid relationship-discovery preset is implemented in the Hybrid worktree. A seed labeled eval now exists; expand it to 30-50 pairs before making the preset the default.
