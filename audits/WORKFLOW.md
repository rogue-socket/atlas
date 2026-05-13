# Atlas Audit Workflow

This document describes the pattern Atlas uses to work through code-quality audit findings (e.g., output of `/simplify` or `/ultrareview`) without freezing accidental drift into shared abstractions or producing unreviewable mega-commits.

It exists so future sessions don't reinvent the approach, and so the shape of the work stays consistent across different findings.

> **TL;DR.** Don't refactor first. Analyze → Decide → Reconcile → Refactor → Commit, in five distinct phases with verification between each. Sign-off on judgment calls comes before any structural change. Drift gets reconciled in-place *before* a shared abstraction freezes an arbitrary winner into the codebase.

---

## When to use this pattern

Use this pattern when:

- You have an audit finding (from `/simplify`, `/ultrareview`, a stale TODO, or your own observation) where the current code is *working* but smells.
- The "fix" is a judgment call, not a mechanical translation. (E.g., "extract a protocol" vs. "rename a variable.")
- The smell exists in **two or more files** (the standard duplication case) or touches a **two-or-more-step refactor** (the structural case).
- There's any chance the audit's recommended fix would silently regress behavior if applied blindly. Duplicated code rots — code-pasted siblings drift apart over time. A shared abstraction needs to pick one behavior, and that pick is a decision, not a reorg.

**Skip this pattern when:**

- The fix is a one-line bug. Just fix it.
- The change is purely additive (new feature, new type, new method). Just add it.
- The audit finding is wrong. File a comment with reasoning and move on.
- The smell is in exactly one file and the fix is purely local. Edit the file, ship.

The pattern has overhead — a deep-analysis pass, sometimes a sign-off doc, two commits instead of one. For trivial work that overhead is wasted. For non-trivial structural work that overhead is what stops the next maintainer from cursing your name.

---

## Inputs

The pattern assumes you have:

1. **A survey doc.** The list of audit findings, prioritized by impact, with concrete file:line pointers. The canonical example is `audits/2026-05-14_simplify-survey.md` — 30 findings in three tiers (reuse / quality / efficiency) produced by `/simplify` agents.
2. **A current working tree** that builds. If it doesn't, fix that first.
3. **A clear understanding of what you're trying to accomplish** — usually "close one specific finding from the survey."

The survey doc is the *backlog* for this workflow. You pick one finding at a time and run it through the five phases.

---

## The five phases

### Phase 0: Pick one finding

Don't try to do multiple findings in one pass. Each finding gets its own analysis, its own decisions, its own commit shape. Bundling tempts you to mega-commit, and a mega-commit hides drift fixes inside refactor diff.

Pick by:

- **Impact first.** Tier 1 before Tier 3 unless there's a reason.
- **Independence.** Findings that don't touch each other can be done in any order.
- **Setup-cost.** If finding A's refactor unlocks call-site changes that finding B needs, do A first.

Update the survey's status table when you pick — set status to "in progress" or move to the next-natural slot in your `backlog.md` so other sessions don't grab it.

### Phase 1: Deep "why is it like this" analysis

**This is the most important phase and the easiest one to skip.** Skipping it produces refactors that freeze accidental drift into shared abstractions, which is worse than the duplication you started with.

Before touching any code, write a written analysis covering:

1. **What the code actually does.** Concrete, with file:line. Read the relevant files (or large coherent sections — not "the whole 1800-line file"). Don't just trust the audit's framing.

2. **Why it ended up this way.** Check `git log -- <file>` for the original commit and subsequent edits. Frequently the duplication or smell was *original* — copy-pasted in one shot at project start, when extracting a shared shape would have been premature. Knowing this changes your refactor: you're collapsing an over-time-rotted copy, not undoing a deliberate design choice.

3. **What the audit overstates.** Audits exaggerate, especially perf claims. Tier 1 #2 in today's survey was framed as "O(n²) hot path" — true, but in absolute terms it's milliseconds against multi-second LLM network calls. The *real* value was dedup, not speed. Re-derive value yourself; don't accept the audit's framing.

4. **What the audit understates.** The flip side. Maybe the audit calls it "code smell" but the silent drift between siblings is already a bug.

5. **Constraints to know about.** Threading model, conformance requirements, framework quirks, deliberate workarounds. Today's `KnowledgeGraph` is `@Observable nonisolated` to dodge a macOS 26.3 SwiftConcurrency bug — that's load-bearing context, written in a code comment, that affects how you add fields.

6. **What "fix" actually looks like.** Sketch, not final code. Identify the shape of the change and the boundaries.

