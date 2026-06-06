# LAN Embedding Gateway Integration

Atlas supports the LAN OpenAI-compatible embedding gateway as an ETR/Hybrid embedding backend.

## Gateway

- Base URL: `http://192.168.1.14:8200/v1`
- Endpoint: `POST /embeddings`
- API key: `none` by default
- Default model: `bge-base-en-v1.5`

## Models

Configured app-selectable models:

- `bge-base-en-v1.5` — 768 dimensions, default quality candidate.
- `all-minilm-l6-v2` — 384 dimensions, fast baseline.

The LAN gateway also exposes `e5-base-v2` and `nomic-embed-text-v1`,
but the 2026-06-02 pp1 comparison showed both are badly uncalibrated at
Atlas' current `0.80/0.95` resolver thresholds. Keep them out of the app
picker until per-model threshold sweeps exist.

Atlas stores separate embedding cache files per project, model, and dimension:

`embeddings_<projectID>_<model>_<dimension>d.json`

Each cached vector stores model name, dimension, source node id, source path, chunk id, chunk text, and vector values.

## Switching Models

In Settings, use `Embedding Backend` and select `LAN Embedding Gateway`, then choose a model.

For headless runs, set preferences before launching:

```sh
defaults write rogues.pdf-app1 atlas.ai.embedding.backendType EmbeddingGateway
defaults write rogues.pdf-app1 atlas.ai.embedding.model bge-base-en-v1.5
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.baseURL http://192.168.1.14:8200/v1
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.apiKey none
```

The ETR sweep scripts also set the chat adjudication backend. By default they
use the Claude subscription sidecar:

```sh
defaults write rogues.pdf-app1 atlas.ai.backendType ClaudeSubscription
defaults write rogues.pdf-app1 atlas.ai.model sonnet
```

Override with `ETR_CHAT_BACKEND` and `ETR_CHAT_MODEL` for explicit comparison
runs. For a Codex Agent comparison, use:

```sh
ETR_CHAT_BACKEND=CodexAgent ETR_CHAT_MODEL=gpt-5.3-codex-spark ./scripts/etr_threshold_sweep.sh
```

Switch to MiniLM for a latency baseline:

```sh
defaults write rogues.pdf-app1 atlas.ai.embedding.model all-minilm-l6-v2
```

## Evaluation

Run the same extracted project through ETR or Hybrid with at least two models, preserving logs separately.

ETR:

```sh
./pdf_app1.app/Contents/MacOS/pdf_app1 --headless-extract --project pp1 --etr-only
```

Hybrid:

```sh
./pdf_app1.app/Contents/MacOS/pdf_app1 --headless-extract --hybrid-resolve /path/to/per-doc-graphs
```

Compare:

- merge/relation counts in logs
- resolver failures/errors
- elapsed time around embedding calls and ETR/Hybrid completion
- downstream graph quality on the app task

2026-06-02 live comparison on `pp1` found:

- `bge-base-en-v1.5`: 2 plausible adjudication candidates from 5,846 cross-doc pairs.
- `all-minilm-l6-v2`: 1 plausible adjudication candidate from the same graph.

Use BGE as the default. Use MiniLM only as a fast baseline.
