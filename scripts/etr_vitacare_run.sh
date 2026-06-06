#!/usr/bin/env bash
# Single-process vitacare ETR run: bootstrap project → extract (if needed) → ETR → rubric.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
eval "$(ROOT="$ROOT" "$ROOT/scripts/ensure_embedding_gateway.sh")"

PDF_APP1="$ROOT/pdf_app1"
DERIVED_DATA="${ETR_DERIVED_DATA:-$PDF_APP1/build}"
APP_BUNDLE="${ETR_APP_BUNDLE:-$DERIVED_DATA/Build/Products/Debug/pdf_app1.app}"
SOURCE_PDFS="${ETR_SAMPLE_PDF_DIR:-$ROOT/../sample_pdfs/files}"
CONTAINER_DATA="$HOME/Library/Containers/rogues.pdf-app1/Data"
STAGED_PDFS="$CONTAINER_DATA/vitacare-fixtures"
RUNS="$ROOT/runs/vitacare-etr-$(date +%Y%m%d-%H%M%S)"
GRAPH_OUT_CONTAINER="$CONTAINER_DATA/vitacare-post-etr.json"
GRAPH_OUT="$RUNS/vitacare-post-etr.json"
LOG="$RUNS/run.log"

mkdir -p "$RUNS" "$STAGED_PDFS"
cp -f "$SOURCE_PDFS"/vitacare_*.pdf "$STAGED_PDFS/" 2>/dev/null || {
  echo "Missing vitacare PDFs under $SOURCE_PDFS" >&2
  exit 1
}
echo "Staged $(ls "$STAGED_PDFS"/*.pdf | wc -l | tr -d ' ') PDFs → $STAGED_PDFS" >&2

defaults write rogues.pdf-app1 atlas.ai.embedding.backendType EmbeddingGateway
defaults write rogues.pdf-app1 atlas.ai.embedding.model bge-base-en-v1.5
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.baseURL "$ATLAS_EMBEDDING_GATEWAY_BASE_URL"
defaults write rogues.pdf-app1 atlas.ai.embedding.gateway.apiKey none
# Chat backend for extract + ETR adjudication (dev key file: container Data/atlas-dev-keys.json).
defaults write rogues.pdf-app1 atlas.ai.backendType Gemini
defaults write rogues.pdf-app1 atlas.ai.model gemini-2.5-flash

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Building pdf_app1…" >&2
  (cd "$PDF_APP1" && xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug -derivedDataPath "$DERIVED_DATA" build -quiet)
fi

# One headless process only (no GUI windows).
ETR_MODE=(--headless-extract --project vitacare --bootstrap-pdf-dir "$STAGED_PDFS" --export-graph "$GRAPH_OUT_CONTAINER")

# ETR-only when vitacare project already has 4 PDFs on disk with graphs (tuning loop).
HAS_VITACARE_PROJECT=$(python3 -c "
import json, os
p = os.path.expanduser('~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/PDFViewer/projects.json')
if not os.path.exists(p): raise SystemExit(0)
for pr in json.load(open(p)).get('projects', []):
    if pr.get('name') == 'vitacare' and len(pr.get('files', [])) >= 4:
        raise SystemExit(1)
raise SystemExit(0)
" && echo 0 || echo 1)

if [[ "${ETR_FORCE_EXTRACT:-0}" == "1" ]]; then
  ETR_MODE+=(--mode fast --etr)
  echo "Full extract + ETR (ETR_FORCE_EXTRACT=1)" >&2
elif [[ "$HAS_VITACARE_PROJECT" == "1" && "${ETR_SKIP_EXTRACT:-0}" != "0" ]]; then
  ETR_MODE+=(--etr-only)
  echo "vitacare project on disk — ETR-only (set ETR_FORCE_EXTRACT=1 to re-extract)" >&2
else
  ETR_MODE+=(--mode fast --etr)
  echo "Bootstrap + extract + ETR (first vitacare run)" >&2
fi

echo "Log: $LOG" >&2
echo "Gateway: $ATLAS_EMBEDDING_GATEWAY_BASE_URL" >&2

# Single instance via LaunchServices; -g avoids stealing focus.
open -W -g "$APP_BUNDLE" --args "${ETR_MODE[@]}" >"$LOG" 2>&1
EXIT=$?

echo "--- unified log (headless/ETR) ---" >&2
log show --style compact --predicate 'subsystem == "com.atlas.pdf" AND (category == "headless" OR category == "embedding" OR category == "pipeline")' --last 20m 2>/dev/null \
  | grep -E 'Headless|ETR|Rubric|structural_boost|error|bootstrap' | tail -50 || true

if [[ -f "$GRAPH_OUT_CONTAINER" ]]; then
  cp -f "$GRAPH_OUT_CONTAINER" "$GRAPH_OUT"
fi

if [[ $EXIT -eq 0 && -f "$GRAPH_OUT_CONTAINER" ]]; then
  open -W -g "$APP_BUNDLE" --args --headless-extract --score-rubric "$GRAPH_OUT_CONTAINER" >>"$LOG" 2>&1 || true
  log show --style compact --predicate 'subsystem == "com.atlas.pdf" AND category == "headless"' --last 5m 2>/dev/null \
    | grep Rubric | tail -25 || true
fi

echo "Done exit=$EXIT artifacts=$RUNS" >&2
exit $EXIT
