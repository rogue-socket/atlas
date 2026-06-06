# Guided Tour Focusgroup Findings

## Summary
- Date: 2026-05-27
- Feature under test: guided tour for the Atlas knowledge map.
- Focusgroup project: `/private/tmp/atlas-guided-tour-focusgroup`
- Persona backend: Codex agent backend via `FOCUSGROUP_PERSONA_MODE=codex`.
- Judge backend: stub judge via `FOCUSGROUP_JUDGE_MODE=stub`.
- Scope note: this was a focusgroup simulation against a lightweight adapter that modeled the current guided-tour UX. It was not direct UI automation of the macOS app.

The core guided-tour interaction tested well enough to keep hardening: personas could start the tour, see progress and controls, and cause map focus updates. The main product issue is not functional failure; it is confidence. Most personas understood the rough flow but hesitated to say they would return because the affordance, control contract, and jump behavior were not explicit enough.

## Runs

Fresh valid runs:
- `20260527T230304-guided-tour-adversarial-probing`
- `20260527T230505-guided-tour-confused-translating`
- `20260527T230555-guided-tour-distracted-multitasker`
- `20260527T230649-guided-tour-enthusiastic-overshare`
- `20260527T230758-guided-tour-expert-terse`
- `20260527T230852-guided-tour-novice-anxious`
- `20260527T230944-guided-tour-pedantic-formal`
- `20260527T231042-guided-tour-power-user-grumpy`

Follow-up forced-model probe:
- `20260527T233447-guided-tour-expert-terse`

Commands used, omitting failed/interrupted exploratory attempts:

```sh
FOCUSGROUP_PERSONA_MODE=codex FOCUSGROUP_JUDGE_MODE=stub FOCUSGROUP_CODEX_CWD=/Users/yashagrawal/Documents/pdf_projects/atlas python3 -m runner.run --project-dir /private/tmp/atlas-guided-tour-focusgroup --scenario guided-tour-adversarial-probing
```

```sh
FOCUSGROUP_PERSONA_MODE=codex FOCUSGROUP_JUDGE_MODE=stub FOCUSGROUP_CODEX_CWD=/Users/yashagrawal/Documents/pdf_projects/atlas python3 -m runner.run --project-dir /private/tmp/atlas-guided-tour-focusgroup --scenario guided-tour-confused-translating,guided-tour-distracted-multitasker,guided-tour-enthusiastic-overshare,guided-tour-expert-terse,guided-tour-novice-anxious,guided-tour-pedantic-formal,guided-tour-power-user-grumpy
```

```sh
FOCUSGROUP_PERSONA_MODE=codex FOCUSGROUP_JUDGE_MODE=stub FOCUSGROUP_CODEX_MODEL=gpt-5.5 FOCUSGROUP_CODEX_CWD=/Users/yashagrawal/Documents/pdf_projects/atlas python3 -m runner.run --project-dir /private/tmp/atlas-guided-tour-focusgroup --scenario guided-tour-expert-terse
```

## Oracle Results

Common requirements:
- `F-001`: tour can be discovered and started.
- `F-002`: playback state and controls are visible.
- `F-003`: navigation updates map focus.
- `S-001`: no unsafe behavior claim appears.
- `P-001`: interaction completes within the turn budget.
- `I-001`: persona says they would return.

Result pattern:
- `F-002`, `F-003`, `S-001`, and `P-001` passed across the fresh valid runs.
- `I-001` only passed for `novice-anxious`; the other personas answered `maybe`.
- `F-001` failed for `expert-terse`, `pedantic-formal`, and `power-user-grumpy` in the fresh batch because the final state had `tour_started == false` after close/dismiss. Their transcripts show they did start the tour, so this is an oracle design flaw: `F-001` should assert "was started during the run", not "is still active at run end".

## Forced `gpt-5.5` Failure

The first forced `gpt-5.5` focusgroup run failed before producing a valid scenario result. The preserved log is `/tmp/atlas-guided-tour-focusgroup-real-v2.log`. The failure was:

```text
runner.codex_client.CodexError: codex exec failed with exit code 1:
```

There was no stderr text after the colon.

Follow-up probes showed that `gpt-5.5` itself was not the stable problem:
- A direct `codex exec --model gpt-5.5` smoke probe returned `OK`.
- A direct `runner.codex_client.complete_json(...)` schema probe with `FOCUSGROUP_CODEX_MODEL=gpt-5.5` returned `{'text': 'OK', 'done': False}`.
- A full forced-model focusgroup scenario later completed successfully: `20260527T233447-guided-tour-expert-terse`.

Conclusion: treat the original forced-model failure as a transient nested `codex exec` failure, not evidence that `gpt-5.5` is unavailable or misconfigured.

There is still a tooling bug worth fixing in the focusgroup runner. `runner/codex_client.py` raises with only `proc.stderr.strip()` on non-zero exit. If Codex emits diagnostic details through JSON stdout, or exits with no stderr, the runner loses the useful failure context. The wrapper should include a bounded tail of stdout, stderr, exit code, model, sandbox, cwd, and whether an output schema was used.

## Persona Findings