7. **Risks.** What could regress? What downstream callers rely on the current shape? Is there test coverage?

8. **Recommendation.** A clear "I think we should do X because Y."

**Output:** a Markdown doc, in chat or as a deliverable, ~500–1500 words. The shape of these analyses today became Tier 1 #1's analysis (delivered in chat) and Tier 1 #2's analysis (also chat). Long enough to be useful, short enough to be readable.

**Stop before this phase is done.** It's tempting to start coding mid-analysis. Don't. The analysis is what the user signs off on; the code follows.

### Phase 2: Decisions doc (optional but encouraged)

When the analysis surfaces real judgment calls — multiple plausible behaviors, where picking one freezes a choice into the shared layer — write a numbered decisions doc with sign-off marks. Today's canonical example is `audits/2026-05-14_backend-drift-decisions.md`.

**Use a decisions doc when:**

- Three or more distinct "we have to pick one of these" choices exist.
- A naive refactor would silently freeze an arbitrary winner into the abstraction.
- The user is the right stakeholder for the choice. (You aren't always.)

**Skip a decisions doc when:**

- There's only one plausible option per choice. Just say so in the analysis.
- The choice is small enough to inline into a commit message.

**Shape of each decision:**

- **Drift N — short title.** One-sentence framing.
- **Current state:** what each variant does today, with file:line. Concrete.
- **Caller impact:** what the user sees / what the next module sees. Translate consequences out of the code domain into the user-or-system domain.
- **Options A/B/C:** one paragraph each, with pros/cons. Avoid bias-loading the options — describe each fairly.
- **Recommendation:** your call, with reasoning. One paragraph.
- **Decision:** `☐ A   ☐ B   ☐ C` line for sign-off marks. The user fills these in (or you do, after they tell you in chat).

When the user **overrides** a recommendation, capture it explicitly:

```
**Decision:** ☑ **A** (overrides recommendation)   ☐ B

**Rationale for choosing A over the recommendation:** …
```

Today, D2 in the backend drift doc was an override. The override and the user's stated rationale are preserved in the doc — that's important. The reasoning explains the override to future maintainers who might otherwise re-derive my original (rejected) recommendation.

**Wait for sign-off.** Don't start Phase 3 with unmarked decisions. If the user is asynchronous, hand them the doc and wait.

### Phase 3: Step 1 — Surgical reconciliation

Apply the signed-off decisions as **targeted edits that preserve current file shape**. Don't refactor yet. Don't extract abstractions. Don't rename. Just change the lines that have to change.

**Why this is a separate phase from the refactor:**

1. **It's the smallest possible change to validate the decisions are right.** If decision D was wrong, the revert is one commit; a refactor-bundled revert is painful.
2. **It keeps the diff readable.** Reconciliation diffs are line-level; refactor diffs are structural. Mixed diffs are unreviewable.
3. **It catches behavioral regressions before they get tangled up with structural ones.** Build green after Phase 3 = behavior reconciled. Build green after Phase 4 = structure preserved. Together = success.
4. **It separates the *what* from the *how*.** Phase 3 commits answer "what changed in behavior." Phase 4 commits answer "what changed in shape." Both are valuable but they're different questions.

Today's Step 1 (for Tier 1 #1) was 7 surgical edits across the three backend files: temperature added to Claude's body, max_tokens raised, isAvailable preflight added to OpenAI, parser error-handling unified. **No protocol extraction yet.** The three backend files still looked nearly-duplicate after Step 1 — they just behaved consistently for the first time.

**Verification after Phase 3:** build green. If you can smoke-test (run the app, exercise the affected code paths), do so. For backend behavior changes especially, build-green isn't proof of correctness — only a live exercise is.

If smoke-testing isn't practical, document what wasn't tested and surface it in the commit message and the session handoff. Future-you needs to know what's unverified.

### Phase 4: Step 2 — Structural refactor

Now the actual cleanup. With Phase 3 decisions locked in, extract the protocol / add the index / split the file / consolidate the helpers / etc.

**The refactor must be behavior-preserving.** Phase 3 was the behavior change. Phase 4 must produce the same observable behavior with cleaner code.

Today's Step 2 (for Tier 1 #1) introduced `LLMBackend` protocol with default implementations and `LLMResponseParser` enum, rewrote the three vendor backends to only carry transport + identity. The reconciled behaviors from Phase 3 carried forward into the new shape — Claude's `temperature: 0.1` lived in its `transport(prompt:)`, the unified error wrapping lived in the parser enum, etc.

**Verification after Phase 4:** build green again. Optionally: same smoke test as Phase 3 to confirm nothing changed. Same caveats about live-vs-build apply.

**When Phase 3 + Phase 4 collapse into one commit:** if the intermediate file shape from Phase 3 no longer exists in the working tree (because Phase 4 overwrote those files entirely), you can't easily commit them separately. Bundle them, but split the *commit body* into Step-1 and Step-2 sections so the rationale stays separable. Today's `058936e` commit message uses this shape — "Step 1 reconcile" + "Step 2 extract" headers in the body.

### Phase 5: Commit shape

Land in **logical seams**, not "all the changes in one commit." Today's shape for two findings was four commits:

1. **`46ea52c` Audit docs.** Standalone — survey + decisions docs. No code impact. Commits first so the rationale exists in the repo even if subsequent commits are amended.
2. **`058936e` Backend dedup + drift reconciliation (Tier 1 #1).** All four backend files (3 modified, 1 new). Body explains the Step 1 + Step 2 split since they're bundled.
3. **`be9814b` Label index + private(set) lock-down (Tier 1 #2).** `KnowledgeGraph.swift` + 3 call-site files. Body explains both the structural change and the call-site dedup as one thought.
4. **`0423050` Backlog sync.** Standalone — `backlog.md` only. Captures the Done-2026-MM-DD block so cold-start sessions see the work.

**Each commit's body should explain *why* the change exists, not just *what*.** The audit findings and decision rationale are the "why." Future maintainers (including future-you) will read these messages to understand whether the change is still load-bearing.

**Commit message conventions:**

- Subject line < 70 chars, sentence-imperative ("Extract LLMBackend protocol..."), no trailing period.
- Body wraps at ~72 chars. First paragraph is the "what + why" headline.
- Subsequent paragraphs cover constraints, decisions, what was deliberately not done.
- Closing trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- No "Generated with Claude Code" line in Atlas — match local commits' style.
- If the commit closes a GitHub issue, use `Closes #N` in the body.

**Where to stage:** specific files by name (`git add path/to/file.swift`). Never `git add -A` or `git add .` — they catch unwanted files (`.DS_Store`, partial edits, untracked scratch).

**Pre-commit hooks:** don't skip them. If a hook fails, fix the underlying issue. Don't `--no-verify`.

**Push timing:** ask first unless the user has already given a session-scoped push authorization. Today the user explicitly said "push" before the push. Don't infer authorization from a previous "push" earlier in the day.

---

## Anti-patterns

- **Skipping Phase 1.** Diving into the refactor first freezes whatever drift currently exists into the shared layer, often as bugs. Always analyze first.
- **Mega-commits.** A 600-line commit that mixes drift fixes with structural refactor is unreviewable. Split.
- **Auto-accepting the audit's framing.** Audits exaggerate perf claims and underweight maintenance value. Re-derive the value yourself.
- **Refactoring around drift.** If parser A throws and parser B swallows, don't write a shared parser that does both — pick one, sign off, then refactor. This is the entire reason Phase 2 exists.
- **Forgetting verification between phases.** Each phase has a checkpoint; if Phase 3 didn't build, don't move on to Phase 4.
- **Refactoring "while you're in the area."** Resist scope creep. If you spot another smell while doing this finding, write it in the backlog or note it in the commit message — don't fold it in. (Today's Tier 3 #24 partial close was a deliberate, narrow side-effect that was unavoidable for Phase 3 to work. That's the only acceptable scope-creep: side-effects that fall out of the necessary change.)
- **Designing for the third backend you don't have.** When abstracting, abstract for *what exists today*, not for hypothetical future variation. If a 4th LLM backend appears and breaks the protocol's assumptions, refactor then — don't over-engineer now.
- **Touching unrelated callers.** Today's `allNodes.map { $0.label }` sites at `ExtractionPipeline.swift:86, 121, 415` weren't part of #2's lookup-dedup scope. They build a list for the LLM prompt — different concern. Left alone, even though they technically benefit from the new `labelIndex`. Scope discipline matters.

---

## The "intern translation" technique

When a decision needs sign-off, also explain it in plain language — **no Swift jargon**, no "decode," "throw," "protocol," "extension." Translate the choice into terms anyone could evaluate.

**Why this matters:**

1. **It forces you to confirm you understand the trade-off** (not just the syntax). If you can't explain it in plain English, you don't understand it well enough to recommend a default.
2. **It catches false dichotomies.** When you simplify, sometimes you realize options A and B aren't actually different in any way the user cares about.
3. **It lowers the cost of override.** The user is more likely to push back productively when the choice is framed in their domain (user-visible behavior) rather than yours (code structure).

**The shape:**

- What the code currently does, in everyday terms.
- What goes wrong / what the smell is, in plain language.
- The options, framed by their **user-visible** or **operationally visible** consequence (not the code shape).
- A recommendation with one-line reasoning.

Today's session used this twice:

1. After drafting `2026-05-14_backend-drift-decisions.md` in Swift terms, the user asked for "intern language." The translation surfaced that D2 (UTF8 + JSON decode failure handling) was really "show the user a clear error vs. show them garbled response as if it were the answer." Framed that way, the user overrode my recommendation immediately.

2. For Tier 1 #2's sub-decisions (lookup table, lock-down, silent merge), the intern translation was the primary medium — the doc itself was never written. The chat-message translation was sufficient because the decisions were less interdependent than #1's.

**Rule of thumb:** if you've drafted decisions in code terms and the user asks for plain language, *always* translate before they pick. Don't just answer their question and move on — the translation might change their choice.

---

## Worked example 1 — Tier 1 #1 (AI backend duplication)

**Phase 0 — Pick.** Highest-tier finding with the largest code removal payoff (~300-400 lines projected). Chose first.

**Phase 1 — Analysis.** Read all three backend files end-to-end. Checked `git log -- pdf_app1/.../Backends/` and found the initial commit (`7efee06`) created all three at once. Identified that vendor variation is **real** at the HTTP-transport layer (paths, auth, body shape, response JSON paths) but **synthetic** at the public-method layer (5 methods × 3 = 15 near-identical methods). Discovered Ollama was *not* a 4th file — it's `OpenAIBackend` instantiated with localhost. Surfaced **5 real drifts** hidden inside the duplication:

| Drift | Variant | Likely intent |
|---|---|---|
| D1 | Three different `parseExtractionResponse` error types | Accidental |
| D2 | `parseAnswerResponse` throws vs. swallows UTF8 failures | Accidental |
| D3 | OpenAI lacks `isAvailable` preflight | Intentional (for Ollama) |
| D4 | Claude missing `temperature` (runs at default ~1.0) | Almost certainly accidental |
| D5 | `max_tokens` capped below model ceilings | Vendor-specific intent |

Delivered the analysis in chat (~900 words).

**Phase 2 — Decisions doc.** Wrote `audits/2026-05-14_backend-drift-decisions.md` with five numbered decisions, my recommendation for each, and sign-off checkboxes. User overrode D2 (chose A — throw — over my recommended B — swallow). Updated the doc with `☑ **A** (overrides recommendation)` and captured rationale ("never show raw garbled response as the assistant's answer"). All other recommendations accepted.

**Phase 3 — Reconciliation.** Seven surgical edits across `ClaudeBackend.swift`, `OpenAIBackend.swift`, `GeminiBackend.swift`. No protocol introduced. Files still looked nearly-duplicate, but behaviors were now consistent: Claude at temp 0.1, max_tokens 8192 on Claude/OpenAI, OpenAI's preflight added, all three parsers throw `AIError.decodingError`. Build green.

**Phase 4 — Refactor.** Created `Atlas/AI/Backends/LLMBackend.swift` (124 lines) — protocol + default impls + `LLMResponseParser` enum. Rewrote the three backend files to be 84/91/92 lines each. Net `Backends/` folder: 593 → 391 lines.

**Phase 5 — Commit.** Audit docs + reconciliation+refactor (bundled because the intermediate Phase-3 file shape no longer existed) + backlog sync. Three commits, plus the umbrella audit-docs commit. Pushed to `origin/main`.

**Artifacts:**
- Analysis: in-session chat (not persisted as a separate doc; the decisions doc captured the substance).
- Decisions doc: `audits/2026-05-14_backend-drift-decisions.md`.
- Implementation: commit `058936e`.

---

## Worked example 2 — Tier 1 #2 (label-lookup dedup)

**Phase 0 — Pick.** Second-highest impact, naturally next-after-#1.

**Phase 1 — Analysis.** Counted the call sites (11 across three files). Surveyed how `KnowledgeGraph` is currently structured (`@Observable nonisolated`, `var nodes: [UUID: ConceptNode]`, computed `allNodes`). Noticed `merge(from:)` already bypasses `addNode` (writes directly to `nodes[id]` — pre-existing smell). Reframed the audit's "O(n²) hot path" claim: real value is *dedup* (one place to change the match rule), perf is incidental — string compares are noise next to LLM network calls. Identified three sub-decisions worth surfacing.

**Phase 2 — Decisions (in-chat, no doc).** Three sub-decisions framed in intern language:

- Q1: Just dedup, or dedup + speed up? → User: A (both)
- Q2: Lock down `nodes`/`edges` to `private(set)`? → User: check first, then A if clean
- Q3: Silent merges (no per-node log spam)? → User: B (silent)

Verified Q2 by `rg`-grepping for external writes — zero. Confirmed safe to lock down.

**Phase 3 — Reconciliation.** N/A. There was no drift to reconcile — the smell was pure duplication, not divergent behavior. Skipped straight to Phase 4. Worth noting: **not every finding needs Phase 3.** When the audit catches duplication without drift, you can collapse to refactor.

**Phase 4 — Refactor.** Added `labelIndex: [String: UUID]` + private `insert(_:)` to `KnowledgeGraph`. New public `node(matching:)` for O(1) lookup. Updated `addNode`/`removeNode`/`updateNode`/`clear`/`merge` to keep the index in sync. Made `nodes`/`edges` `private(set)`. Routed `merge(from:)` through silent `insert` (no per-node logs). Replaced 11 lookup call sites with `graph.node(matching:)`. Left the 3 `allNodes.map { $0.label }` sites alone (different concern — building label list for LLM prompt, not lookup).

**Phase 5 — Commit.** One commit (`be9814b`). All four files (`KnowledgeGraph.swift` + 3 call-site files) in one logical seam since they're inseparable from the perspective of "did this refactor land correctly."

**Artifacts:**
- Analysis: in-session chat (~900 words).
- Decisions: in-chat (no doc — three small sub-decisions didn't warrant the doc ceremony).
- Implementation: commit `be9814b`.

---

## Differences between the two examples

Worth calling out:

- **#1 had drift; #2 did not.** #1 needed Phase 2 (decisions doc) and Phase 3 (reconciliation). #2 collapsed Phase 2 into chat and skipped Phase 3 entirely.
- **#1 needed a doc for its decisions; #2 didn't.** Five interdependent drift questions warranted a sign-off artifact. Three small sub-decisions didn't.
- **#1's Phase 3 and Phase 4 collapsed into one commit; #2 was single-commit anyway.** Both for similar reasons — the intermediate file state from one phase didn't survive into the next, so splitting commits would have required `git stash` gymnastics.

The phases adapt. Use the ones you need.

---

## Adapting the pattern

The five phases aren't a checklist — they're a default sequence. Real audit findings have different shapes:

- **Pure duplication, no drift:** Phase 0, 1, 4, 5. Skip 2 and 3.
- **Drift with no duplication** (e.g., one file with internally inconsistent error handling): Phase 0, 1, 2, 3, 5. Skip 4.
- **Single-file structural** (e.g., split `PDFViewerView.swift`): Phase 0, 1, 4, 5. Skip 2 and 3. Maybe split Phase 4 across multiple commits if the file is large enough.
- **Cross-file behavioral change** (e.g., add a new parameter everywhere): Phase 0, 1, 2 (if there are knobs to pick), 4, 5. Skip 3 unless you can stage it as "add new path + switch callers + remove old path" — in which case it's all five.

The shared spine is **Analyze → Decide → Verify → Refactor → Commit**, with verification at every phase boundary.

---

## When to update this doc

Update when:

- A worked example uncovers a phase the current doc doesn't cover.
- An anti-pattern recurs across multiple sessions.
- The commit-message conventions in Atlas change.
- A new tool (e.g., `/ultrareview`) enters the workflow.

Don't update when:

- A single finding doesn't fit the pattern. (That's normal — adapt the phases.)
- A single user override conflicts with the pattern. (Capture it in the decisions doc, not here.)

This doc is the **process baseline**, not a per-finding log.

---

## Pointers

- Survey under review: [`2026-05-14_simplify-survey.md`](./2026-05-14_simplify-survey.md)
- Worked example 1 decisions: [`2026-05-14_backend-drift-decisions.md`](./2026-05-14_backend-drift-decisions.md)
- Earlier audit (issue batching) for comparison: [`2026-05-12_issue-batching.md`](./2026-05-12_issue-batching.md)
- Earlier audit (codebase analysis): [`2026-01-14_23-23-20_codebase-analysis.md`](./2026-01-14_23-23-20_codebase-analysis.md)
- Backlog: `atlas/backlog.md`
- Per-day handoffs: `~/.claude/sessions/atlas/YYYY-MM-DD.md`
