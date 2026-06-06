# Hybrid adjudication eval fixtures

This folder stores label fixtures plus local canonical audit rows used by the
regression tests for hybrid adjudication scoring.

## Baseline artifacts

- `pp1-hybrid-adjudication-labels.json`
- `vitacare-hybrid-adjudication-labels.json`
- `reference-audits/pp1-hybrid-adjudication-audit-canonical.json`
- `reference-audits/vitacare-hybrid-adjudication-audit-canonical.json`

The reference audit files keep only the audit rows needed by the label fixtures,
plus the original audit metadata.

## Repro commands

Run these from any working directory with Xcode-built binary available.

You can run both in one command:

```bash
./docs/evals/score-hybrid-baselines.sh
```

The script cleans and stages the JSON fixtures into the app container before
invoking the sandboxed debug binary; direct repo paths may be denied by the
macOS sandbox.
It also writes `manifest.json` beside the staged files with source SHA-256
hashes, verifies the staged copies against it, and lets app-hosted tests prefer
only staged copies whose bytes match the manifest.

Or run each manually after staging the files somewhere the app can read, such
as `~/Library/Containers/rogues.pdf-app1/Data/tmp/hybrid-eval-fixtures`:

```bash
APP_PATH="/Users/yashagrawal/Library/Developer/Xcode/DerivedData/pdf_app1-btbfipsypfdfaugbobekbmvwqyib/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1"
APP_CONTAINER_DATA="$HOME/Library/Containers/rogues.pdf-app1/Data"
FIXTURE_DIR="$APP_CONTAINER_DATA/tmp/hybrid-eval-fixtures"

mkdir -p "$FIXTURE_DIR/reference-audits"
cp docs/evals/*-hybrid-adjudication-labels.json "$FIXTURE_DIR/"
cp docs/evals/reference-audits/*-hybrid-adjudication-audit-canonical.json "$FIXTURE_DIR/reference-audits/"

"$APP_PATH" \
  --headless-extract --score-hybrid-adjudication \
  "$FIXTURE_DIR/reference-audits/pp1-hybrid-adjudication-audit-canonical.json" \
  --eval "$FIXTURE_DIR/pp1-hybrid-adjudication-labels.json" | tail -n 1

"$APP_PATH" \
  --headless-extract --score-hybrid-adjudication \
  "$FIXTURE_DIR/reference-audits/vitacare-hybrid-adjudication-audit-canonical.json" \
  --eval "$FIXTURE_DIR/vitacare-hybrid-adjudication-labels.json" | tail -n 1
```

If needed, override the binary path:

```bash
APP_PATH="/path/to/pdf_app1.app/Contents/MacOS/pdf_app1" ./docs/evals/score-hybrid-baselines.sh
```

Expected in the output for both lines is a single line beginning with:

```
HYBRID_EVAL_SUMMARY
```

The baseline script fails if a run emits `HYBRID_EVAL_*ERROR`, does not emit
exactly one `HYBRID_EVAL_SUMMARY`, or misses the expected totals:

- pp1: `totalLabels=12`, `accuracy=1`, `directionRequiredLabels=5`, `directionMismatches=0`
- vitacare: `totalLabels=21`, `accuracy=1`, `directionRequiredLabels=10`, `directionMismatches=0`

The two-score tests in `pdf_app1/pdf_app1Tests/HybridAdjudicationEvalTests.swift`
validate these baselines in CI/unit runs.

## Live hybrid lexical baselines

To run the live hybrid resolver against the current app-container graph inputs:

```bash
./docs/evals/run-hybrid-live-baselines.sh
```

Defaults:

- pp1 graphs: `~/Library/Containers/rogues.pdf-app1/Data/hybrid-input-pp1-v2`
- vitacare graphs: `~/Library/Containers/rogues.pdf-app1/Data/hybrid-input-vitacare-current`
- backend/model: `CodexAgent` / `gpt-5.3-codex-spark`
- lexical limit: `120`

For a quick smoke or sweep:

```bash
LIMITS="24" ./docs/evals/run-hybrid-live-baselines.sh
LIMITS="24 60 120" ./docs/evals/run-hybrid-live-baselines.sh
```

`LIMITS` entries must be positive integers.

Expected output includes `HYBRID_RELATION`, `HYBRID_MERGE`, and one
`HYBRID_RESOLVE_SUMMARY` per corpus/limit. The script exits nonzero if a run
emits `HYBRID_*ERROR`, does not emit exactly one summary, or reports the wrong
`candidateLimit`.
