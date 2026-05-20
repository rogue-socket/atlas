# Atlas Claude sidecar

A tiny localhost HTTP server that lets the **sandboxed** Atlas macOS app use
Claude for concept extraction via your **Claude subscription** (not a metered
API key).

Atlas is sandboxed (`com.apple.security.app-sandbox`) and cannot spawn the
`claude` CLI directly. It reaches this server over loopback HTTP instead.

No `npm install` — Node builtins only. Requires Node 18+ and the `claude` CLI
on `PATH`, logged in to a Claude subscription.

## Auto-start (recommended)

Install the sidecar as a per-user launchd LaunchAgent — it then starts on login
and restarts if it crashes, so you never have to start it by hand:

```sh
./install-launchagent.sh
```

This writes `~/Library/LaunchAgents/com.atlas.claude-sidecar.plist` (logs to
`~/Library/Logs/atlas-claude-sidecar.log`) and loads it immediately. Re-run the
script if your `node` or `claude` install path changes. To uninstall:

```sh
launchctl unload ~/Library/LaunchAgents/com.atlas.claude-sidecar.plist
rm ~/Library/LaunchAgents/com.atlas.claude-sidecar.plist
```

## Run manually

```sh
node server.mjs
```

## Using it in Atlas

Select **Claude (Subscription)** as the AI backend in Settings. If the sidecar
isn't running when an extraction starts, Atlas health-checks it first and stops
with a clear message instead of failing every batch silently.

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
