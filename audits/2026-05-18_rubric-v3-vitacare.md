# ETR Rubric v3 — vitacare 2026-05-18 fresh extraction

> **Pairs with:** `audits/2026-05-18_v3-prompt-experiment.md` (the v3 prompt that pushed the old rubric into "labels don't match anything" territory); `audits/2026-05-17_etr-prompt-tune.md` (rubric v2, now obsolete).
>
> **Status:** This rubric supersedes "Quality Rubric v2 — vitacare 2026-05-16" in `prds/2026-05-15_4-level-knowledge-graph.md`. The v2 rubric's labels (e.g. "Asynchronous messages", "Lab result release: typically within 24 hours") no longer exist in the post-`1df5c35` extraction, which produces chapter-style aggregated concepts ("VitaCare Overview & Service Model", "Care Model & Cultural Principles") rather than fact-level entities. Treat v2 as historical.

## Why this exists

The v3 audit (`audits/2026-05-18_v3-prompt-experiment.md` §"What v3 still gets wrong") identified two unresolved over-merges (#2 and #4 in that doc — both involve umbrella-style labels on both sides of the pair) and one real-loss merge regression (#6 — SUD ↔ BH privacy, the regulatory-subset case). Acting on those findings requires a *measurable* baseline to compare future prompt revisions against, and the published "Quality Rubric v2" can't provide one because none of its labels match the current extraction.

This document is that baseline. It is built from the **actual 52 in-band pairs** the embedding stage surfaces at floor 0.80 against the current 2026-05-18 extraction (per pinned sidecar `/tmp/atlas_sidecar_v3_080_20260518T131220.json`), hand-graded.

## Source data

- **Extraction:** 4-doc vitacare set, deep mode, Gemini 2.5 Flash, T=0+topK=1, performed 2026-05-18 02:16–02:28.
- **Graph state:** 214 nodes / 405 edges total, 185 eligible (concept + entity level). Pinned snapshot: `/tmp/atlas_snaps/postextract/`.
- **Embedding model:** `gemini-embedding-2-preview`, 3072-dim.
- **Adjudication band:** similarity ∈ [0.80, 0.95]. Pairs at sim ≥ 0.95 are auto-merged before LLM (this is why the literal `org: Company Identity` ↔ `compliance: Company Identity` pair — identical label and summary — does not appear in this rubric; it is presumed to auto-merge above the LLM-adjudication band).
- **In-band pair count:** 52 (out of 12,628 cross-doc pairs evaluated).

## Methodology

For each in-band pair, an eyeball verdict against the test "could the two labels appear as bullet points under the same heading in a corporate handbook describing a single process, service, fact, or entity?" is recorded. Pairs are graded:

- **MUST-MERGE** (M) — clear shared real-world referent. Recall denominator.
- **MUST-REJECT** (R) — clear KEEP-SEPARATE; one of the v3-prompt failure-mode patterns applies.
- **BORDERLINE** (B) — could be argued either way; not counted toward precision/recall but tracked.

Scoring of a future run:

- **Precision** = (approvals that are MUST-MERGE) / (total approvals)
- **Recall** = (approvals that are MUST-MERGE) / (MUST-MERGE count)
- **Trap rate** = (approvals that are MUST-REJECT) / (MUST-REJECT count)

A v4 prompt is "better than v3" if it strictly improves precision OR recall without making the other worse, **on a 3-of-3 stable intersection** across runs (single-run reads are noise-dominated per `audits/2026-05-17_etr-prompt-tune.md` §"Methodology").

## Grading

Sorted by similarity (descending). `[X]` = cross-doc; `[in]` = in-doc. v3 = the verdict in the pinned sidecar.

### MUST-MERGE (3)

| # | sim | v3 | A | B | Pattern |
|---|---|---|---|---|---|
| 3 | 0.849 | ✓ | compliance: Corporate & Provider Compliance | org: Legal Structure & Clinical Services | **Paraphrase** — both describe PSA structure for corporate-practice-of-medicine states. Same operational fact, different framing. |
| 11 | 0.821 | ✗ | compliance: SUD Record Protections | clinical: Behavioral Health Record Privacy | **Regulatory subset** — SUD records under 42 CFR Part 2 are a strict-superset stricter regime *layered on top of* the BH record privacy regime in the clinical system. v3 misses this — it is the documented "real loss" from `audits/2026-05-18_v3-prompt-experiment.md` #6. **Primary recovery target for v4.** |
| 45 | 0.803 | ✓ | compliance: Consent Framework | clinical: Behavioral Health Record Privacy | **Partial overlap / shared scope** — Consent Framework's content is SUD-record consent + disclosure; BH Record Privacy is the access-control regime that consent governs. Both reference the same regulated record class. |

### MUST-REJECT (43)

Categorized by which v3 KEEP-SEPARATE pattern applies. v3 verdict shown.

#### LEAF-OF-CATALOG / umbrella ↔ aspect (most common failure class; 14)

| # | sim | v3 | A | B |
|---|---|---|---|---|
| 2 | 0.864 | ✗ | clinical: VitaCare Overview & Service Model | org: VitaCare Health Network Overview |
| 4 | 0.846 | **✓ over-merge** | clinical: VitaCare Overview & Service Model | org: Care Model & Cultural Principles |
| 5 | 0.841 | ✗ | clinical: VitaCare Overview & Service Model | patient: Coordinated Care & Referrals |
| 8 | 0.824 | **✓ over-merge** | clinical: VitaCare Overview & Service Model | org: Core Care Principles |
| 12 | 0.820 | ✗ | org: Clinic Network & Facilities | clinical: VitaCare Overview & Service Model |
| 15 | 0.815 | ✗ | org: Core Care Principles | clinical: Core Service Areas |
| 16 | 0.815 | ✗ | clinical: VitaCare Overview & Service Model | patient: Strategic Partnerships |
| 18 | 0.814 | ✗ | clinical: VitaCare Overview & Service Model | org: Workforce & Staffing Model |
| 21 | 0.812 | ✗ | clinical: VitaCare Overview & Service Model | org: Operational Scale & Financials |
| 36 | 0.806 | ✗ | patient: VitaCare Patient Experience Design | org: VitaCare Health Network Overview |
| 47 | 0.803 | ✗ | patient: Appointment & Response Timelines | clinical: VitaCare Overview & Service Model |
| 48 | 0.802 | ✗ | clinical: VitaCare Overview & Service Model | org: Clinic & Telehealth Reach |
| 49 | 0.802 | ✗ | clinical: VitaCare Overview & Service Model | patient: VitaCare Patient Experience Design |
| 51 | 0.801 | ✗ | clinical: VitaCare Overview & Service Model | org: Clinical Performance Outcomes |

**Pattern note:** v3's leaf-of-catalog rule (word-list test on the umbrella side) correctly rejects 12/14, but fails on #4 and #8 — both have umbrella-style words on BOTH sides, so the asymmetry the rule depends on collapses. v4 must address this: either rule needs to fire on "either side strictly contains the other's scope," or umbrella ↔ umbrella needs its own explicit anti-pattern.

#### Different fact / different metric (shared noun, same object) (11)

| # | sim | v3 | A | B |
|---|---|---|---|---|
| 1 | 0.873 | ✗ | patient: Service Availability & Performance | org: Clinical Performance Outcomes (different metric domains — service-ops % vs HEDIS clinical %) |
| 9 | 0.824 | ✗ | org: Clinic & Telehealth Reach | compliance: Quality Accreditations |
| 13 | 0.819 | ✗ | clinical: Telehealth Availability & Response Times | patient: Clinic & Telehealth Hours (SLA vs operating hours) |
| 17 | 0.814 | ✗ | org: Care Model & Cultural Principles | clinical: Primary Care & Chronic Condition Management (philosophy ↔ service) |
| 19 | 0.813 | ✗ | org: Core Care Principles | clinical: Primary Care & Chronic Condition Management |
| 23 | 0.809 | ✗ | org: Regional Network Structure | compliance: Quality Accreditations |
| 35 | 0.807 | ✗ | patient: Specialist Network & Affiliations | compliance: Quality Accreditations |
| 41 | 0.805 | ✗ | patient: Performance Metrics | org: Clinical Performance Outcomes (service-ops vs HEDIS) |
| 42 | 0.804 | ✗ | patient: Appointment & Response Timelines | org: Core Care Principles |
| 22 | 0.811 | ✗ | clinical: Clinician Licensing & Data Privacy | org: Clinic & Telehealth Reach |
| 32 | 0.807 | ✗ | compliance: Patient Safety Initiatives | patient: Patient Support & Accessibility |

#### Internal vs external / adjacent-but-distinct programs (5)

| # | sim | v3 | A | B |
|---|---|---|---|---|
| 10 | 0.822 | ✗ | patient: Diagnostic & Pharmacy Partners | clinical: On-site & Ancillary Services (external partners ↔ on-site facilities — v2 trap) |
| 20 | 0.812 | ✗ | patient: Coordinated Care & Referrals | clinical: On-site & Ancillary Services |
| 28 | 0.808 | ✗ | clinical: Chronic Disease Management Programs | patient: Patient Education & Engagement Programs (different program types) |
| 33 | 0.807 | ✗ | patient: Group Programs & Newsletters | clinical: Chronic Disease Management Programs (different modalities — v2 trap) |
| 38 | 0.806 | ✗ | patient: Strategic Partnerships | clinical: On-site & Ancillary Services |

#### Different processes / different scope (9)

| # | sim | v3 | A | B |
|---|---|---|---|---|
| 7 | 0.828 | ✗ | compliance: Clinical Processes | patient: Referral Management Process (lab/imaging closed-loop ↔ specialist referral) |
| 14 | 0.815 | ✗ | patient: Hospital Discharge Coordination | compliance: Clinical Processes |
| 25 | 0.809 | ✗ | patient: Strategic Partnerships | org: Clinical Performance Outcomes |
| 27 | 0.808 | ✗ | patient: Specialist Network & Affiliations | org: Regional Network Structure (specialist vendor network ↔ internal regional structure) |
| 29 | 0.808 | ✗ | compliance: Patient Safety Initiatives | patient: Coordinated Care & Referrals |
| 30 | 0.808 | ✗ | compliance: Accreditations & Certifications | patient: Patient Support & Accessibility |
| 34 | 0.807 | ✗ | patient: Patient Support & Accessibility | compliance: Compliance Monitoring & External Relations |
| 37 | 0.806 | ✗ | org: Clinic & Telehealth Reach | patient: Employer Partners |
| 40 | 0.805 | ✗ | clinical: Primary Care & Chronic Condition Management | patient: Patient Education & Engagement Programs |

#### Shared noun, different actor/object (4)

| # | sim | v3 | A | B |
|---|---|---|---|---|
| 26 | 0.808 | ✗ | clinical: Specialty Care Offerings | patient: Strategic Partnerships |
| 39 | 0.805 | ✗ | patient: Specialist Network & Affiliations | org: Clinic & Telehealth Reach |
| 44 | 0.803 | ✗ | patient: Health System Affiliations | org: Clinic & Telehealth Reach |
| 52 | 0.801 | ✗ | patient: Strategic Partnerships | compliance: Accreditations & Certifications |

### BORDERLINE (5) — not counted in precision/recall

These could be argued either way; they are excluded from the scoring formula to keep precision/recall numerically stable across prompt revisions. Track v3's verdict for sanity.

| # | sim | v3 | A | B | Why borderline |
|---|---|---|---|---|---|
| 24 | 0.809 | ✗ | patient: Service Availability & Performance | clinical: Telehealth Services & Access | Service-availability overlaps telehealth access; arguably partial-overlap merge |
| 31 | 0.808 | ✗ | patient: Communication Channels | clinical: Telehealth Services & Access | Comm channels include the async-messaging part of telehealth |
| 43 | 0.803 | ✗ | clinical: Telehealth Services & Access | patient: Patient Support & Accessibility | Telehealth IS one of the support channels |
| 46 | 0.803 | ✗ | patient: Coordinated Care & Referrals | clinical: Primary Care & Chronic Condition Management | Coordinated care includes some primary-care functions |
| 50 | 0.802 | ✗ | patient: Appointment & Response Timelines | clinical: Telehealth Services & Access | Telehealth has its own appointment/response cadence (synchronous video + async messaging) |

### IN-DOC (1) — observation

| # | sim | v3 | A | B | Note |
|---|---|---|---|---|---|
| 6 | 0.834 | ✗ | compliance: VitaCare Overview & Governance | compliance: Company Identity | **Both nodes from the same doc.** ETR's `pairsToCompare` is currently surfacing some in-doc pairs despite the backlog item describing in-doc support as not-yet-enabled. Worth investigating separately; **excluded from this rubric's scoring**. |

## Summary counts

| Category | Count |
|---|---|
| MUST-MERGE | 3 |
| MUST-REJECT | 43 |
| BORDERLINE | 5 |
| In-doc (excluded) | 1 |
| **Total in-band at 0.80** | **52** |

## Baseline scores under this rubric

Computed against the pinned v3 sidecar (`/tmp/atlas_sidecar_v3_080_20260518T131220.json`):

| Prompt | Approvals | of which MUST-MERGE | of which MUST-REJECT | of which BORDERLINE | Precision | Recall | Trap rate |
|---|---|---|---|---|---|---|---|
| v3 (single run) | 4 | 2 (#3, #45) | 2 (#4, #8) | 0 | **50%** | **67%** (2 / 3) | **5%** (2 / 43) |

The single MUST-MERGE v3 misses is #11 (SUD ↔ BH privacy). The two trap rejections it fails are #4 and #8 (umbrella ↔ umbrella with leaf-of-catalog rule asymmetry collapse).

**v4 targets:**
- Recover #11 → recall ≥ 100% (3/3)
- Reject #4 and #8 → trap rate → 0%
- Keep #3 and #45 → precision ≥ 75% (3/4) if exactly these three approvals fire

A v4 that lands these three goals would score **100% precision, 100% recall, 0% trap rate** on this rubric (single-run; needs 3-of-3 stability to confirm).

## Limitations

- **In-band only.** Pairs at similarity < 0.80 are not in the rubric. v4 can't be evaluated for missed merges in the 0.75–0.80 band without a wider-floor run, which is excluded here for cost reasons.
- **Single-corpus.** Only vitacare. Behavior on harvest_hearth (the held-out corpus per `audits/2026-05-16_etr-step1-plan.md`) is not measured.
- **Hand-graded.** No second-rater for kappa; verdicts are one person's eyeball over a single review pass.
- **In-doc pair leakage.** Pair #6 reveals `pairsToCompare` isn't strictly cross-doc-filtered as the backlog implies. Excluded from scoring; flag as a separate audit item.

## Maintenance

When extraction changes (different prompt, different model, different abstraction level), this rubric expires the same way v2 did. The fingerprint to watch: if the in-band pair list (the 52 above) no longer matches a fresh `--etr-only` run's sidecar at floor 0.80 ± a few %, the rubric needs re-grading. Cheap protection: keep the pinned sidecar and the postextract snapshot alongside this doc so any reader can re-compute the in-band list from the same baseline graph.
