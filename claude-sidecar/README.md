# Atlas Claude sidecar

A tiny localhost HTTP server that lets the **sandboxed** Atlas macOS app use
Claude for concept extraction via your **Claude subscription** (not a metered
API key).

Atlas is sandboxed (`com.apple.security.app-sandbox`) and cannot spawn the
`claude` CLI directly. It reaches this server over loopback HTTP instead.

## Run

```sh
node server.mjs
```

No `npm install` — Node builtins only. Requires Node 18+ and the `claude` CLI
on `PATH`, logged in to a Claude subscription.

The app will not extract while this is down — start it before extracting in
Atlas, then select **Claude (Subscription)** as the AI backend in Settings.

## Auth

The server strips `ANTHROPIC_API_KEY` from the `claude` child process so the
CLI uses your logged-in subscription (OAuth). Subscription rate limits apply.

## Endpoints

- `GET /health` → `{ "ok": true, "model": "opus" }`
- `POST /extract` — body `{ "prompt": "...", "model": "opus" }` → `{ "text": "..." }`

## Env knobs

| Var | Default | Purpose |
|-----|---------|---------|
| `ATLAS_SIDECAR_PORT` | `8765` | listen port (must match Settings) |
| `ATLAS_SIDECAR_MODEL` | `opus` | default model alias |
| `ATLAS_SIDECAR_TIMEOUT` | `280000` | per-request kill (ms) |
| `CLAUDE_BIN` | `claude` | path to the `claude` CLI |
