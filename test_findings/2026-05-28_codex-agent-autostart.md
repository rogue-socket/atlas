# Codex Agent Auto-Start Smoke — 2026-05-28

## Scope

Verify the exact user flow requested for the Codex Agent backend:

1. Open Atlas.
2. Go to **Settings -> AI**.
3. Select **Codex Agent** as the provider.
4. Confirm the sidecar starts at that moment.
5. Press **Test API Connection** and confirm the backend is usable.

## Build Under Test

- Branch: `feature/hybrid-cross-doc`
- App: Debug build from `pdf_app1.xcodeproj`
- Backend: `Codex Agent`
- Model: `gpt-5.5`
- Sidecar URL: `http://127.0.0.1:8775`

## Precondition

The test started with no sidecar process and health down:

```sh
pkill -f '[c]odex-agent-sidecar/server.py' || true
curl --max-time 1 http://127.0.0.1:8775/health
```

Monitor baseline:

```text
13:18:14 monitor_initialized
13:18:14 sidecar=none codex=none health=DOWN
```

## Result

Selecting **Codex Agent** in Settings triggered the sidecar startup. No manual
terminal start was used.

```text
13:18:54 sidecar=21763 ... /atlas/codex-agent-sidecar/server.py; codex=none health=DOWN
13:19:00 sidecar=21763 ... /atlas/codex-agent-sidecar/server.py; codex=none health=OK {"ok": true, "model": "gpt-5.5", "codexBin": "/opt/homebrew/bin/codex", "codexAgentPath": "/Users/yashagrawal/Documents/codex-agent"}
```

Pressing **Test API Connection** then launched a real Codex request:

```text
13:19:13 sidecar=21763 ... server.py; codex=22341 node /opt/homebrew/bin/codex exec --json ...; health=OK ...
13:19:17 sidecar=21763 ... server.py; codex=none health=OK ...
```

Atlas UI showed:

```text
OK (4.3s) — Machine learning is a subfield of artificial intelligence fo...
```

The sidecar log confirmed a successful request:

```text
[extract] model=gpt-5.5 in=221ch out=105ch 4296ms
[http] 127.0.0.1 - "POST /extract HTTP/1.1" 200 -
```

## Issues Found And Fixed During Smoke

1. Direct child process startup initially failed inside the sandbox:

   ```text
   Operation not permitted
   ```

   Fix: add the sandbox permissions needed for the app-started Python sidecar:
   localhost server entitlement, read access to the sidecar package paths, read
   access to Homebrew Codex, and read/write access to `~/.codex`.

2. A LaunchAgent fallback could be bootstrapped from the shell but not from the
   sandboxed app:

   ```text
   launchctl bootstrap ... failed: Bootstrap failed: 5: Input/output error
   ```

   Fix: keep startup as an app child process instead of LaunchAgent bootstrap.

3. The first successful sidecar process could not authenticate Codex:

   ```text
   HTTP error: 401 Unauthorized
   ```

   Root cause: the sandboxed child inherited the app container home, so Codex
   could not see the real user's `~/.codex` auth/config.

   Fix: set `HOME` and `CODEX_HOME` for the sidecar child based on the real
   user home inferred from the sidecar script path.

## Verification Commands

Focused XCTest:

```sh
xcodebuild test \
  -project pdf_app1.xcodeproj \
  -scheme pdf_app1 \
  -configuration Debug \
  -only-testing:pdf_app1Tests/CodexAgentBackendTests
```

Result:

```text
8 tests, 0 failures
```

## Notes

- Codex Agent is still LLM-only. It does not provide an embedding backend.
- Sidecar log path:

  ```text
  ~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/codex-agent-sidecar.log
  ```

## Follow-Up: Finder/Xcode App Launch Python Path

After the first commit, a real app launch reported repeated `/health`
connection refusals and ended with:

```text
Model unavailable: Codex Agent sidecar did not become ready at http://127.0.0.1:8775 after Atlas started it.
```

The sidecar log contained:

```text
xcrun: error: cannot be used within an App Sandbox.
```

Root cause: the launcher used `/usr/bin/env python3`. In the user's app launch
environment, that resolved to Apple's `/usr/bin/python3` developer-tool shim,
which invokes `xcrun`; `xcrun` cannot run inside App Sandbox.

