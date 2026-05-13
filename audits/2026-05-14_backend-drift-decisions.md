# Backend Drift — Sign-Off Decisions

Companion to `2026-05-14_simplify-survey.md` Tier-1 #1.

Five real divergences exist between `ClaudeBackend.swift`, `OpenAIBackend.swift`, and `GeminiBackend.swift`. Before consolidating into a shared `LLMBackend` protocol with default implementations, we have to pick a single behavior (or explicitly preserve the variation) for each. Doing this *before* the refactor avoids freezing arbitrary winners into the shared layer.

Mark each decision A / B / C below and I'll apply them as three surgical edits to the existing files. Then we re-run the app, verify no regressions, then collapse into the shared protocol.

---

## Drift 1 — `parseExtractionResponse` error type on decode failure

**Current state:**
- Claude (`ClaudeBackend.swift:158-166`): wraps `DecodingError` → `AIError.decodingError(error.localizedDescription)`.
- OpenAI (`OpenAIBackend.swift:161-165`): rethrows raw `DecodingError`.
- Gemini (`GeminiBackend.swift:160-170`): logs the cleaned JSON preview, then wraps → `AIError.decodingError(…)`.

**Caller impact:** `ExtractionPipeline.swift:260` — any throw aborts the batch. Both error types are caught the same way, only `error.localizedDescription` differs.

