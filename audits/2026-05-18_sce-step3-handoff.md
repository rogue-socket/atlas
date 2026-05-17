# SCE Step 3 — Research Handoff (2026-05-18)

> **Branch:** `feature/sce-cross-doc` at `e763c8a` (origin in sync). **WORKING TREE DIRTY — 6 files modified, 629 insertions, NOT committed.** See [§ Uncommitted state](#uncommitted-state) for what to do with it.
>
> **What this doc is:** complete handoff for a new agent picking up SCE research. Captures (a) what we just shipped (call it "v5"), (b) every dead-end we hit so you don't retry them, (c) the LLM behavior patterns we characterized, (d) what to try next.
>
> **Companion doc:** `audits/2026-05-16_sce-step1-findings.md` is the prior baseline doc — read it for original SCE design intent. This doc supersedes its "what's open for next session" section.

---

## TL;DR

We pushed SCE node-merging research from the 2026-05-16 baseline (2 cross-doc shared nodes) to a working pipeline that produces **54 cross-doc structural signals** (8 merges + 46 typed cross-doc edges) per 4-doc vitacare extraction. The key unlocks:

1. **`prior_label_match` schema field** — LLM flags matches, parser does the rename. Working since v2 (2026-05-17 AM).
2. **`match_kind` taxonomy with typed cross-doc edges** — splits "same thing" from related-but-different relationships (instance_of / attribute_of / process_for). Failed on gemini-2.5-flash (LLM never used it), succeeded on **gemini-3.1-pro-preview** (46 typed edges produced).
3. **Direction rule in prompt** — cuts attributeOf direction errors from ~30% → ~15%.
4. **Concept-only filter on edge-proposal Step 6** — eliminated JSON-truncation failures on Pro at >200-node graphs.

What did NOT work: Gemini's `responseSchema` enum constraint hits a "too many states for serving" cap at vitacare scale (~70 prior labels with normal lengths); structured-output mode caused 88k-char verbose responses on docs 3+4 (truncated → unparseable).

Total spend across this research arc: **~$3-4** in API calls over ~6 runs.

---

## Uncommitted state

Six files are modified on `feature/sce-cross-doc` and **not committed**:

```
M pdf_app1/pdf_app1/Atlas/AI/AtlasModelProtocol.swift     +28 lines
M pdf_app1/pdf_app1/Atlas/AI/Backends/GeminiBackend.swift +135 lines
M pdf_app1/pdf_app1/Atlas/AI/ExtractionPipeline.swift     +113 lines
M pdf_app1/pdf_app1/Atlas/AI/PromptTemplates.swift        +102 lines
M pdf_app1/pdf_app1/Atlas/Models/ConceptTypes.swift       +14 lines
M pdf_app1/pdf_app1Tests/SCETests.swift                   +265 lines (test additions)
```

These collectively implement v5 (the current "best" pipeline). All 24 SCETests pass. Build green. The live extraction (`--headless-extract`) produces the 54-cross-doc-signal result described above.

**Recommended commit split (per the morning's "revertability-first" pattern from `~/.claude/sessions/atlas/2026-05-17.md`):**

1. `EdgeType: add instanceOf/attributeOf/processFor cases` — ConceptTypes.swift
2. `AtlasModelProtocol: add priorLabelMatch + matchKind fields to RawConcept; priorDocsLabelMap to ExtractionContext` — AtlasModelProtocol.swift
3. `PromptTemplates: prior_label_match flag + match_kind taxonomy + direction rule` — PromptTemplates.swift
4. `GeminiBackend: switch default to gemini-3.1-pro-preview; schema-aware extractConcepts override with empirical char-budget fallback` — GeminiBackend.swift
5. `ExtractionPipeline: Step 5 match-action branching (rename vs typed-edge); Step 6 filter to concept-level for edge proposal` — ExtractionPipeline.swift
6. `SCETests: 14 tests for prior_label_match decode, resolveMatchAction, schema builder` — SCETests.swift

Each commit compiles independently (verified by ordering: deps land before consumers). Tests pass at HEAD.

**If you don't want to commit yet**, do NOT switch branches without stashing — the uncommitted state would follow you and conflict with `main`'s cleanup work.

---

## Current model + pipeline shape (v5)

**Model:** `gemini-3.1-pro-preview` (changed from `gemini-2.5-flash` default in `GeminiBackend.swift:30`).

**Per concept-extraction call:**

1. Pipeline builds `priorDocsHeader` (natural-language bulleted list of prior-doc nodes) + `priorDocsLabelMap` (lowercased→canonical map for parser-side validation).
2. Prompt includes the prior-docs block with `prior_label_match` + `match_kind` instructions (see `PromptTemplates.swift:23-55`).
3. **No `responseSchema`** is sent on this run — we tried it (v3.1) and it caused truncation failures. The override in `GeminiBackend.extractConcepts` builds the schema dict but passes `nil` to `transport(_:responseSchema:)` (see `GeminiBackend.swift:128-131`). To re-enable later: change `responseSchema: nil` to `responseSchema: schema`. The `buildExtractionResponseSchema` helper is preserved with a char-budget fallback (so partial enum is possible if Pro handles it better than Flash did).
4. LLM returns concepts/entities with optional `prior_label_match` + `match_kind`.
5. Parser (`ExtractionPipeline.swift:393-410, 503-518`) calls `PromptTemplates.resolveMatchAction(...)` which returns one of `.noMatch / .mergeByRename / .typedEdge(canonical, EdgeType)`.
6. Branching in Step 5: `.mergeByRename` → existing rename path; `.typedEdge` → keep new node, add typed edge to prior canonical; `.noMatch` → no SCE action.
7. Step 6 (edge proposal) filters to `level == .concept` nodes only — prevents the JSON-truncation issue we saw with all-nodes lists.

**Per-batch telemetry logged at `[SCE]` log lines** (subsystem `com.atlas.pdf`, category `pipeline`):
- `match_summary: claims=N renames=N merges=N typed_edges=N` per batch
- `concept rename: "X" → "Y" via same_entity`
- `entity typed-edge: "X" -[edgeType]→ "Y"`

Pull via: `log show --predicate 'subsystem == "com.atlas.pdf"' --info --last 30m | grep '\[SCE\]'`

---

## Headline metrics across all runs this arc

| Run | Date | Model | Schema | Match-kind | Cross-doc shared | Typed edges | Total signal | Notes |
|---|---|---|---|---|---|---|---|---|
| Baseline (pre-SCE) | 2026-05-16 | Flash 2.5 | n/a | n/a | 2 | 0 | 2 | `/tmp/atlas_graphs_baseline_pre_sce_2026-05-16/` |
| Post-fix SCE Run 2 | 2026-05-16 | Flash 2.5 | none | none | 2 | 0 | 2 | findings doc baseline; only edges lifted (4→137) |
| v1 (Option D) | 2026-05-17 | Flash 2.5 | none | none | **9** | 0 | 9 | first prior_label_match run; 13 renames, 11 invalid claims |
| v2 (Option D + anti-patterns) | 2026-05-17 | Flash 2.5 | none | none | **15** | 0 | 15 | vitacare-specific anti-patterns in prompt; 80-87% precision |
| v3 (schema enum) | 2026-05-17 | Flash 2.5 | enum @ 74 labels | n/a | n/a | n/a | n/a | HTTP 400: "too many states for serving" — docs 2+3+4 failed entirely |
| v3.1 (schema soft fallback + match_kind) | 2026-05-17 | Flash 2.5 | unrestricted-string | first attempt | 3 | 0 | 3 | structured-output mode caused 48k/88k-char verbose truncation on docs 3+4; **LLM ignored match_kind** entirely (4/4 same_entity) |
| **v4 (Pro 3.1, no schema)** | **2026-05-18** | **Pro 3.1** | **none** | **enabled** | **8** | **18** | **26** | **First time match_kind actually used (was zero on Flash)**; 3 edge-proposal JSON failures |
| **v5 (Pro + edge filter + direction rule)** | **2026-05-18** | **Pro 3.1** | **none** | **enabled** | **8** | **46** | **54** | **Current best.** Zero errors. 21 instanceOf + 20 attributeOf + 5 processFor edges. |

**Three notable jumps:**
- Baseline → v2: cross-doc shared 2 → 15. Mechanism: prior_label_match + parser-side rename + anti-pattern prompt.
- v2 → v4: cross-doc signal 15 → 26. Mechanism: model upgrade Flash → Pro unlocks match_kind taxonomy.
- v4 → v5: cross-doc signal 26 → 54. Mechanism: direction rule + edge-proposal filter.

---

## Methods that work

### Method 1: `prior_label_match` field + parser-side validation

**What:** LLM emits an optional `prior_label_match: "<exact prior label>"` on any concept/entity. Parser checks the claim against a case-insensitive map of all prior-doc node labels; if valid, rewrites the new node's label to the canonical prior label, which triggers the existing `KnowledgeGraph.node(matching:)` exact-match merge path. Invalid claims are silently dropped (LLM hallucinates ~50-65% of the time but it costs nothing).

**Code:**
- Field decl: `AtlasModelProtocol.swift:12-31` (RawConcept + CodingKeys)
- Map builder: `PromptTemplates.swift:138-157` (`priorDocsLabelMap`)
- Parser helper: `PromptTemplates.swift:173-216` (`SCEMatchAction` enum + `resolveMatchAction`)
- Pipeline integration: `ExtractionPipeline.swift:393-447, 503-562`
- Tests: `SCETests.swift:test_resolveMatchAction_*` (5 tests covering valid/invalid/edge cases)

**Status:** Stable since v2. Works on Flash and Pro. Hallucination rate is high but harmless (parser is the safety net).

### Method 2: `match_kind` taxonomy with typed cross-doc edges

**What:** Alongside `prior_label_match`, LLM also emits `match_kind` ∈ {`same_entity`, `instance_of`, `attribute_of`, `process_for`}. Parser branches:
- `same_entity` → rename + merge (Method 1 path)
- `instance_of` / `attribute_of` / `process_for` → keep new node, add typed cross-doc edge from new → canonical prior

This converts what used to be "precision losses" (LLM treating an attribute/process/instance as if it were the parent thing) into structured graph signal.

**Code:**
- Edge types: `ConceptTypes.swift:95-100` (3 new EdgeType cases) + displayName/color cases
- Field decl: `AtlasModelProtocol.swift:25-31` (matchKind on RawConcept)
- Action enum: `PromptTemplates.swift:178-184` (SCEMatchAction)
- Resolver: `PromptTemplates.swift:186-216` (resolveMatchAction)
- Pipeline branching: `ExtractionPipeline.swift:397-410, 426-447, 507-518, 533-545`
- Tests: `SCETests.swift:test_resolveMatchAction_typedKinds_yieldEdges`, etc.

**Status:** Only works on Pro 3.1. **Flash 2.5 completely ignored the typed kinds** in v3.1 (4/4 claims were same_entity even when attribute_of was obviously correct). Pro 3.1 uses all four kinds meaningfully — 46 typed edges in v5 with ~61% overall precision (instanceOf ~62%, attributeOf ~75%, processFor ~60%).

### Method 3: Direction rule in prompt

**What:** Added a "DIRECTION RULE (strict)" clause to the prior-docs block. States that for any match_kind other than `same_entity`, the CURRENT item must be the more specific/narrower thing; if reversed, OMIT both fields. Includes abstract REJECT-direction examples for each kind.

**Code:** `PromptTemplates.swift:33-39`

**Status:** Halved direction errors on attributeOf (~30% → ~15%). Some still slip through (e.g. `Most clinic-based staff work in-person → in-person` is still backwards). Worth iterating if precision is the bottleneck.

### Method 4: Concept-only filter on edge proposal

**What:** Step 6 (`proposeEdges`) previously passed all `graph.allNodes.map { $0.label }` to the LLM — by doc 4 on Pro that's 200+ labels causing 88k-char responses → JSON truncation → parse failure. Filter changes it to `.filter { $0.level == .concept }`. Reduces input list to ~30-50 concept labels, eliminates the truncation.

**Code:** `ExtractionPipeline.swift:572-578`

**Status:** Eliminated all 3 edge-proposal failures from v4 in the v5 run. Cleaner architecturally too (the prompt was already framed around concepts, not entities).

---

## Methods that DID NOT work (don't retry without redesign)

### Failed: `responseSchema` with enum constraint on `prior_label_match`

**What we tried:** Pass Gemini's `generationConfig.responseSchema` with a JSON schema that constrained `prior_label_match` to the actual prior-doc label list (enum). Would make hallucinations API-level-impossible.

**Why it failed:** Gemini rejects with HTTP 400: `"The specified schema produces a constraint that has too many states for serving. Typical causes... very long property or enum names, schemas with long array length limits (especially when nested)"`. Empirical limit on gemini-2.5-flash: ~1500 chars of enum content across the nested-duplicated concept+entity schemas (~60 labels with normal lengths). Vitacare hits this around doc 2.

**Probe details:** I directly tested with curl. 5/20/50/60-label enums worked; 80-label enum with normal-length labels failed. With real vitacare labels (some 50-115 chars long, some with embedded newlines), the limit hit at 74 labels.

**What I left in the codebase:** `GeminiBackend.buildExtractionResponseSchema` is preserved with a char-budget fallback (drops the enum when total chars > 1500, falls back to unrestricted-string). But it's currently NOT called (extractConcepts override passes `responseSchema: nil`). To re-enable, see `GeminiBackend.swift:128-131`. **Note:** Gemini 3-series claims fuller JSON Schema support — may not have the same limits. Untested in this arc.

### Failed: Structured-output mode (any schema) at scale

**What we tried:** Even when the enum was dropped (schema fell back to unrestricted-string `prior_label_match`), keeping the rest of the responseSchema (typed fields, match_kind enum) was still active.

**Why it failed:** Gemini's structured-output mode induces verbose generation when prior-context is large. v3.1 doc 3 batch 1: 48,553 chars response. Doc 4 batch 1: 88,293 chars. Both got truncated (output token cutoff) producing unparseable JSON. JSON repair couldn't recover them.

**What this told us:** "schema=anything" + "prior-context=large" → Gemini gets verbose. The fix was to drop the schema entirely (v4+). Re-trying with Pro 3.1 + schema is the most interesting open follow-up — Pro 3.1 may not have this verbosity issue (untested).

### Failed: Vitacare-specific anti-pattern examples in the prompt

**What we tried (v2):** Added 3-4 vitacare-specific anti-pattern examples like "Asynchronous Messages (the messaging service). Current text 'Message response time: within 6 business hours' → this is an SLA ATTRIBUTE..."

**Why it "worked but was wrong":** v2 with these examples got 15 cross-doc nodes at ~80% precision — the best Flash result of the arc. But user veto: **"Under no circumstance should you hardcode"** (2026-05-17 PM). Vitacare-specific examples don't generalize beyond this corpus.

**What we did instead:** Replaced with abstract pattern templates ("prior `<Entity X>` ↔ current `<a time / count / SLA / metric / policy / value of X>`"). v3+ uses these. They work less well than the hardcoded examples but generalize. Pro 3.1 partially recovers what we lost by being smarter about the abstract patterns.

### Failed: "STRICT VALUE RULE" prompt wording for hallucination reduction

**What we tried (v2):** Added "`prior_label_match` must be COPIED character-for-character from exactly one of the bullet labels listed above..." — strong wording.

**Why it failed:** Hallucination rate stayed at 46-65% on Flash, ~62-74% on Pro. The LLM doesn't internalize "must be in this exact list" without an external forcing function (which would be the enum we couldn't make work at scale). Hallucinations are harmless because the parser drops them, but they represent wasted LLM attention.

---

## LLM behavior patterns observed

These patterns were characterized by reading the actual extracted nodes in `/tmp/atlas_graphs_baseline_pre_sce_2026-05-16/` (pre-SCE baseline) AND the v5 graph. They generalize to any corpus.

**P1 — Suffix stripping.** Prior label "Company Identity & Founding" → LLM produces "Company Identity" in later docs. Drops parenthetical/suffix qualifiers because they're not in the current doc's framing. **Fix:** `prior_label_match` with `same_entity` (Method 1). Works on both Flash and Pro.

**P2 — Aspect rotation.** Prior "External Laboratory Services" ↔ current "External Service Partners" — same vendors (Labcorp, Quest) but framed through different organizational lenses. Label-copy can't fix this; the labels are genuinely different framings. **Not fixable by SCE; ETR territory.**

**P3 — Role-vs-name asymmetry.** Rubric pair 2: ORG names Dr. Helena Vargas; CMP describes her role as "Program Ownership". Different granularity. **Not fixable by either SCE or ETR cleanly** — would need an entity-resolution layer with role↔name awareness.

**P4 — Catalog-vs-leaf.** 6 different "Telehealth-*" labels across 3 docs, none exact. These are usually genuinely different facets (modalities, limitations, hours, footprint, services) — should NOT merge. Pro's match_kind correctly routes some to typed edges (e.g. `Telehealth: 7:00 AM - 11:00 PM` → attributeOf → `telehealth`).

**P5 — Cross-level.** Rubric expects concept↔entity merges (e.g. `Annual Wellness Visit` entity ↔ `Appointment Scheduling Timelines` concept). Prompt notes "cross-level allowed" but LLM rarely operationalizes it. v5's typed edges DO bridge concept↔entity sometimes (`Annual wellness visit: scheduled within 14 days` attributeOf `Annual Wellness Visit`).

**P6 (newly observed in v4, partially fixed in v5) — Direction confusion.** When choosing match_kind, LLM sometimes treats the broader thing as the more-specific one. v4 had ~30% direction errors on attributeOf; v5's direction rule cut to ~15%.

**P7 (newly observed in v5) — Forced relationships.** LLM occasionally tags a relationship via match_kind when none exists (e.g. `Each clinic includes 8-18 exam rooms... → attributeOf → Routine labs are performed on-site at every clinic` — neither is an attribute of the other). Could be addressed by adding a "if uncertain, OMIT" clause in the prompt.

---

## Cross-doc shared nodes (v5) — audit

8 nodes appear in ≥2 vitacare docs:

| Label | Level | Docs | Quality |
|---|---|---|---|
| `Advanced imaging (MRI, CT, mammography)` | entity | clinical+patient | ✓ rename from "advanced imaging" |
| `Clinic hours are 7:30 AM - 7:00 PM ...` | entity | organization+patient | ✓ rename from "Standard clinic hours: ..." |
| `Group programs` | entity | clinical+patient | ✓ exact-label match |
| `Regional Medical Director` | entity | organization+patient | ✓ exact-label match (also a typed-edge self-ref to investigate) |
| `Send-out labs are processed by Labcorp or Quest Diagnostics` | entity | clinical+patient | ✓ rename from "Labcorp and Quest Diagnostics" |
| `Virtual Care Platform` | chapter | clinical+organization | ✓ chapter-level merge |
| `additional access controls` | entity | clinical+compliance | ✓ likely exact-label |
| `web portal` | entity | clinical+patient | ✓ rename from "Patient portal: vitacare.com" |

All 8 look like real cross-doc same-thing matches.

## Typed edges (v5) — full audit

### instanceOf (21 edges) — ~62% precision
Good: `18-session course of CBT → Brief evidence-based therapy`, `diabetes program → Chronic Condition Programs`, `In-app messaging → asynchronous messaging`, `Group medical visits → Group programs`, `medication-assisted treatment → Substance use disorder treatment`, `Substance Use Disorder Records Protection → Behavioral Health Records Privacy` (cross-doc rubric pair!), `point-of-care lab capabilities → on-site labs and basic imaging`, `behavioral health support → Behavioral Health Services`, `care coordinator manages referral → Care coordinators and patient navigators: 96`, others.

Wrong: `Free VitaCare primary care for employees → primary care` (benefit not instance); `Transitioned to VitaCare where all three functions... → Behavioral Health Services` (narrative not instance); `Substance Use Disorder Records → Specialty Care Services` (wrong category); `Regional Medical Director → Regional Medical Director` (self-reference, should've been same_entity merge).

### attributeOf (20 edges) — ~75% precision
Good: `Acute primary care concern: same-day or next-day → primary care`, `Annual wellness visit: scheduled within 14 days → Annual Wellness Visit`, `Lab result release: within 24 hours → Lab Result Communication`, `Telehealth: 7:00 AM - 11:00 PM → telehealth`, `Message response: within 6 hours → asynchronous messaging`, `VitaCare Direct membership as employee benefit → VitaCare Direct Membership`, others.

Wrong: `Most clinic-based staff work in-person 4-5 days per week → in-person` (direction wrong — in-person is the attribute of the staff, not vice versa). The direction rule reduced but didn't eliminate this class.

### processFor (5 edges) — ~60% precision
Good: `Provider enrollment → Accepted Insurance Networks`, `Billing, payment plans, and insurance management → Patient Pricing and Insurance`, `Closed-loop result management → Lab Result Communication`.

Wrong: `Secure messaging with the care team → asynchronous messaging` (should've been same_entity merge); `Care coordinator handles prior authorization → referral and prior auth handled by VitaCare care coordinators` (these are the same description twice).

---

## Open issues

1. **Direction errors persist** (~15% on attributeOf despite the direction rule). The "forced relationships" pattern P7 is a related issue. Worth one more prompt iteration with a stronger "if uncertain, OMIT" clause.

2. **Self-reference typed edges** — `Regional Medical Director → Regional Medical Director` (instanceOf to itself). Either the parser should detect and reject self-edges, or the prompt should warn against it.

3. **Hallucination rate ~62-74%** — harmless but represents wasted LLM attention. **Re-test responseSchema enum approach on Pro 3.1** — Gemini 3-series has fuller JSON Schema support per docs and may not hit the "too many states" cap. If it works, hallucinations drop to 0%.

4. **Pro 3.1 cost is ~5-7× Flash 2.5.** Each full vitacare run is ~$1-1.50 on Pro vs $0.20 on Flash. Production runs may want a Flash-fallback for projects where typed-edge richness doesn't justify the cost.

5. **Pro 3.1 occasionally produces malformed edge-proposal JSON** (3 failures in v4, 0 in v5 after the concept-only filter — but the failure mode could recur on bigger corpora). Worth instrumenting Gemini's `finishReason` to detect MAX_TOKENS truncation early.

6. **`match_kind` taxonomy may need expansion.** Currently 4 kinds (same_entity + 3 typed). Possibly missing: `contradicts` (X says X-policy, prior says ¬X-policy), `predecessor_of` (temporal), `aggregate_of` (sum-of-many-instances). Add only if real failure modes emerge.

7. **Rubric scoring not yet redone for v5.** The morning's PRD rubric (40 pairs) was scored against Flash-v2-era extraction. v5 produces different labels (typed edges where v2 had merges); needs rubric re-grading. Lab Result Communication, Annual Wellness Visit attributeOf, and SUD Records Protection instanceOf are plausibly rubric hits.

---

## What to try next (ranked)

1. **Commit the 6 uncommitted files** as 5-6 surgical commits per the recommended split above. Then merge `main` into the branch to pick up the morning's data-loss fix + Locate UX + project-graph cleanup (10 commits behind).

2. **Re-score the 40-pair rubric against v5's graph.** The typed edges may capture multiple rubric pairs as typed relationships rather than merges. Re-derive precision/recall under that broader definition of "captured."

3. **Re-enable `responseSchema` on Pro 3.1.** Single-line change in `GeminiBackend.swift:128-131` (`responseSchema: nil` → `responseSchema: schema`). Pro's fuller JSON Schema support may handle the constraint-state budget better than Flash did. If it works, hallucinations vanish AND we get free typed-kind discipline. One run, ~$1.50.

4. **Add P7 "if uncertain, OMIT" clause to the prompt** — small text edit, free to test in next run.

5. **Add a self-edge filter** in the parser (`ExtractionPipeline.swift` typed-edge creation paths) — reject when `sourceNodeID == priorNode.id`. Two-line change.

6. **Compare v5 on a SECOND corpus** (non-vitacare) to validate generalization. Current findings are vitacare-only. The nexapay sample PDFs in the baseline snapshot are an obvious second corpus.

7. **Then revisit SCE+ETR hybrid** (the option you held off in 2026-05-18 conversation). With v5's typed-edge channel + ETR's embedding-based semantic merging, the combined system covers all 5 LLM failure patterns. The SCE/ETR division of labor decision (#11 in PRD) becomes "both ship, doing complementary jobs" not "winner picks all."

---

## Code map (with line numbers — verify before editing)

```
pdf_app1/pdf_app1/
├── Atlas/AI/
│   ├── AtlasModelProtocol.swift
│   │   ├── L10-31    RawConcept + priorLabelMatch + matchKind + CodingKeys
│   │   └── L41-71    ExtractionContext + priorDocsLabelMap field
│   ├── PromptTemplates.swift
│   │   ├── L14-134   conceptExtraction() — main prompt builder
│   │   ├── L23-55    Prior-docs block + match_kind taxonomy + direction rule
│   │   ├── L138-157  priorDocsLabelMap() — graph → label map helper
│   │   ├── L161-171  resolveEffectiveLabel() — legacy Method 1 helper (kept for backward-compat tests)
│   │   ├── L178-216  SCEMatchAction enum + resolveMatchAction()
│   │   └── L221-260  cumulativeStateHeader() — natural-language header for the prompt
│   ├── ExtractionPipeline.swift
│   │   ├── L111-125  priorDocsHeader + priorDocsLabelMap built once per doc
│   │   ├── L152-167  processBatch call with header + label-map plumbing
│   │   ├── L328-339  ExtractionContext construction with priorDocsLabelMap
│   │   ├── L361-372  Step 5 telemetry counters
│   │   ├── L393-410  Concept match-action branching + rename
│   │   ├── L426-447  Concept typed-edge creation
│   │   ├── L503-518  Entity match-action branching + rename
│   │   ├── L533-545  Entity typed-edge creation
│   │   ├── L565-567  Per-batch [SCE] match_summary log line
│   │   └── L572-578  Step 6 concept-only filter for edge proposal
│   └── Backends/
│       ├── GeminiBackend.swift
│       │   ├── L30        Default model = "gemini-3.1-pro-preview"
│       │   ├── L39-67     transport() — schema-aware via overload
│       │   ├── L114-131   extractConcepts override (currently passes responseSchema: nil)
│       │   └── L143-211   buildExtractionResponseSchema() with char-budget fallback
│       └── LLMBackend.swift (unchanged)
├── Atlas/Models/
│   └── ConceptTypes.swift
│       └── L95-100   EdgeType .instanceOf, .attributeOf, .processFor + displayName/color cases
└── pdf_app1Tests/
    └── SCETests.swift
        ├── L150-165  test_priorDocsLabelMap_excludesCurrentDocNodes_andLowercasesKeys
        ├── L167-217  test_resolveMatchAction_* (5 tests)
        ├── L219-273  test_buildExtractionResponseSchema_* (4 tests)
        └── L275-310  test_rawConcept_decodes* (3 tests)
```

---

## How to reproduce a run

**Prereqs:**
- Dev key at `~/Library/Containers/rogues.pdf-app1/Data/atlas-dev-keys.json` containing `{"gemini": "<key>"}`
- `test_proj` project exists in ProjectsManager state with 4 vitacare PDFs
- Build current branch: `cd atlas/pdf_app1 && xcodebuild -project pdf_app1.xcodeproj -scheme pdf_app1 -configuration Debug build`

**Wipe + run:**

```bash
# Snapshot prior state for comparison
cp ~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs/project_*.json /tmp/atlas_sce_prior.json

# Wipe per-doc + project graph (keep embeddings + ETR audit sidecars)
GRAPHS_DIR=~/Library/Containers/rogues.pdf-app1/Data/Library/Application\ Support/Atlas/graphs
ls "$GRAPHS_DIR" | grep -E '^project_|^[0-9a-f]{16}\.json$' | while read f; do rm "$GRAPHS_DIR/$f"; done

# Launch headless extraction (background)
~/Library/Developer/Xcode/DerivedData/pdf_app1-giytzhghgxnvaderrgxenmypwjxy/Build/Products/Debug/pdf_app1.app/Contents/MacOS/pdf_app1 \
  --headless-extract --project test_proj --mode fast &
RUNPID=$!

# Wait for completion (~14-18 min on Pro 3.1)
until ! pgrep -f "pdf_app1.*headless-extract" > /dev/null; do sleep 60; done
echo "done"
```

**Pull SCE telemetry:**

```bash
log show --predicate 'subsystem == "com.atlas.pdf"' --info --last 30m | grep '\[SCE\]'
```

**Analyze the result:**

```python
import json, os
path = '~/Library/Containers/rogues.pdf-app1/Data/Library/Application Support/Atlas/graphs/project_*.json'
# (use the actual project_<UUID>.json file)
g = json.load(open(path))
nodes = list(g['nodes'].values()) if isinstance(g['nodes'], dict) else g['nodes']
edges = list(g['edges'].values()) if isinstance(g['edges'], dict) else g['edges']

# Cross-doc shared
cross_doc = [
    (n['label'], n.get('level',''), sorted({
        os.path.basename(a['documentURL']).replace('vitacare_','').replace('.pdf','').split('_')[0]
        for a in n.get('sourceAnchors', []) if 'vitacare' in a.get('documentURL','')
    }))
    for n in nodes
    if len({a['documentURL'] for a in n.get('sourceAnchors', []) if 'vitacare' in a.get('documentURL','')}) >= 2
]

# Typed edges
for nt in ['instanceOf', 'attributeOf', 'processFor']:
    matching = [e for e in edges if e.get('type') == nt]
    print(f'{nt}: {len(matching)}')
```

---

## Cost tracking

| Run | Approx cost |
|---|---|
| v1 (Flash) | ~$0.20 |
| v2 (Flash) | ~$0.20 |
| v3 (Flash, schema fail) | ~$0.05 (failed early) |
| v3.1 (Flash, schema fallback) | ~$0.15 (partial) |
| v4 (Pro 3.1) | ~$1.50 |
| v5 (Pro 3.1) | ~$1.30 |
| Curl probes | ~$0.01 |
| **Total this arc** | **~$3.40** |

Pro 3.1 pricing: $2/M input + $12/M output (<200k tokens). Per vitacare run ~36k input + ~30k output ≈ $0.072 + $0.36 ≈ $0.43 — but Pro is a "thinking" model and burns extra reasoning tokens (44/55 thoughts on a trivial probe), driving real cost 2-3× higher to ~$1-1.50.

**For follow-up cost planning:** budget ~$2/run on Pro for safety margin. Flash runs are still ~$0.20 if testing flag mechanics without needing typed-edge taxonomy.

---

## Pointers to relevant prior docs

- `audits/2026-05-16_sce-step1-findings.md` — original SCE design, baseline numbers, GraphMergeEngine-is-dormant correction, the foundational "edges yes, nodes no" finding
- `audits/2026-05-16_etr-step1-status.md` (on `feature/etr-cross-doc`) — ETR design context (for the eventual hybrid)
- `audits/2026-05-16_etr-live-verification.md` — ETR threshold sweep + rubric v2 results (the parallel work)
- `prds/2026-05-15_4-level-knowledge-graph.md` §"Quality Rubric v2" — the 40-pair scoring rubric
- `~/.claude/sessions/atlas/2026-05-17.md` — yesterday's session log with the morning's data-loss fix + project-graph cleanup commits that need merging in
- `~/.claude/sessions/atlas/2026-05-18.md` — today's session log (this work)

---

## One paragraph for a new agent's `/start`

You're picking up SCE research on `feature/sce-cross-doc`. The branch has 6 uncommitted files implementing v5 — the working tree builds and all 24 SCETests pass. Read this doc top-to-bottom; the v5 pipeline produces 54 cross-doc structural signals (8 same_entity merges + 46 typed edges across instance_of / attribute_of / process_for) on the 4-doc vitacare corpus using `gemini-3.1-pro-preview`. The runnable command + reproduction recipe is in §"How to reproduce a run". Next concrete actions: commit the 6 files in 5-6 surgical commits (see § Uncommitted state for the split), merge `main` to catch up on the data-loss fix + project-graph cleanup, then either (a) re-score the 40-pair rubric under the new typed-edge definition of "captured" or (b) re-enable `responseSchema` on Pro 3.1 to test if Gemini-3-series's fuller JSON Schema support handles the constraint-state cap we hit on Flash. Do NOT retry: enum constraint at scale on Flash (HTTP 400), structured-output mode at scale on Flash (88k-char truncations), vitacare-specific anti-pattern examples in the prompt (user-vetoed: no hardcoding).