Fix: resolve a real Python executable before starting the sidecar and skip the
`/usr/bin/python3` shim. The preferred candidates are:

- `$ATLAS_CODEX_AGENT_PYTHON`
- `/Library/Frameworks/Python.framework/Versions/Current/bin/python3`
- `/opt/homebrew/bin/python3`
- `/usr/local/bin/python3`

The sandbox entitlements also include read access for
`/Library/Frameworks/Python.framework/`.

## Follow-Up: Sandbox Hangs Opening Code Under Documents

The Python-path fix exposed two additional sandbox hangs during the same
Settings -> AI -> Codex Agent flow:

1. Python could start, but hung opening `atlas/codex-agent-sidecar/server.py`
   directly from the user's `Documents` tree.
2. Copying the script into the app container helped Python start the copied
   file, but the sidecar then hung importing the sibling
   `~/Documents/codex-agent` package.

Final fix:

- Bundle `codex-agent-sidecar/server.py` into `pdf_app1.app/Contents/Resources`.
- Copy the bundled resource into Atlas Application Support before launch.
- Make the sidecar self-contained so it no longer imports `codex-agent` from
  `Documents` at runtime.
- Use the app-container Application Support directory as the sidecar working
  directory.
- Remove the `Documents` read exceptions from the app sandbox entitlements.

Retest from a clean state:

```text
15:44:30 sidecar=none health=DOWN
15:44:52 sidecar=86285 health={"ok": true, "model": "gpt-5.5", "codexBin": "/opt/homebrew/bin/codex", "sidecar": "self-contained"}
15:45:02 sidecar=86285 health={"ok": true, "model": "gpt-5.5", "codexBin": "/opt/homebrew/bin/codex", "sidecar": "self-contained"}
```

Settings showed:

```text
OK (4.5s) — Machine learning is a subfield of artificial intelligence fo...
```

The sidecar log confirmed:

```text
Atlas Codex Agent sidecar listening on http://127.0.0.1:8775
  sidecar:     self-contained
[extract] model=gpt-5.5 in=221ch out=105ch 4467ms
[http] 127.0.0.1 - "POST /extract HTTP/1.1" 200 -
```

## Follow-Up: Extraction Failed Because Node Was Missing From PATH

A later user run could start the app and select Codex Agent, but document
analysis reached Step 4 and repeated `/health` checks failed with connection
errors:

```text
NSURLErrorDomain Code=-1004 "Could not connect to the server."
[CodexAgent] Health check failed: Could not connect to the server.
Model unavailable: Codex Agent sidecar did not become ready at http://127.0.0.1:8775 after Atlas started it.
```

The sidecar log showed the real extraction failure:

```text
RuntimeError: codex exited 127: env: node: No such file or directory
NameError: name 'sys' is not defined
```

Root cause:

- Atlas set `CODEX_BIN=/opt/homebrew/bin/codex`, but GUI app launches did not
  provide a shell PATH that included `/opt/homebrew/bin` or `/usr/local/bin`.
- The Codex CLI is installed as a Node entrypoint, so `#!/usr/bin/env node`
  failed even though the `codex` path itself was correct.
- The sidecar's exception logging used `sys.stderr` after `import sys` had been
  removed, so the handler dropped the HTTP request instead of returning a clean
  502.

Fix:

- Restore `import sys` in the sidecar.
- Prepend the Python directory, `/opt/homebrew/bin`, and `/usr/local/bin` to
  the sidecar child `PATH` while preserving and de-duplicating the inherited
  app environment.

Retest from the Atlas UI:

```text
15:55:31 sidecar=90931 health={"ok": true, "model": "gpt-5.5", "codexBin": "/opt/homebrew/bin/codex", "sidecar": "self-contained"}
Settings Test API Connection: OK (7.5s)
[extract] model=gpt-5.5 in=221ch out=58ch 7467ms
[http] 127.0.0.1 - "POST /extract HTTP/1.1" 200 -
```

A focused document analysis then generated visible Concept nodes and saved a
graph with semantic-level counts:

```json
{
  "nodes": 64,
  "edges": 87,
  "levels": [
    { "level": "concept", "count": 13 },
    { "level": "entity", "count": 51 }
  ]
}
```
