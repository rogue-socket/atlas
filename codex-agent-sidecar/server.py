#!/usr/bin/env python3
"""Atlas Codex Agent sidecar.

Local HTTP bridge from the sandboxed Atlas app to the user's Codex CLI.
The sibling codex-agent package is imported read-only; Atlas-specific stdin
prompt handling lives here so long PDF prompts do not hit argv limits.
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
DEFAULT_MODEL = os.environ.get("ATLAS_CODEX_AGENT_MODEL", "gpt-5.5")
TIMEOUT_SECONDS = float(os.environ.get("ATLAS_CODEX_AGENT_TIMEOUT", "600"))
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")
SANDBOX = os.environ.get("ATLAS_CODEX_AGENT_SANDBOX", "read-only")
MAX_BODY_BYTES = 8_000_000

SERVICE_PROMPT = (
    "You are a text-processing service for Atlas. Do not inspect files or run "
    "commands. Follow the user instructions exactly and return only the "
    "requested output, with no preamble, explanation, or commentary."
)


def _candidate_codex_agent_paths() -> list[Path]:
    paths: list[Path] = []
    if os.environ.get("CODEX_AGENT_PATH"):
        paths.append(Path(os.environ["CODEX_AGENT_PATH"]).expanduser())

    here = Path(__file__).resolve()
    paths.extend(
        [
            here.parents[3] / "codex-agent",  # ../codex-agent from pdf_projects/
            here.parents[2] / "codex-agent",  # fallback if colocated under pdf_projects/
            Path.cwd().parent / "codex-agent",
        ]
    )
    return paths


def _install_codex_agent_path() -> str | None:
    for path in _candidate_codex_agent_paths():
        if (path / "codex_agent").is_dir():
            sys.path.insert(0, str(path))
            return str(path)
    return None


CODEX_AGENT_PATH = _install_codex_agent_path()
IMPORT_ERROR: Exception | None = None

try:
    from codex_agent.engine.codex_exec import (  # type: ignore
        CodexExecConfig,
        build_exec_command,
        parse_jsonl_events,
    )
except Exception as exc:  # pragma: no cover - surfaced by /health
    IMPORT_ERROR = exc


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


def _last_message_from_events(events: list[Any]) -> str | None:
    for event in reversed(events):
        data = getattr(event, "data", {})
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


def run_codex(prompt: str, model: str) -> str:
    if IMPORT_ERROR is not None:
        raise RuntimeError(f"could not import codex-agent: {IMPORT_ERROR}")

    full_prompt = f"{SERVICE_PROMPT}\n\n{prompt}"
    with tempfile.TemporaryDirectory(prefix="atlas-codex-agent-") as tmp:
        tmp_path = Path(tmp)
        output_last_message = tmp_path / "last_message.txt"
        config = CodexExecConfig(
            codex_bin=CODEX_BIN,
            cwd=tmp_path,
            model=model,
            sandbox=SANDBOX,
            output_last_message=output_last_message,
            ephemeral=True,
            skip_git_repo_check=True,
        )
        cmd = build_exec_command(config, "-")
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
        if IMPORT_ERROR is not None:
            _send_json(
                self,
                503,
                {
                    "ok": False,
                    "error": f"could not import codex-agent: {IMPORT_ERROR}",
                    "codexAgentPath": CODEX_AGENT_PATH,
                },
            )
            return
        _send_json(
            self,
            200,
            {
                "ok": True,
                "model": DEFAULT_MODEL,
                "codexBin": CODEX_BIN,
                "codexAgentPath": CODEX_AGENT_PATH,
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

            started = time.monotonic()
            text = run_codex(prompt, model)
            elapsed_ms = int((time.monotonic() - started) * 1000)
            print(
                f"[extract] model={model} in={len(prompt)}ch "
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
    print(f"  codex:       {CODEX_BIN}")
    print(f"  codex-agent: {CODEX_AGENT_PATH or '<not found>'}")
    print(f"  health:      curl http://{HOST}:{PORT}/health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nAtlas Codex Agent sidecar stopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
