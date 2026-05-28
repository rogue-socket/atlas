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
