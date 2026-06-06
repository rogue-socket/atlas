#!/usr/bin/env bash
# ETR threshold sweep on the tune corpus (default: vitacare).
#
# Prereqs:
#   - Built Debug app: cd pdf_app1 && xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug -derivedDataPath build build
#   - Project "vitacare" with per-doc graphs already on disk (extract once in app or headless)
#   - LAN embedding gateway on lv (default http://192.168.1.14:8200/v1)
#   - Gemini (or other) chat backend + API key for LLM adjudication
#
# Usage:
#   ./scripts/etr_threshold_sweep.sh
#   ATLAS_EMBEDDING_GATEWAY_BASE_URL=http://lv:8200/v1 ./scripts/etr_threshold_sweep.sh
#   ETR_PROJECT=pp1 ETR_SKIP_EXTRACT=1 ./scripts/etr_threshold_sweep.sh   # holdout (etr-only)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
eval "$(ROOT="$ROOT" "$ROOT/scripts/ensure_embedding_gateway.sh")"

PDF_APP1="$ROOT/pdf_app1"
DERIVED_DATA="${ETR_DERIVED_DATA:-$PDF_APP1/build}"
APP_BUNDLE="${ETR_APP_BUNDLE:-$DERIVED_DATA/Build/Products/Debug/pdf_app1.app}"
APP="$APP_BUNDLE/Contents/MacOS/pdf_app1"
PROJECT="${ETR_PROJECT:-vitacare}"
GATEWAY_URL="$ATLAS_EMBEDDING_GATEWAY_BASE_URL"
RUNS="$ROOT/runs/etr-sweep-${PROJECT}-$(date +%Y%m%d-%H%M%S)"
RUNS_CONTAINER="$HOME/Library/Containers/rogues.pdf-app1/Data/${RUNS##*/}"

if [[ ! -x "$APP" ]]; then
  echo "Build the app first: cd $PDF_APP1 && xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug -derivedDataPath build build" >&2
  exit 1
fi

mkdir -p "$RUNS"
mkdir -p "$RUNS_CONTAINER"
echo "Runs → $RUNS"
echo "Gateway → $GATEWAY_URL"

defaults write rogues.pdf-app1 atlas.ai.embedding.backendType EmbeddingGateway
defaults write rogues.pdf-app1 atlas.ai.embedding.model bge-base-en-v1.5
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.baseURL "$GATEWAY_URL"
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.apiKey none

# Flat adjudication floors to try (auto-merge stays 0.95). Extend or add per-kind flags as needed.
FLOORS=(0.78 0.80 0.82 0.84)

run_one() {
  local tag="$1"
  shift
  local graph_out="$RUNS_CONTAINER/${tag}-graph.json"
  local graph_out_local="$RUNS/${tag}-graph.json"
  local log_out="$RUNS/${tag}.log"
  echo "=== $tag ==="
  export ATLAS_EMBEDDING_GATEWAY_BASE_URL="$GATEWAY_URL"
  local etr_mode=(--etr-only)
  if [[ "${ETR_SKIP_EXTRACT:-0}" != "1" ]]; then
    etr_mode=(--mode fast --etr)
  fi

  "$APP" --headless-extract --project "$PROJECT" "${etr_mode[@]}" "$@" \
    --export-graph "$graph_out" >"$log_out" 2>&1 || {
    echo "Run failed — see $log_out" >&2
    return 1
  }
  cp -f "$graph_out" "$graph_out_local"
  /usr/bin/log show --style compact --info --predicate 'subsystem == "com.atlas.pdf" AND category == "headless"' --last 5m \
    | grep -E "\[Rubric\]|\[Headless\] (ETR|scorecard|scoring)|${PROJECT}|${tag}|precision =|recall    =" | tail -80 >>"$log_out" || true
  "$APP" --headless-extract --score-rubric "$graph_out" >>"$log_out" 2>&1 || true
  grep -E '\[Rubric\]|precision =|recall    =' "$log_out" | tail -20 || true
}

for floor in "${FLOORS[@]}"; do
  run_one "floor-${floor}" --adj-floor "$floor"
done

# Per-kind example (concept stricter, entity looser) — uncomment to include:
# run_one "perkind-cc090-ee075" --adj-floor-cc 0.90 --adj-floor-ee 0.75

echo "Done. Artifacts in $RUNS"
echo "Audit sidecars: ~/Library/Application Support/Atlas/graphs/etr_audit_*.json"
