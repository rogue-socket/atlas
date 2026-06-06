#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVAL_DIR="$REPO_ROOT/docs/evals"
APP_PATH="${APP_PATH:-/Users/yashagrawal/Library/Developer/Xcode/DerivedData/pdf_app1-btbfipsypfdfaugbobekbmvwqyib/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1}"
APP_CONTAINER_DATA="${APP_CONTAINER_DATA:-$HOME/Library/Containers/rogues.pdf-app1/Data}"
WORK_DIR="$APP_CONTAINER_DATA/tmp/hybrid-eval-fixtures"
MANIFEST="$WORK_DIR/manifest.json"

PP1_AUDIT="$EVAL_DIR/reference-audits/pp1-hybrid-adjudication-audit-canonical.json"
PP1_LABELS="$EVAL_DIR/pp1-hybrid-adjudication-labels.json"
VITACARE_AUDIT="$EVAL_DIR/reference-audits/vitacare-hybrid-adjudication-audit-canonical.json"
VITACARE_LABELS="$EVAL_DIR/vitacare-hybrid-adjudication-labels.json"

if [[ ! -x "$APP_PATH" ]]; then
    echo "[ERROR] app binary not executable at: $APP_PATH" >&2
    exit 1
fi

if [[ ! -f "$PP1_AUDIT" || ! -f "$PP1_LABELS" || ! -f "$VITACARE_AUDIT" || ! -f "$VITACARE_LABELS" ]]; then
    echo "[ERROR] missing eval fixture(s) under $EVAL_DIR" >&2
    exit 1
fi

if [[ "$WORK_DIR" != */hybrid-eval-fixtures ]]; then
    echo "[ERROR] refusing to clean unexpected staging directory: $WORK_DIR" >&2
    exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cp "$PP1_AUDIT" "$WORK_DIR/pp1-hybrid-adjudication-audit-canonical.json"
cp "$PP1_LABELS" "$WORK_DIR/pp1-hybrid-adjudication-labels.json"
cp "$VITACARE_AUDIT" "$WORK_DIR/vitacare-hybrid-adjudication-audit-canonical.json"
cp "$VITACARE_LABELS" "$WORK_DIR/vitacare-hybrid-adjudication-labels.json"
python3 - "$MANIFEST" "$REPO_ROOT" "$PP1_AUDIT" "$PP1_LABELS" "$VITACARE_AUDIT" "$VITACARE_LABELS" <<'PY'
import hashlib
import json
import pathlib
import sys
from datetime import datetime, timezone

manifest_path = pathlib.Path(sys.argv[1])
repo_root = sys.argv[2]
sources = [pathlib.Path(path) for path in sys.argv[3:]]

manifest = {
    "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "repoRoot": repo_root,
    "sources": [
        {
            "fileName": source.name,
            "sha256": hashlib.sha256(source.read_bytes()).hexdigest()
        }
        for source in sources
    ]
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
python3 - "$MANIFEST" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
manifest = json.loads(manifest_path.read_text())
work_dir = manifest_path.parent

for source in manifest["sources"]:
    staged_path = work_dir / source["fileName"]
    if not staged_path.is_file():
        print(f"[ERROR] staged fixture missing: {staged_path}", file=sys.stderr)
        sys.exit(1)

    actual = hashlib.sha256(staged_path.read_bytes()).hexdigest()
    expected = source["sha256"]
    if actual != expected:
        print(
            f"[ERROR] staged fixture hash mismatch: {source['fileName']} expected {expected}, got {actual}",
            file=sys.stderr,
        )
        sys.exit(1)
PY

PP1_AUDIT="$WORK_DIR/pp1-hybrid-adjudication-audit-canonical.json"
PP1_LABELS="$WORK_DIR/pp1-hybrid-adjudication-labels.json"
VITACARE_AUDIT="$WORK_DIR/vitacare-hybrid-adjudication-audit-canonical.json"
VITACARE_LABELS="$WORK_DIR/vitacare-hybrid-adjudication-labels.json"

run_score() {
    local audit_path=$1
    local eval_path=$2
    local tag=$3
    local expected_total=$4
    local expected_direction_required=$5

    echo "==> $tag"
    local raw_output
    set +e
    raw_output="$("$APP_PATH" --headless-extract --score-hybrid-adjudication "$audit_path" --eval "$eval_path")"
    local app_status=$?
    set -e

    local error_lines
    error_lines="$(printf '%s\n' "$raw_output" | rg '^HYBRID_EVAL_.*ERROR' || true)"
    if [[ -n "$error_lines" ]]; then
        echo "$error_lines" >&2
        echo "[ERROR] $tag: scorer emitted HYBRID_EVAL error output" >&2
        exit 1
    fi

    if [[ "$app_status" != "0" ]]; then
        echo "[ERROR] $tag: scorer exited with status $app_status" >&2
        printf '%s\n' "$raw_output" | tail -n 20 >&2
        exit 1
    fi

    local summaries
    summaries="$(printf '%s\n' "$raw_output" | rg '^HYBRID_EVAL_SUMMARY ' || true)"
    local summary_count
    summary_count="$(printf '%s\n' "$summaries" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$summary_count" != "1" ]]; then
        echo "[ERROR] $tag: expected one HYBRID_EVAL_SUMMARY, got $summary_count" >&2
        exit 1
    fi

    local summary
    summary="$summaries"
    echo "$summary"
    SUMMARY="$summary" python3 - "$tag" "$expected_total" "$expected_direction_required" <<'PY'
import json
import os
import sys

tag = sys.argv[1]
expected_total = int(sys.argv[2])
expected_direction_required = int(sys.argv[3])
line = os.environ["SUMMARY"]
prefix = "HYBRID_EVAL_SUMMARY "
if not line.startswith(prefix):
    print(f"[ERROR] {tag}: missing HYBRID_EVAL_SUMMARY line", file=sys.stderr)
    sys.exit(1)

summary = json.loads(line[len(prefix):])
checks = [
    ("totalLabels", expected_total),
    ("matchedLabels", expected_total),
    ("exactMatches", expected_total),
    ("missingLabels", 0),
    ("directionRequiredLabels", expected_direction_required),
    ("directionMismatches", 0),
]
for key, expected in checks:
    actual = summary.get(key)
    if actual != expected:
        print(f"[ERROR] {tag}: {key} expected {expected}, got {actual}", file=sys.stderr)
        sys.exit(1)

if summary.get("accuracy") != 1:
    print(f"[ERROR] {tag}: accuracy expected 1, got {summary.get('accuracy')}", file=sys.stderr)
    sys.exit(1)
PY
}

run_score "$PP1_AUDIT" "$PP1_LABELS" "pp1" 12 5
run_score "$VITACARE_AUDIT" "$VITACARE_LABELS" "vitacare" 21 10
