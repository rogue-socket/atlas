#!/usr/bin/env bash
# Ensure the lv embedding gateway is reachable from this Mac.
# Prints export lines suitable for: eval "$(./scripts/ensure_embedding_gateway.sh)"
#
# 1. Try ATLAS_EMBEDDING_GATEWAY_BASE_URL or http://192.168.1.14:8200/v1 (SSH config Host lv)
# 2. On failure, start ssh -L <port>:127.0.0.1:8200 lv and use http://127.0.0.1:<port>/v1

set -euo pipefail

DEFAULT_URL="http://192.168.1.14:8200/v1"
TUNNEL_PORT="${ATLAS_EMBEDDING_TUNNEL_PORT:-18200}"
TUNNEL_URL="http://127.0.0.1:${TUNNEL_PORT}/v1"
SSH_HOST="${ATLAS_EMBEDDING_SSH_HOST:-lv}"

probe() {
  curl -fsS -m 8 "${1%/}/models" >/dev/null 2>&1
}

pick_url() {
  if [[ -n "${ATLAS_EMBEDDING_GATEWAY_BASE_URL:-}" ]] && probe "$ATLAS_EMBEDDING_GATEWAY_BASE_URL"; then
    echo "$ATLAS_EMBEDDING_GATEWAY_BASE_URL"
    return 0
  fi
  if probe "$DEFAULT_URL"; then
    echo "$DEFAULT_URL"
    return 0
  fi
  return 1
}

start_tunnel() {
  if probe "$TUNNEL_URL"; then
    echo "$TUNNEL_URL"
    return 0
  fi
  echo "ensure_embedding_gateway: direct LAN failed; opening SSH tunnel ${SSH_HOST} → 127.0.0.1:${TUNNEL_PORT}" >&2
  ssh -f -N -o ExitOnForwardFailure=yes -L "${TUNNEL_PORT}:127.0.0.1:8200" "$SSH_HOST"
  sleep 0.3
  if probe "$TUNNEL_URL"; then
    echo "$TUNNEL_URL"
    return 0
  fi
  echo "ensure_embedding_gateway: tunnel up but /v1/models still failed" >&2
  return 1
}

if URL="$(pick_url 2>/dev/null)"; then
  :
elif URL="$(start_tunnel)"; then
  :
else
  exit 1
fi

printf 'export ATLAS_EMBEDDING_GATEWAY_BASE_URL=%q\n' "$URL"
echo "ensure_embedding_gateway: OK $URL" >&2
