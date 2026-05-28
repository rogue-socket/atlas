# Atlas Codex Agent sidecar

Local HTTP bridge from the sandboxed Atlas macOS app to the user's Codex CLI.
It lets Atlas use **Codex Agent** as an AI backend without storing an API key in
Atlas.

The sidecar is intentionally tiny: Atlas talks to `127.0.0.1`, the sidecar
passes prompts to `codex exec --json`, and the text response is returned to the
app.

## User flow

1. Open Atlas.
2. Open **Settings** (`Cmd+,`) -> **AI**.
3. Select **Codex Agent** as the provider.
4. Atlas automatically starts the bundled `codex-agent-sidecar/server.py`.
5. Press **Test API Connection** to verify a real Codex request.

Expected result:

- Settings shows provider `Codex Agent`, model `gpt-5.5`.
- The sidecar becomes healthy at `http://127.0.0.1:8775/health`.
- Test API Connection shows `OK (...)`.

The same preflight/startup path runs before document analysis, so extraction
does not require manually starting the sidecar first.

## Requirements

- Python 3 installed outside Apple's `/usr/bin/python3` developer-tool shim.
  Atlas looks for:
  - `$ATLAS_CODEX_AGENT_PYTHON`
  - `/Library/Frameworks/Python.framework/Versions/Current/bin/python3`
  - `/opt/homebrew/bin/python3`
  - `/usr/local/bin/python3`
- The `codex` CLI installed and logged in for the current macOS user.
- Atlas must be built with the Codex Agent sandbox exceptions in
  `pdf_app1/pdf_app1/pdf_app1.entitlements`.

The Debug/dev setup currently grants read access to:

- `/Library/Frameworks/Python.framework/`
- `/opt/homebrew/`

and read/write access to:

- `~/.codex/`

Those exceptions are what allow the sandboxed app to spawn Python, run the
Homebrew Codex CLI, and use the user's Codex auth state. The launcher
intentionally avoids `/usr/bin/python3`: on macOS this can route through
`xcrun`, which fails inside App Sandbox.

## Startup behavior

`CodexAgentBackend.preflight()` first calls `/health`.

If health is already OK, Atlas does not start a new process. If health is down,
Atlas copies the bundled `server.py` resource into the app-container
Application Support directory, then starts that copy with a resolved Python
executable. This avoids App Sandbox code-open edge cases for scripts under
`Documents`.

The launch is equivalent to:

```sh
/Library/Frameworks/Python.framework/Versions/Current/bin/python3 \
  ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/codex-agent-sidecar/server.py
```

The child process uses the Atlas Application Support directory as its working
directory. Atlas also sets `HOME` and `CODEX_HOME` to the real user home so the
Codex CLI sees the same auth/config as a normal terminal session.
Atlas prepends the Python directory plus `/opt/homebrew/bin` and
`/usr/local/bin` to `PATH` before launching the sidecar. This matters for GUI
launches because the Codex CLI commonly starts through `#!/usr/bin/env node`,
and Finder/Xcode app launches may not inherit a shell PATH that can find Node.

The app then polls `/health` until the sidecar is ready or the startup timeout
expires. This preflight is used by:

- selecting **Codex Agent** in Settings -> AI
- pressing **Test API Connection**
- extraction and guided-tour generation paths that create an AI backend

The sidecar log lives in the app container:

```sh
~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/codex-agent-sidecar.log
```

## Endpoints

- `GET /health`

  Returns:

  ```json
  {
    "ok": true,
    "model": "gpt-5.5",
    "codexBin": "/opt/homebrew/bin/codex",
    "sidecar": "self-contained"
  }
  ```

- `POST /extract`

  Request:

  ```json
  {
    "prompt": "...",
    "model": "gpt-5.5"
  }
  ```

  Response:

  ```json
  {
    "text": "..."
  }
  ```

## Environment knobs

| Var | Default | Purpose |
|-----|---------|---------|
| `ATLAS_CODEX_AGENT_PORT` | `8775` | Sidecar listen port. Must match Settings -> AI sidecar URL. |
| `ATLAS_CODEX_AGENT_MODEL` | `gpt-5.5` | Default model when the request does not provide one. |
| `ATLAS_CODEX_AGENT_TIMEOUT` | `600` | Per-request Codex timeout in seconds. |
| `ATLAS_CODEX_AGENT_SANDBOX` | `read-only` | Sandbox passed to `codex exec`. |
| `ATLAS_CODEX_AGENT_PYTHON` | auto-detected | Override the Python executable used to start the sidecar. Do not point this at `/usr/bin/python3`. |
| `CODEX_BIN` | `codex` | Codex CLI path. Atlas sets `/opt/homebrew/bin/codex` when present. |

Atlas also sets `HOME` and `CODEX_HOME` for the sidecar child process so the
Codex CLI can read the user's real `~/.codex` auth/config instead of the app
container home.

## Troubleshooting

### Provider selection shows "sidecar did not become ready"

Check the sidecar log:

```sh
tail -n 80 "$HOME/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/codex-agent-sidecar.log"
```

Common causes:

- the app was not rebuilt after entitlement changes
- the bundled `server.py` resource is missing from the app
- Atlas cannot copy `server.py` into the app container
- Python is not available from one of the sandbox-usable paths
- port `8775` is already in use

If the log contains:

```text
xcrun: error: cannot be used within an App Sandbox.
```

Atlas used Apple's developer-tool Python shim instead of a real Python install.
Rebuild with the current launcher, or set `ATLAS_CODEX_AGENT_PYTHON` to a real
Python executable such as
`/Library/Frameworks/Python.framework/Versions/Current/bin/python3`.

### Test API Connection returns HTTP 502 with Codex output

The sidecar started, but `codex exec` failed. Common causes:

- the Codex CLI is not logged in
- `HOME` / `CODEX_HOME` does not point to the real user home
- `PATH` does not include the directory that contains Node for a
  `#!/usr/bin/env node` Codex CLI install
- network/auth failures from the Codex service

If the log contains:

```text
RuntimeError: codex exited 127: env: node: No such file or directory
```

the sidecar could run Python and receive HTTP requests, but the Codex CLI could
not start because Node was not visible in the sidecar environment. Rebuild with
the current launcher so Atlas prepends `/opt/homebrew/bin` and `/usr/local/bin`
to `PATH`, or launch with an explicit `CODEX_BIN`/environment that can resolve
Node.

### Health works but extraction fails

`/health` only checks that the sidecar process can respond over HTTP. Press
**Test API Connection** to verify the full path through `codex exec --json`.

## Manual smoke test

From a clean state:

```sh
pkill -f '[c]odex-agent-sidecar/server.py' || true
curl --max-time 1 http://127.0.0.1:8775/health
```

Then use Atlas UI:

1. Settings -> AI.
2. Select **Codex Agent**.
3. Confirm `/health` returns OK.
4. Press **Test API Connection**.

The 2026-05-28 smoke from the app UI showed:

- sidecar process appeared after selecting Codex Agent
- `/health` returned OK with `"sidecar": "self-contained"`
- Test API Connection completed in 4.5 seconds
- sidecar logged `POST /extract HTTP/1.1" 200`

## Embeddings

Codex Agent is an LLM backend only. It does not provide embeddings, so ETR
embedding-backed workflows still require another embedding provider.
