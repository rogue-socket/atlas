#!/usr/bin/env node
//
// Atlas Claude sidecar
//
// A tiny localhost HTTP server that wraps the `claude` CLI in headless mode,
// so the sandboxed Atlas macOS app can use Claude for concept extraction.
//
// Atlas is sandboxed and cannot spawn `claude` itself; it reaches this server
// over loopback HTTP instead (the app holds com.apple.security.network.client).
//
// Auth: this uses your logged-in Claude *subscription* (OAuth), NOT a metered
// API key — ANTHROPIC_API_KEY is stripped from the child environment so the
// CLI falls back to subscription credentials. Subscription rate limits apply.
//
// Run:  node server.mjs        (no npm install — Node builtins only)
//
// Env knobs:
//   ATLAS_SIDECAR_PORT     listen port            (default 8765)
//   ATLAS_SIDECAR_MODEL    default model alias    (default "opus")
//   ATLAS_SIDECAR_TIMEOUT  per-request kill (ms)  (default 280000)
//   CLAUDE_BIN             path to the claude CLI (default "claude" on PATH)
//

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const HOST = '127.0.0.1';
const PORT = Number(process.env.ATLAS_SIDECAR_PORT) || 8765;
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const DEFAULT_MODEL = process.env.ATLAS_SIDECAR_MODEL || 'opus';
const TIMEOUT_MS = Number(process.env.ATLAS_SIDECAR_TIMEOUT) || 280_000;

// Minimal system prompt — replaces the multi-thousand-token Claude Code agent
// prompt. Atlas's PromptTemplates already carries all task instructions, so the
// system prompt only needs to keep the model from adding chatter.
const SYSTEM_PROMPT =
  'You are a text-processing service. Follow the instructions in the message ' +
  'exactly and return only the requested output, with no preamble, no ' +
  'explanation, and no commentary.';

/**
 * Run one headless `claude` invocation and resolve with the result text.
 * The prompt is fed via stdin (no argv length limits, no shell escaping).
 */
function runClaude(prompt, model) {
  return new Promise((resolve, reject) => {
    // Strip ANTHROPIC_API_KEY so the CLI authenticates with the logged-in
    // subscription (OAuth) instead of metered API billing.
    const env = { ...process.env };
    delete env.ANTHROPIC_API_KEY;

    const args = [
      '-p',                             // headless print mode
      '--output-format', 'json',        // single structured result object
      '--model', model,
      '--system-prompt', SYSTEM_PROMPT, // replace the heavy agent prompt
      '--no-session-persistence',       // don't litter ~/.claude with sessions
      '--tools', '',                    // disable all tools (drops tool-def tokens)
    ];

    // tmpdir() as cwd so the CLI doesn't auto-discover a project CLAUDE.md.
    const child = spawn(CLAUDE_BIN, args, { env, cwd: tmpdir() });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      reject(new Error(`claude timed out after ${TIMEOUT_MS}ms`));
    }, TIMEOUT_MS);

    child.stdout.on('data', (d) => { stdout += d; });
    child.stderr.on('data', (d) => { stderr += d; });

    child.on('error', (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error(`failed to spawn '${CLAUDE_BIN}': ${err.message}`));
    });

    child.on('close', (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`claude exited ${code}: ${(stderr || stdout).slice(0, 500)}`));
        return;
      }
      let parsed;
      try {
        parsed = JSON.parse(stdout.trim());
      } catch {
        reject(new Error(`unparseable claude output: ${stdout.slice(0, 500)}`));
        return;
      }
      if (parsed.is_error) {
        reject(new Error(`claude reported error (${parsed.subtype}): ${parsed.result || ''}`));
        return;
      }
      resolve(String(parsed.result ?? ''));
    });

    child.stdin.write(prompt);
    child.stdin.end();
  });
}

function sendJSON(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(body);
}

const server = createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    sendJSON(res, 200, { ok: true, model: DEFAULT_MODEL });
    return;
  }

  if (req.method === 'POST' && req.url === '/extract') {
    let body = '';
    req.on('data', (c) => {
      body += c;
      if (body.length > 8_000_000) req.destroy(); // 8 MB guard
    });
    req.on('end', async () => {
      let payload;
      try {
        payload = JSON.parse(body);
      } catch {
        sendJSON(res, 400, { error: 'invalid JSON body' });
        return;
      }
      const prompt = payload.prompt;
      if (typeof prompt !== 'string' || prompt.length === 0) {
        sendJSON(res, 400, { error: 'missing or empty "prompt"' });
        return;
      }
      const model = (typeof payload.model === 'string' && payload.model)
        ? payload.model
        : DEFAULT_MODEL;

      const started = Date.now();
      try {
        const text = await runClaude(prompt, model);
        console.log(
          `[extract] model=${model} in=${prompt.length}ch ` +
          `out=${text.length}ch ${Date.now() - started}ms`
        );
        sendJSON(res, 200, { text });
      } catch (err) {
        console.error(`[extract] FAILED after ${Date.now() - started}ms: ${err.message}`);
        sendJSON(res, 502, { error: err.message });
      }
    });
    return;
  }

  sendJSON(res, 404, { error: 'not found' });
});

server.listen(PORT, HOST, () => {
  console.log(`Atlas Claude sidecar listening on http://${HOST}:${PORT}`);
  console.log(`  model:   ${DEFAULT_MODEL}`);
  console.log(`  claude:  ${CLAUDE_BIN}`);
  console.log(`  health:  curl http://${HOST}:${PORT}/health`);
});
