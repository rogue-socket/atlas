# ETR in-doc pair leak — root-cause trace

> **Triggered by:** `audits/2026-05-18_v4-prompt-experiment.md` §"In-doc pair leak" and the rubric pair #6 anomaly in `audits/2026-05-18_rubric-v3-vitacare.md`.
> **TL;DR:** Not a filter bug. `isCrossDoc` uses set-inequality on `sourceAnchors`' document URLs; pair #6 surfaces because one node has multi-doc anchors from a prior merge. The sidecar attribution (`sourceAnchors.first?`) hides this — making the pair look same-doc to a reader of the sidecar.

## The pair

```
Pair #6 (sim 0.834, in-band, v3 run 3 approved):
  aID = 101DBCB2-…  label = "VitaCare Overview & Governance"
  bID = BCD0A513-…  label = "Company Identity"
  aDoc = vitacare_compliance_quality_and_security.pdf
  bDoc = vitacare_compliance_quality_and_security.pdf       ← misleading
```

Both `aDoc` and `bDoc` are the compliance PDF, suggesting an in-doc adjudication.

## What the per-doc graph files actually contain

Decoded `/tmp/atlas_snaps/postextract/{4 per-doc graphs}` and searched for both UUIDs:

```
[org per-doc file]
  BCD0A513 "Company Identity"          sourceAnchors: 2 — [compliance, org]

[compliance per-doc file]
  101DBCB2 "VitaCare Overview & …"     sourceAnchors: 1 — [compliance]
  BCD0A513 "Company Identity"          sourceAnchors: 1 — [compliance]
```

UUID `BCD0A513` appears in TWO per-doc files. In the org file its `sourceAnchors` already span both compliance and org; in the compliance file it spans only compliance.

When `loadProjectWideGraph` merges these per-doc files into a single project graph, the same UUID resolves to one node whose `sourceAnchors` end up as the union — `[compliance, org]` (2 distinct doc URLs).

## What `isCrossDoc` does (the filter)

`EmbeddingResolver.swift:147-155`:

```swift
/// Cross-doc pair filter. Returns false (skip) when both nodes have the
/// **exact same set** of source documents — that includes the common case
/// of "both came from the same single doc" and the rarer "both already
/// merged across the same docs."
static func isCrossDoc(_ a: ConceptNode, _ b: ConceptNode) -> Bool {
    let setA = Set(a.sourceAnchors.map { $0.documentURL })
    let setB = Set(b.sourceAnchors.map { $0.documentURL })
    return setA != setB
}
```

For our pair after project-wide load:

- `A` (101DBCB2): `setA = {compliance}`
- `B` (BCD0A513): `setB = {compliance, org}`  ← merged-spanning
- `setA != setB` → **true** → considered cross-doc → enters pair pool

The docstring is precise: "exact same set." The function operates as designed.

## What `aDoc`/`bDoc` actually represent in the sidecar

`EmbeddingResolver.swift:80` + sidecar writer at `:405`:

```swift
let aDoc: String?      // primary source-doc filename (first anchor)
...
aDoc: a.sourceAnchors.first?.documentURL.lastPathComponent,
```

Only the *first* sourceAnchor's doc URL is recorded. So a node with anchors `[compliance, org]` shows up as `aDoc = compliance.pdf` regardless of the second anchor. This is the diagnostic blindspot — the sidecar makes pair #6 look same-doc when it isn't (per the resolver's own definition).

## So is this a bug?

Three independent issues, separable:

### Issue 1 (semantic): the cross-doc test is "any set difference," not "no shared doc"

**The design is intentional** per the docstring — "rarer merged across the same docs" is explicitly carved out. But it admits the pattern we're seeing: when one node has been previously merged across multiple docs and the other hasn't, they re-enter the adjudication band even though they share at least one doc.

This is a **judgment call**, not a bug:

- **Pro current design:** if `B` is a previously merged "Company Identity" spanning [compliance, org], it's plausibly the canonical entity, and `A` (a compliance-only sibling) is a candidate to fold into it. Re-adjudicating them is the right call.
- **Con current design:** the pair appears as "in-doc" from a sidecar reader's perspective, undermining trust in the cross-doc invariant. Also, if the merged `B` was an over-merge to begin with, re-adjudicating it just compounds the error.

**Recommended action:** Leave the semantic as-is for now (it serves the broader "ETR is for cross-doc dedup" intent). Document the edge case explicitly in the `isCrossDoc` docstring with an example.

### Issue 2 (diagnostics): sidecar's `first?` attribution hides the multi-doc case

This is a **real bug** — but cosmetic. The sidecar should reflect what the resolver actually sees. Change `aDoc: String?` to `aDocs: [String]` (or a comma-joined string) and emit all doc URLs sorted. Then pair #6 would render as:

```
aDoc = compliance.pdf
bDoc = compliance.pdf, org.pdf   ← signals: this is merged-spanning, not in-doc
```

Self-documenting. ~5-line code change in the sidecar entry struct + writer.

### Issue 3 (process): how did BCD0A513 end up multi-doc-anchored in the per-doc file?

The org per-doc file shouldn't normally write a Company Identity node with anchors in the compliance doc. This implies a previous ETR / extraction-time merge folded the compliance instance into the org instance (or vice versa), and the merged anchors got persisted into both per-doc files via `scheduleSave` + `encodeSubgraph(for:)`.

This is **expected behavior** of the merged-state save path. `encodeSubgraph(for: orgURL)` writes nodes anchored at org — including the multi-doc-anchored BCD0A513 which has an org anchor. The same node also has a compliance anchor, so `encodeSubgraph(for: complianceURL)` writes it to the compliance per-doc file too. Both files persist the union-anchored node, by design (so that opening either doc cold finds the cross-doc presence).

The artifact is a feature, not a bug. The implication for ETR: a previously-merged node will *always* satisfy `isCrossDoc` against any of its single-doc siblings after re-load, because its anchor set is a superset of any single doc. So once you merge across N docs, all single-doc siblings of the merged node get re-adjudicated on every subsequent ETR run.

This may be intended (re-adjudication is cheap on warm cache) or undesirable (it expands the adjudication band over time as more pairs get merged). Worth a separate session to decide.

## Recommended follow-ups

1. **Fix Issue 2 (~10 min).** Update sidecar attribution to emit all source docs as a list. Eliminates the "looks in-doc, actually cross-doc" confusion in future rubric reads. Add the explicit example to `isCrossDoc`'s docstring at the same time.
2. **Hold Issue 1.** Don't change the cross-doc semantic without an A/B run that quantifies how often the merged-spanning case generates noise vs valid merges. The fact that v3 run 3 was the only one of 6 runs that approved pair #6 suggests the current behavior produces noise but not consistent noise.
3. **Reserve Issue 3 for a separate session.** The "previously-merged nodes auto-re-adjudicate forever" property is interesting but not urgent. Worth understanding as ETR runs accumulate over the project lifetime.

None of these block flipping the public delegator to v4 (already committed). The "in-doc leak" framing in the v4 audit should be corrected to "merged-spanning pair attribution gap"; the v4 commit message already references it as a separate finding, which is the right scope.

## Reproduction

Scoring script `/tmp/atlas_score.py` and the `target_ids` Python snippet in this audit reproduce the trace. The pinned per-doc snapshots (`/tmp/atlas_snaps/postextract/`) are the inputs.