### Adversarial Probing
- Outcome: partial, would return maybe, trust unsure.
- Reaction: ambiguity around invalid jumps was the main trust problem.
- Finding: the system should never silently clamp, ignore, or reinterpret nonexistent jump requests. The tester wanted valid stops, requested target, outcome, and current stop after the attempt.
- Product interpretation: the real UI list only exposes valid choices, but any future keyboard/deep-link/jump affordance needs explicit invalid-target handling.

### Confused Translating
- Outcome: partial, would return maybe, trust mostly.
- Reaction: "node", "right level", "scan", "selected", and "core concepts" were unclear. The tester confused the list/jump control with a translation or chapter-list feature.
- Finding: the start affordance and card need plain wording: this is a walkthrough of the PDF knowledge map, not a translation or summary tool.

### Distracted Multitasker
- Outcome: gave up, would return maybe, trust unsure.
- Reaction: wanted a fast gist and did not want to track four small controls.
- Finding: a separate quick-summary or "2-minute gist" mode may be useful, but it is a different feature from guided tour hardening.
- Product interpretation: do not fold this into the current guided-tour pass unless the scope changes.

### Enthusiastic Overshare
- Outcome: partial, would return maybe, trust mostly.
- Reaction: appreciated read-only reassurance, but got frustrated when the SUT repeated safety boundaries instead of advancing.
- Finding: when moving to the next stop, keep orientation cues visible: stop name, progress number, and what the map centered on.

### Expert Terse
- Outcome: partial, would return maybe, trust no.
- Reaction: could start, advance, jump, and close, but wanted exact state observables.
- Finding: the card should make current stop, progress, centered/highlighted node, and disabled/enabled controls obvious. Direct UI does not need to expose a debug state object, but it should provide these observables without interpretation.

### Novice Anxious
- Outcome: partial, would return yes, trust mostly.
- Reaction: most positive persona. Read-only reassurance made the feature feel safe.
- Finding: add a visible label such as "Read-only guided tour" near the start button or in the card.

### Pedantic Formal
- Outcome: partial, would return maybe, trust unsure.
- Reaction: wanted a precise control contract: previous, next, list/jump, close, replay, enabled states, progress effects, persistence after close, and treatment of tour-selected nodes.
- Finding: tooltips and disabled control states need to be unambiguous. Close behavior should be explicit: the card closes and the map remains focused where the tour left it.

### Power User Grumpy
- Outcome: yes, would return maybe, trust mostly.
- Reaction: jump-to-stop and Esc dismissal were useful and fast enough to beat manual map dragging for known targets.
- Finding: narration that assumes linear traversal breaks trust. Jumped-to stops must use context-neutral narration, or transition text must be generated dynamically only for actual previous/next navigation.

## Recommended Fix Queue

1. Make the start/card affordance explicit.
   - Add visible text or an accessible label: "Guided Tour" and "Read-only guided tour".
   - Keep the graduation-cap icon, but do not rely on the icon alone.

2. Remove linear-assumption narration from generated stop text.
   - Current generated copy can say things like "Now that you've explored Chapter Structure" even if the user jumped directly to "Core Concepts".
   - Prefer self-contained stop narration.
   - If transition copy is desired, add it dynamically only when the user actually advances sequentially.

3. Add a compact centered-node status in the playback card.
   - Example shape: `Centered on: Core Concepts`.
   - This addresses expert/pedantic requests without turning the UI into a debug panel.

4. Tighten control semantics.
   - Previous disabled on the first stop.
   - Next disabled or replaced by replay on the last stop.
   - List/jump shows all valid stops by number and label.
   - Close dismisses only the card and preserves the current map focus.
   - Tooltips should name controls plainly.

5. Fix the focusgroup oracle and Codex error capture.
   - Change `F-001` from final-state active check to "tour was started at least once".
   - On `codex exec` failure, include bounded stdout/stderr tails and command metadata.

6. Defer the "2-minute gist" request.
   - It is a valid product idea, but it should be tracked separately from guided-tour correctness.

## Implementation Follow-up

Status as of 2026-05-28:
- Atlas now exposes the guided tour through a labeled graduation-cap toolbar button when an AI backend is configured and the graph has enough valid topics.
- The playback card now shows "Guided Tour", "Read-only", progress, `Centered on: ...`, previous/next/list controls, Replay on the last stop, and a close button that preserves map focus.
- Generated stop narration is self-contained so jump-to-stop does not inherit a false linear transition.
- The local focusgroup adapter was updated to track "tour started at least once" for `F-001`.
- The focusgroup runner now includes bounded stdout/stderr tails plus Codex model, sandbox, cwd, and schema metadata when `codex exec` fails.

Verification:
- Focused XCTest: `TourPlayerTests` plus `MapInteractionTests/testFocusOnNodeCentersNodeAndSelectsIt` passed.
- Manual Atlas smoke with `nexapay_company_and_workforce.pdf` passed using the Codex Agent backend: generate tour, advance, open list, jump to stop 4, confirm Replay/disabled Next, and close while preserving map focus.
- Claude Subscription was not usable for this smoke because the org disabled Claude Code subscription access; this is an environment/auth blocker, not a guided-tour regression.

## Cleanup Notes

The temporary focusgroup project and run artifacts are disposable after this report:
- `/private/tmp/atlas-guided-tour-focusgroup`
- `/tmp/atlas-guided-tour-focusgroup-*.log`

Do not delete them before checking whether another follow-up needs exact transcripts.