**Options:**
- **A.** Unify to **wrap → `AIError.decodingError(...)`** (Claude/Gemini's behavior). Pro: typed Atlas error reaches the caller; logs/UI surface "Failed to decode response: …" instead of Swift's raw `DecodingError` debug description.
- **B.** Unify to **rethrow raw `DecodingError`** (OpenAI's behavior). Pro: Swift's `DecodingError` is richer (key path, debug context); useful when actually debugging.
- **C.** Keep both, signal via `var richErrorLogging: Bool { get }` per backend.

**Recommendation: A.** The whole point of `AIError` is to be the unified surface. OpenAI's drift is almost certainly accidental — the original commit (`7efee06`) had the wrapper, OpenAI just lost it later. Keep Gemini's extra log line on failure (it's been valuable enough that the author added it; cheap to keep).

**Decision:** ☑ **A**   ☐ B   ☐ C

---

## Drift 2 — `parseAnswerResponse` on UTF8 conversion failure

**Current state:**
- Claude (`ClaudeBackend.swift:182-191`): `guard let data = cleaned.data(using: .utf8) else { throw AIError.decodingError("Invalid UTF8") }`, then decode-with-fallback.
- OpenAI (`OpenAIBackend.swift:180-190`): `guard let data … else { return AnswerWithCitations(answer: text, citations: []) }`, then decode-with-fallback.
- Gemini (`GeminiBackend.swift:187-197`): same as OpenAI.

**Caller impact:** `ChatViewModel.swift:60-72` shows `error.localizedDescription` as a chat error message on throw, or surfaces `result.answer` + empty citations on success. Net difference:
- Claude path on UTF8 failure: user sees "Failed to decode response: Invalid UTF8" in chat.
- OpenAI/Gemini path on UTF8 failure: user sees the raw response *as* the assistant's answer, with no citations.

**Reality check:** UTF8 conversion failure here is near-impossible — `URLSession`'s `data` is whatever the server sent, and the upstream `JSONSerialization.jsonObject` step in transport would have already failed on non-UTF8 bytes. This branch is essentially dead. But we still want one behavior.

**Options:**
- **A.** Unify to **throw `AIError.decodingError`** (Claude's behavior). The dead branch becomes visible if ever hit.
- **B.** Unify to **return fallback empty-citations** (OpenAI/Gemini's behavior). The original 7efee06 commit had this in all three; Claude diverged later. Surfaces raw text rather than an error.

**Recommendation: B.** This matches the original intent and the decode-failure fallback right below it (which all three already do). The "throw on UTF8 fail but swallow on JSON decode fail" mix in Claude is logically inconsistent inside its own function.

**Decision:** ☑ **A** (overrides recommendation)   ☐ B

**Rationale for choosing A over the recommendation:** showing the user a raw garbled response as if it were the assistant's answer is worse UX than surfacing a clear error — the user can't tell the answer is broken when it's rendered as a normal chat message with no citations. This also implies tightening the *next* line (the JSON-decode fallback): if we throw on UTF8 failure for consistency, the logical follow-through is to throw on JSON-decode failure too (instead of returning raw text as the answer with no citations). Apply the same "show error, don't show garbage" principle to both fallback branches in `parseAnswerResponse` across all three backends.

---

## Drift 3 — `isAvailable` preflight inside transport

**Current state:**
- Claude (`ClaudeBackend.swift:103`): `guard isAvailable else { throw AIError.noAPIKey }` at top of `sendMessage`.
- OpenAI (`OpenAIBackend.swift:108`): no preflight. `isAvailable` is `!apiKey.isEmpty || baseURL.contains("localhost")` (line 20), so adding the guard would still pass for Ollama, but missing key + non-localhost silently posts a request that the server rejects with 401.
- Gemini (`GeminiBackend.swift:99`): `guard isAvailable else { throw AIError.noAPIKey }`.

**Reason for the variation:** `OpenAIBackend` is dual-purpose — it's also the Ollama backend (`AIServiceManager.swift:60-63` instantiates it with `apiKey: ""` + localhost base URL). The reason it has the permissive `isAvailable` is precisely to let Ollama work without a key. **The variation is intentional**; the question is only whether the preflight should still run.

**Options:**
- **A.** Add the `guard isAvailable else { throw .noAPIKey }` to OpenAI's transport too. Ollama already passes `isAvailable` (localhost branch), so this is safe. Pro: any future non-Ollama path that loses its key fails fast with a typed error instead of an HTTP 401.
- **B.** Leave OpenAI as-is. Rely on the server's 401 to surface the missing-key case.

**Recommendation: A.** It's consistent with Claude/Gemini, costs nothing for Ollama (already passes the check), and gives a typed error instead of an HTTP error for the no-key OpenAI case. The current `AIServiceManager.createBackend()` already guards `case .openai` with `guard !apiKey.isEmpty else { return nil }`, so in practice no missing-key OpenAI backend reaches transport — but defense-in-depth is cheap here.

**Decision:** ☑ **A**   ☐ B

---

## Drift 4 — Sampling parameters (`temperature`)

**Current state:**
- Claude (`ClaudeBackend.swift:118-124`): no `temperature` set in body. Anthropic's API defaults to **1.0** when omitted.
- OpenAI (`OpenAIBackend.swift:120-127`): `"temperature": 0.1`.
- Gemini (`GeminiBackend.swift:118-122`): `"temperature": 0.1` inside `generationConfig`.

**This is the most consequential drift.** Concept extraction at temp=0.1 vs temp=1.0 produces materially different outputs — same prompt against Claude will yield more varied / creative concept names and edge proposals than the same prompt against OpenAI/Gemini. Anyone who's been A/B-comparing backends has been comparing apples to oranges.

**Was it intentional?** Almost certainly not — the rest of the commit history shows lockstep edits that just missed this knob.

**Options:**
- **A.** Set `temperature: 0.1` for all three. Aligns behavior; deterministic-ish extraction is the right default for structured-JSON output.
- **B.** Set `temperature` to a different shared value (e.g. 0.2).
- **C.** Keep per-vendor as today (Claude default 1.0; OpenAI/Gemini 0.1). Document why.

**Recommendation: A** (temperature 0.1 across all three). It's the value OpenAI/Gemini already use; structured JSON extraction benefits from lower temperature; Claude's hot default has likely been masking issues or producing varied results across runs. Worth a one-time before/after eyeball on a sample PDF after the change.

**Decision:** ☑ **A**   ☐ B (value: ___)   ☐ C

---

## Drift 5 — `max_tokens` / `maxOutputTokens` ceiling

**Current state:**
- Claude: `max_tokens: 4096`.
- OpenAI: `max_tokens: 4096`.
- Gemini: `maxOutputTokens: 32768`.

**Why the variation:** Gemini 2.5 supports very large output windows; the higher ceiling lets it return more concepts/edges per batch when extraction is deep. Claude 4.5 Sonnet supports 8192 output tokens; OpenAI gpt-4o supports 16384. Both are currently capped *below* their actual limits.

**Caller impact:** If extraction output gets truncated mid-JSON, `JSONRepair.cleanAndRepair` either recovers a partial concept list or yields a decode error. Increasing the ceiling reduces truncation risk; doesn't increase cost unless the model actually emits more tokens.

**Options:**
- **A.** Keep per-vendor, no change.
- **B.** Raise Claude to 8192 and OpenAI to 8192 (their effective output ceilings for the configured models). Leave Gemini at 32768.
- **C.** Make `maxOutputTokens` a per-backend config knob exposed through the protocol (e.g. `var maxOutputTokens: Int { get }`).

**Recommendation: B.** It matches model capabilities, costs nothing extra in practice, and reduces silent truncation. Don't unify ceilings — they reflect real vendor differences.

**Decision:** ☐ A   ☑ **B**   ☐ C

---

## Out of scope (kept as-is)

- **Per-vendor body knobs** that are vendor-specific (`anthropic-version` header, Gemini's `responseMimeType: "application/json"`). These are correctly per-backend and stay in the transport implementation after refactor.
- **HTTP paths, auth headers, response JSON paths.** These belong inside `transport(prompt:)`; the whole point of the consolidation is *not* to abstract these.
- **`displayName` mutability on OpenAIBackend** (so it can pose as Ollama). Keep as-is.
- **`extractJSON` private wrappers** that forward to `JSONRepair.cleanAndRepair`. Delete during the refactor itself; not a drift question.
- **`parseEdgesResponse`** — I re-checked, this is genuinely consistent across all three (each has the `ExtractionResponse`-wrapping retry on decode failure). No drift here.

---

## Sign-off status: ✅ Approved 2026-05-14

Final decisions:
- **D1:** A — wrap decode errors to `AIError.decodingError` across all three.
- **D2:** A (overrides recommendation) — throw on UTF8 *and* on JSON decode failure in `parseAnswerResponse`. Principle: show a clear error, never show raw garbled response as if it were the assistant's answer.
- **D3:** A — add the `guard isAvailable` preflight to OpenAI's transport (Ollama still passes via the localhost branch).
- **D4:** A — set `temperature: 0.1` in Claude's request body to match OpenAI/Gemini.
- **D5:** B — raise `max_tokens` to 8192 for Claude and OpenAI; leave Gemini at 32768.

Next steps:

1. Apply the 5 decisions as small targeted edits to the three existing backend files (no refactor yet, just reconciliation).
2. Build + smoke-test the app against each backend with an API key on hand (or at least Ollama).
3. Then move to step 2 of the broader plan: extract `LLMBackend` protocol with default implementations, leaving each backend with just `transport(prompt:) -> String` + the vendor-specific transport body. Expect ~300-400 lines deleted.
