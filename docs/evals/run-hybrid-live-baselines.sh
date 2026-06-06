#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${APP_PATH:-/Users/yashagrawal/Library/Developer/Xcode/DerivedData/pdf_app1-btbfipsypfdfaugbobekbmvwqyib/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1}"
APP_CONTAINER_DATA="${APP_CONTAINER_DATA:-$HOME/Library/Containers/rogues.pdf-app1/Data}"
PP1_GRAPH_DIR="${PP1_GRAPH_DIR:-$APP_CONTAINER_DATA/hybrid-input-pp1-v2}"
VITACARE_GRAPH_DIR="${VITACARE_GRAPH_DIR:-$APP_CONTAINER_DATA/hybrid-input-vitacare-current}"
BACKEND="${BACKEND:-CodexAgent}"
MODEL="${MODEL:-gpt-5.3-codex-spark}"
LIMITS="${LIMITS:-120}"

if [[ ! -x "$APP_PATH" ]]; then
    echo "[ERROR] app binary not executable at: $APP_PATH" >&2
    exit 1
fi

if [[ ! -d "$PP1_GRAPH_DIR" ]]; then
    echo "[ERROR] pp1 graph directory missing: $PP1_GRAPH_DIR" >&2
    exit 1
fi

if [[ ! -d "$VITACARE_GRAPH_DIR" ]]; then
    echo "[ERROR] vitacare graph directory missing: $VITACARE_GRAPH_DIR" >&2
    exit 1
fi

run_live() {
    local tag=$1
    local graph_dir=$2
    local limit=$3

    echo "==> $tag limit=$limit"
    local raw_log
    raw_log="$(mktemp -t atlas-hybrid-live.XXXXXX)"
    set +e
    "$APP_PATH" \
        --headless-extract \
        --hybrid-resolve "$graph_dir" \
        --lexical \
        --lexical-limit "$limit" \
        -atlas.ai.backendType "$BACKEND" \
        -atlas.ai.model "$MODEL" \
        > "$raw_log" 2>&1
    local app_status=$?
    set -e

    local filtered
    filtered="$(rg 'HYBRID_(RELATION|MERGE|RESOLVE|ERROR)' "$raw_log" || true)"
    echo "$filtered"

    local error_lines
    error_lines="$(printf '%s\n' "$filtered" | rg '^HYBRID_.*ERROR' || true)"
    if [[ -n "$error_lines" ]]; then
        echo "$error_lines" >&2
        echo "[ERROR] $tag limit=$limit emitted HYBRID error output" >&2
        rm -f "$raw_log"
        exit 1
    fi

    if [[ "$app_status" != "0" ]]; then
        echo "[ERROR] $tag limit=$limit app exited with status $app_status" >&2
        tail -n 20 "$raw_log" >&2
        rm -f "$raw_log"
        exit 1
    fi

    local summary_lines
    summary_lines="$(printf '%s\n' "$filtered" | rg '^HYBRID_RESOLVE_SUMMARY ' || true)"
    local summaries
    summaries="$(printf '%s\n' "$summary_lines" | sed '/^$/d' | wc -l | tr -d ' ')"
    if [[ "$summaries" != "1" ]]; then
        echo "[ERROR] $tag limit=$limit expected one HYBRID_RESOLVE_SUMMARY, got $summaries" >&2
        rm -f "$raw_log"
        exit 1
    fi

    local summary
    summary="$summary_lines"
    if [[ "$summary" != *"candidateLimit=$limit"* ]]; then
        echo "[ERROR] $tag limit=$limit summary did not report candidateLimit=$limit" >&2
        rm -f "$raw_log"
        exit 1
    fi
    rm -f "$raw_log"
}

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

for limit in $LIMITS; do
    if ! is_positive_int "$limit"; then
        echo "[ERROR] LIMITS entries must be positive integers: $limit" >&2
        exit 1
    fi
    run_live "pp1" "$PP1_GRAPH_DIR" "$limit"
    run_live "vitacare" "$VITACARE_GRAPH_DIR" "$limit"
done
