# Annotation coordinate conversion — Y-inversion audit

**Date:** 2026-05-19
**Trigger:** CLAUDE.md "Known Issues" warned "Annotation coordinate conversion is manual (not using PDFKit built-ins) — may have Y-coordinate inversion issues." Audit triggered by a "next bug to do" request to verify whether that warning describes a real defect or a latent risk.
**Verdict:** No Y-inversion bug found. The warning was overstated; CLAUDE.md updated to reflect the real (different) risks.

## Methodology

Searched `pdf_app1/pdf_app1/**.swift` (excluding tests) for every site that:
- Calls `pdfView.convert(...)` (view ↔ page coord conversion)
- Reads `page.bounds(for: .mediaBox)`
- Constructs a `CGRect` from page-space inputs
- Writes `annotation.bounds`
- Contains manual Y-flip math (`pageHeight - y`, `bounds.maxY - bounds.minY`, `isFlipped`)

## Sites reviewed

| Site | File:line | Method | Verdict |
|------|-----------|--------|---------|
| Select-mode translate (body) | `PDFViewRepresentable.swift:495–525` | `pdfView.convert(location, to: page)` → delta in page coords → `AnnotationGeometry.translated` | ✅ Consistent. Both ends of delta in page coords. |
| Select-mode resize (corner/edge) | same | `AnnotationGeometry.handle(at:)` + `resized(rect:handle:by:in:minSize:)` | ✅ Same as above. Math symmetric across axes — no Y-specific path. |
| Highlight / underline / strikethrough | `handleSelectionCompleted` | `selection.bounds(for: page)` returns page coords | ✅ PDFKit-provided rect, no manual math. |
| Shape annotations (rect/circle/line/arrow/area highlight) | `handlePan` shape modes | `CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(...), height: abs(...))` | ✅ Direction-agnostic: min+abs produces a non-negative rect regardless of drag direction. No Y flip needed. |
| Sticky note placement | `handleClick` `case .stickyNote` | `CGRect(x: pagePoint.x, y: pagePoint.y - 12, w: 24, h: 24)` | ✅ Centers the 24×24 icon on the click in page-up coords. Visually centers on click. |
| Ink path | `handleInkPan` | NSBezierPath points = `pdfView.convert(location, to: page)` (page coords); bounds = bbox of those points + 5pt padding | ⚠️ Page-absolute (not Y-inversion — see "PDFKit-quirk risks" below) |
| Line / arrow endpoints | `handlePan` line/arrow | `annotation.setValue([startPagePoint, endPagePoint], forAnnotationKey: .linePoints)` — page-absolute | ⚠️ Same quirk class |
| Initial fit-to-page | `PDFViewRepresentable:54` | `page.bounds(for: .mediaBox)` → scale calc using `pageRect.width/height` | ✅ Scale-only math, no axis-specific logic |
| Text-page page-size for extraction | `TextExtractor`, `ExtractionPipeline` | `page.bounds(for: .mediaBox)` | ✅ Size used only for scaling, no Y math |

## What's NOT in the code

- Zero occurrences of `pageHeight - y`, `bounds.maxY - bounds.minY` (as a Y-flip pattern), or any manual Y inversion.
- Zero `isFlipped` overrides (`HighlightingPDFView` doesn't override it; PDFView inherits NSView's default `isFlipped = false`).
- Zero `page.rotation`-aware manual coordinate math. The code relies on `pdfView.convert(_:to:)` to normalize rotation, which is the documented PDFKit behavior.

## PDFKit-quirk risks (real but NOT Y-inversion)

Two sites populate PDFKit annotation values using **page-absolute** coordinates where Apple's docs are ambiguous about whether annotation-local was expected:

1. **Line / arrow `linePoints`** — `PDFViewRepresentable.handlePan` (`case .changed` for `.line`/`.arrow`) calls `annotation.setValue([startPagePoint, endPagePoint], forAnnotationKey: .linePoints)`. `startPagePoint`/`endPagePoint` are absolute page coords.
2. **Ink paths** — `handleInkPan` builds an `NSBezierPath` with `move(to: pagePoint)` and `line(to: pagePoint)` using absolute page coords, then `annotation.add(path)` after creating the annotation with bounds = bbox-of-those-page-coords-with-padding.

Apple's documentation for both `PDFAnnotationKey.linePoints` and `PDFAnnotation.add(_:)` doesn't say whether the points are page-absolute or annotation-local. Community evidence is mixed, but the page-absolute interpretation is what Atlas relies on and it works on current macOS (annotations render where the user drags). If a future PDFKit release standardizes on annotation-local interpretation, both lines/arrows AND ink would silently render offset by the annotation bounds' origin — they'd appear in the wrong place after the upgrade.

**Mitigation if it ever happens:** subtract `annotation.bounds.origin` from each point before storing. Tracked in CLAUDE.md "Known Issues / Gotchas" as a forward-looking caution, not a present bug.

## Recommendation

- No code change. Audit cleared.
- CLAUDE.md gotcha updated 2026-05-19 — replaced the "Y-coordinate inversion issues" warning with the more accurate PDFKit-quirk-sites caution.
- If desired, a 5-min live smoke-test (draw an ink stroke, drag the resulting annotation with select-mode body-drag, confirm the visible ink moves WITH the annotation rather than staying anchored to its page-absolute path coords) would actively close the line/arrow + ink quirk question. Until then it's a known-works-in-practice / could-break-on-upgrade caution.
