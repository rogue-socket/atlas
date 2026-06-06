#!/usr/bin/env python3
"""Atlas Codex Agent sidecar.

Local HTTP bridge from the sandboxed Atlas app to the user's Codex CLI.
Atlas-specific stdin prompt handling lives here so long PDF prompts do not hit
argv limits.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


HOST = "127.0.0.1"
PORT = int(os.environ.get("ATLAS_CODEX_AGENT_PORT", "8775"))
DEFAULT_MODEL = os.environ.get("ATLAS_CODEX_AGENT_MODEL", "gpt-5.3-codex-spark")
DEFAULT_REASONING_EFFORT = os.environ.get("ATLAS_CODEX_AGENT_REASONING_EFFORT", "medium")
TIMEOUT_SECONDS = float(os.environ.get("ATLAS_CODEX_AGENT_TIMEOUT", "600"))
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")
SANDBOX = os.environ.get("ATLAS_CODEX_AGENT_SANDBOX", "read-only")
MAX_BODY_BYTES = 8_000_000

SERVICE_PROMPT = (
    "You are a text-processing service for Atlas. Do not inspect files or run "
    "commands. Follow the user instructions exactly and return only the "
    "requested output, with no preamble, explanation, or commentary."
)


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_json_body(handler: BaseHTTPRequestHandler) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0:
        raise ValueError("missing request body")
    if length > MAX_BODY_BYTES:
        raise ValueError("request body too large")
    raw = handler.rfile.read(length)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("invalid JSON body") from exc
    if not isinstance(parsed, dict):
        raise ValueError("JSON body must be an object")
    return parsed


def build_exec_command(
    *,
    codex_bin: str,
    cwd: Path,
    model: str,
    reasoning_effort: str,
    sandbox: str,
    output_last_message: Path,
) -> list[str]:
    return [
        codex_bin,
        "exec",
        "--json",
        "--cd",
        str(cwd),
        "--model",
        model,
        "--config",
        f'reasoning_effort="{reasoning_effort}"',
        "--sandbox",
        sandbox,
        "--output-last-message",
        str(output_last_message),
        "--ephemeral",
        "--skip-git-repo-check",
        "-",
    ]


def parse_jsonl_events(text: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            events.append({"type": "raw", "line": line})
            continue
        if isinstance(payload, dict):
            events.append(payload)
        else:
            events.append({"type": "raw", "value": payload})
    return events


def _last_message_from_events(events: list[dict[str, Any]]) -> str | None:
    for event in reversed(events):
        data = event
        if not isinstance(data, dict):
            continue
        for key in ("last_message", "message", "content", "text"):
            value = data.get(key)
            if isinstance(value, str) and value:
                return value
    return None


def _read_last_message(path: Path) -> str | None:
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8").strip()
    return text or None


def _normalize_reasoning_effort(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"low", "medium", "high"}:
        return normalized
    return DEFAULT_REASONING_EFFORT


def run_codex(prompt: str, model: str, reasoning_effort: str | None = None) -> str:
    full_prompt = f"{SERVICE_PROMPT}\n\n{prompt}"
    selected_reasoning_effort = _normalize_reasoning_effort(reasoning_effort or DEFAULT_REASONING_EFFORT)
    with tempfile.TemporaryDirectory(prefix="atlas-codex-agent-") as tmp:
        tmp_path = Path(tmp)
        output_last_message = tmp_path / "last_message.txt"
        cmd = build_exec_command(
            codex_bin=CODEX_BIN,
            cwd=tmp_path,
            model=model,
            reasoning_effort=selected_reasoning_effort,
            sandbox=SANDBOX,
            output_last_message=output_last_message,
        )
        proc = subprocess.run(
            cmd,
            input=full_prompt,
            text=True,
            capture_output=True,
            check=False,
            timeout=TIMEOUT_SECONDS,
        )
        events = parse_jsonl_events(proc.stdout)
        text = _read_last_message(output_last_message) or _last_message_from_events(events)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()[:1000]
            raise RuntimeError(f"codex exited {proc.returncode}: {detail}")
        if not text:
            detail = (proc.stderr or proc.stdout or "").strip()[:1000]
            raise RuntimeError(f"codex returned no final message: {detail}")
        return text


class Handler(BaseHTTPRequestHandler):
    server_version = "AtlasCodexAgentSidecar/0.1"

    def do_GET(self) -> None:
        if self.path != "/health":
            _send_json(self, 404, {"error": "not found"})
            return
        _send_json(
            self,
            200,
            {
                "ok": True,
                "model": DEFAULT_MODEL,
                "codexBin": CODEX_BIN,
                "sidecar": "self-contained",
            },
        )

    def do_POST(self) -> None:
        if self.path != "/extract":
            _send_json(self, 404, {"error": "not found"})
            return
        try:
            payload = _read_json_body(self)
            prompt = payload.get("prompt")
            if not isinstance(prompt, str) or not prompt:
                raise ValueError('missing or empty "prompt"')
            model_value = payload.get("model")
            model = model_value if isinstance(model_value, str) and model_value else DEFAULT_MODEL
            effort_value = payload.get("reasoning_effort")
            reasoning_effort = effort_value if isinstance(effort_value, str) and effort_value else None

            started = time.monotonic()
            text = run_codex(prompt, model, reasoning_effort)
            elapsed_ms = int((time.monotonic() - started) * 1000)
            print(
                f"[extract] model={model} reasoning={_normalize_reasoning_effort(reasoning_effort or DEFAULT_REASONING_EFFORT)} in={len(prompt)}ch "
                f"out={len(text)}ch {elapsed_ms}ms",
                flush=True,
            )
            _send_json(self, 200, {"text": text})
        except ValueError as exc:
            _send_json(self, 400, {"error": str(exc)})
        except subprocess.TimeoutExpired:
            _send_json(self, 504, {"error": f"codex timed out after {TIMEOUT_SECONDS:.0f}s"})
        except Exception as exc:
            print(f"[extract] FAILED: {exc}", file=sys.stderr, flush=True)
            _send_json(self, 502, {"error": str(exc)})

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"[http] {self.address_string()} - {fmt % args}", flush=True)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Atlas Codex Agent sidecar listening on http://{HOST}:{PORT}")
    print(f"  model:       {DEFAULT_MODEL}")
    print(f"  reasoning:   {DEFAULT_REASONING_EFFORT}")
    print(f"  codex:       {CODEX_BIN}")
    print("  sidecar:     self-contained")
    print(f"  health:      curl http://{HOST}:{PORT}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nAtlas Codex Agent sidecar stopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
