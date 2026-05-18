# ETR v5 prompt — harvest-only A/B (recall recovery attempt)

> **Branch:** `feature/etr-cross-doc` (delegator restored to **v4** in working tree).
> **Pairs with:** `audits/2026-05-18_v4-holdout-harvest-hearth.md` (the recall-loss finding v5 attempts to fix), `audits/2026-05-18_rubric-v3-vitacare.md` and `audits/2026-05-18_v4-prompt-experiment.md` (vitacare baseline — not re-tested here because `test_proj` is currently absent from the app).
> **TL;DR:** v5 adds an explicit "Brand value ↔ canonical implementing program" MERGE category paired with a sharpened "Principle ↔ one-of-many implementations" anti-pattern. On harvest_hearth: v5 recovers 1 of 6 brand-value stable-misses, retains v4's 0% stable trap rate, but **worsens worst-case trap count from 4 to 5**. Modest net improvement, not enough to justify another delegator flip. v4 stays default. v5 lives in code for future iteration.

## What v5 changes vs v4

One new MERGE category and one new paired KEEP-SEPARATE pattern.

### New MERGE: Brand value ↔ canonical implementing program

> One label states a brand value, principle, or commitment (often a short declarative phrase: "Repair and Resell", "Honest Sourcing", "Pay Fairly", "Durable over Disposable"). The other label is the named program, service, or system that operationalizes that exact principle. Merge ONLY when the program is the canonical / comprehensive realization of the principle — i.e., the program's scope and the principle's scope match. **Critical discriminator:** apply the substitution test — "if this specific program were removed from the company, could other distinct programs still fulfill the principle in full?" If yes (the program is one of several ways to honor the principle), KEEP SEPARATE — that is the umbrella anti-pattern below. If no (the principle is undeliverable without this exact program; the program's name directly names the activities the principle describes), MERGE.

### New KEEP-SEPARATE: Principle ↔ one-of-many implementations

> A stated principle/value/commitment paired with a specific policy, metric, or sub-program that is one of several distinct ways to honor that principle. Example pattern: a "pay fairly" principle paired with a specific "living wage" policy — the wage is one component of paying fairly, not the totality.

The two patterns are deliberately paired: the substitution test gates which side fires.

## Why design v5 this way

Harvest's recall loss in v4 (`audits/2026-05-18_v4-holdout-harvest-hearth.md`) concentrated on 6 brand-value↔program pairs (#35, #45, #65, #66, #91, #93 plus the v3-flapping #104). The vitacare regression risk for any new MERGE category is pairs like #17 "Cultural Principles ↔ Primary Care Management" — the same shape (principle ↔ program) but where the program is one of many that contribute to the principle. The substitution test gives the LLM a procedure to discriminate the two.

## Test setup

- Harvest_hearth only (4-PDF set, post-extraction baseline at `/tmp/atlas_snaps/harvest_postextract/`).
- 3 runs of v5 at floor 0.80, baseline restored between runs.
- Reuses the hand-graded 39-pair union rubric from `audits/2026-05-18_v4-holdout-harvest-hearth.md` (no re-grading — same in-band pool).
- v3 and v4 sidecars from the prior sweep (today's earlier work) are the comparison set.
- **Vitacare NOT re-tested.** `test_proj` had been removed when `harvest_hearth` was created; vitacare per-doc graphs remain on disk at `/tmp/atlas_snaps/postextract/` but the project metadata to wire them in via `--headless-extract --project test_proj --etr-only` is gone. Without UI re-creation, vitacare can't be re-run.
- Cost: ~$0.30 (3 warm-cache runs).

## Results

### Per-run

| Prompt | Run | Approvals | M | R | B | Precision | Recall |
|---|---|---|---|---|---|---|---|
| v3 | 1 | 24 | 18 | 2 | 4 | 75% | 90% |
| v3 | 2 | 21 | 17 | 3 | 1 | 81% | 85% |
| v3 | 3 | 22 | 17 | 3 | 2 | 77% | 85% |
| v4 | 1 | 23 | 18 | 3 | 2 | 78% | 90% |
| v4 | 2 | 23 | 13 | 4 | 6 | 57% | 65% |
| v4 | 3 | 19 | 15 | 1 | 3 | 79% | 75% |
| v5 | 1 | 18 | 15 | 1 | 2 | 83% | 75% |
| v5 | 2 | 24 | 14 | **5** | 2 | 58% | 70% |
| v5 | 3 | 21 | 15 | 1 | 5 | 71% | 75% |

### 3-of-3 stable intersection

| Prompt | Stable | M | R | B | Precision | Recall | Trap rate |
|---|---|---|---|---|---|---|---|
| v3 | 15 | 14 | 1 | 0 | 93% | **70%** | 10% |
| v4 | 11 | 11 | 0 | 0 | **100%** | 55% | 0% |
| v5 | 13 | 12 | 0 | 1 | 92% | 60% | **0%** |

### Worst-case single-run trap count

- v3: 3
- v4: 4
- **v5: 5** ← regression vs both predecessors

### Union over 3 runs

- v3: 31 approvals (M=20, R=6, B=5)
- v4: 33 approvals (M=18, R=7, B=8)
- v5: 31 approvals (M=17, R=5, B=6)

## What v5 gained and lost vs v4 stable

- **Gained (now in v5 stable, was not in v4 stable):** 2 pairs
  - #104 (M) Repair and Resell ↔ Hearth Again Return Program — ✓ target hit
  - #54 (B) Pay Fairly ↔ Ethical Supply Chain & Worker Wellbeing — borderline (the new principle-vs-program rule applied, arguably correctly)
- **Lost (was in v4 stable, now not in v5 stable):** 0 pairs

So v5 is strictly a superset of v4's stable behavior — never loses what v4 caught — but only adds 1 must-merge of the 6 brand-value pairs it was designed to recover.

## What v5 still misses (v3 catches in stable, v4+v5 do not)

| # | Pair | Why v5's substitution test likely still failed |
|---|---|---|
| #3  | Supply Chain & Operations ↔ Supply Chain & Logistics | Not a brand-value pattern — the new category doesn't apply. Both are umbrella scope-overlapping concepts. |
| #4  | Logistics & Inventory Management ↔ Supply Chain & Logistics | Same. |
| #35 | Repair and Resell ↔ Product Lifecycle & Sustainability | Brand-value↔broader-program. LLM probably treats the broader program as containing other things (recycling, repair, resell — 3 sub-programs), so substitution test reads "other programs could fulfill it" → keep separate. |
| #45 | Repair and Resell ↔ Product Lifecycle & Sustainability Programs | Same. |
| #65 | Repair and Resell ↔ Hearth Again Resale Program | Should have hit — but Hearth Again specifically does "resale" not "repair", so substitution test reads "Repair Services also fulfills Repair-and-Resell" → ambiguous. |
| #66 | Company Philosophy & Principles ↔ Company Mission | Not brand-value↔program — two abstract umbrellas. Out of new category's scope. |
| #89 | Supplier Engagement & Standards ↔ Sourcing & Suppliers | Paraphrase, not brand-value pattern. |
| #93 | Repair and Resell ↔ Repair Services | Same ambiguity as #65 — partial-coverage program. |

**Diagnosis:** v5's substitution test correctly discriminates strict canonical-implementations from one-of-many implementations, but the harvest corpus is full of "split implementations" — a brand value implemented across 2-3 sub-programs, none of which alone covers the principle. v5 reads these as one-of-many → reject. v3 was more permissive and caught them by reading the partial-coverage program as "primary realization."

The LLM's substitution-test reasoning is doing exactly what the prompt asks. The corpus's structural reality — brand values realized via *multiple* sub-programs — doesn't match the v5 MERGE criterion's "canonical" framing.

## Worst-case regression (v5 run 2)

v5 run 2 approved 5 must-rejects vs v4's worst-case 4. The new MERGE category appears to have broadened the LLM's merge appetite enough on some runs to also let in adjacent rejects. The 5 traps in v5 run 2 included #20 (Supplier Vetting ↔ Supplier Audits — different processes), #52 (Engagement ↔ Audits), #68 (Engagement ↔ Living Wage). These are exactly the "principle ↔ one-of-many" pairs the new KEEP-SEPARATE pattern was supposed to discriminate against — yet v5 still tripped them in this run.

The prompt's discriminator (substitution test) is asking the LLM to reason at a level it doesn't always sustain across the 3-batch adjudication. Single-run noise.

## Decision

**Keep v4 as the default.** v5 stays in code as `mergeAdjudicationV5` for future iteration but is NOT routed by the public delegator.

Rationale:

- v5 recovers only 1 of 6 targeted stable must-merges (17% recovery rate).
- v5 keeps v4's 0% stable trap rate, but worsens worst-case single-run trap count from 4 to 5.
- v5 is strictly a stable-superset of v4 (lost nothing v4 caught) — so reverting v5 → v4 loses 1 must-merge in exchange for tighter worst-case stability. Acceptable trade.
- The recall gap on harvest is more about corpus structure (split implementations) than prompt design. Closing it likely requires a different mechanism — e.g., post-LLM clustering that detects "principle named in N places, sub-programs in M places" as a meta-pattern, not a per-pair prompt instruction.

## Vitacare validation deferred

v5 was not tested on vitacare in this session. If/when `test_proj` is recreated in the app, the v5 ×3 sweep at floor 0.80 on vitacare would be ~$0.10 (warm cache) and would tell us whether the new MERGE category accidentally catches any vitacare KEEP-SEPARATE pairs (rubric #17, #19, etc. are the candidates). Until then, v5's safety on vitacare is unknown — another reason not to promote it.

## On-disk artifacts

| Path | What |
|---|---|
| `/tmp/atlas_sidecar_harvest_v5_run{1,2,3}_*.json` | 3 v5 sidecars |
| `/tmp/atlas_score_harvest_v5.py` | Scoring script that compares v3/v4/v5 against the harvest rubric |
| `/tmp/atlas_snaps/harvest_postextract/` | Same baseline used for the v4 holdout sweep |

## Open follow-ups

1. **Vitacare v5 sanity check** — after `test_proj` is recreated, run v5 ×3 on vitacare at floor 0.80 to confirm the new MERGE category doesn't catch new traps there. ~$0.10.
2. **Corpus-structural recall mechanism.** The split-implementation pattern on harvest probably can't be solved with prompt engineering alone. A post-LLM "principle clustering" pass — group nodes whose labels share value-words ("repair", "resell") and check if their programs are scoped together — might recover the recall without changing the prompt. Out of scope for today; worth a backlog entry.
3. **Per-corpus prompt selection.** If neither v4 nor v5 dominates universally, expose a per-project setting `etr.prompt = v3 | v4 | v5` and document when each wins. ~1 hr settings work; defer until users have multiple corpora in active use.
