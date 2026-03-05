# Surf Ace Spec A.1 Consistency Review

**Date:** 2026-03-03  
**Reviewer:** subagent (surf-ace-a1-check)  
**Scope:** Targeted A.1 resolution changes only — three focus areas below.  
**Verdict: NITS ONLY** — no functional contradictions, no wire breakage, no real errors.

---

## Focus Area 1: `scrollOffset` in annotations register (§13.2) vs. `surf_ace_read` return (§14.3) vs. wire Stroke schema

### What was checked
- §13.2 annotations register entry shape: `{ strokeId, points:[{x,y,pressure?}], bbox, startedAt, endedAt, scrollOffset:{x,y}, videoTimestamp? }`
- §14.3 `surf_ace_read` annotations return shape: same
- Wire `Stroke` schema (§10): `{ strokeId, tool, points: [StrokePoint], videoTimestamp? }` — no `scrollOffset`

### Result: Consistent

`scrollOffset` is not in the wire `Stroke` schema and the spec correctly accounts for this. §13.2 explicitly states it is provider-computed — captured from the latest known `scrollPosition` at flush-receive time, not from the wire. A.1 reinforces this: "The `scrollOffset` field added to the `annotations` register in v1 (below) is forward-compatible: v2 can replace it with the wire-provided value once available." §14.3 returns the same shape as §13.2 defines. All three are coherent.

### Nits

**Nit 1 (clarity): Per-batch vs. per-stroke granularity never stated explicitly.**  
`scrollOffset` is described as captured "at the moment the drawing flush event is processed" — i.e., one value per flush. But the register stores it as a per-stroke entry field. The spec implies all strokes within a single flush share the same captured `scrollOffset`, but never says so directly. This is inferable from context (the v2 upgrade path adds `scrollOffsetAtFirstStroke`/`scrollOffsetAtLastStroke` as batch fields, confirming v1 is single-batch precision), but could trip up implementers writing the flush→annotation fanout code.

**Recommended addition to §13.2:** One sentence: "All strokes in a single `drawing_flush` batch receive the same `scrollOffset` value — the provider captures one scroll position per flush, not per stroke."

---

**Nit 2 (implementation gap): "latest known scrollPosition" is ambiguous after a `surf_ace_read` clears the register.**  
The `scrollPosition` register is cleared on each `surf_ace_read` call. The spec says the provider captures `scrollOffset` from "the latest known `scrollPosition` at the moment the drawing flush event is processed." If CLU has recently called `surf_ace_read` (clearing the register) and then a flush arrives, a naive implementation that reads from the register would find `null` and fall back to `{ x: 0, y: 0 }` — silently losing the actual scroll state.

The spec intends "latest known" to mean the provider's internal scroll state (independently maintained), not the CLU-readable register. But this is only implicit. A provider that conflates the two will produce wrong `scrollOffset` values after CLU reads.

**Recommended addition to §13.2:** "The provider MUST maintain scroll state as internal state independent of the CLU-readable `scrollPosition` register. Clearing the register on `surf_ace_read` does not reset the provider's internal scroll position used for `scrollOffset` capture."

---

## Focus Area 2: `bounds` param in `surf_ace_read_buffer` — viewport-coordinate note

### What was checked
- §14.3 `surf_ace_read_buffer` param: `bounds: { x, y, width, height } in viewport coordinates — logical points matching annotation bbox fields`
- §14.3 `surf_ace_read_buffer` return: `width int` / `height int` described as "Pixel width/height of returned image"
- §A.1: drawBuffer pixel dimensions = `SurfaceViewport.width × scale × SurfaceViewport.height × scale` (physical pixels). Bounds described as "MUST be in viewport coordinates… pass the annotation's bbox directly; no translation needed."

### Result: Consistent (no contradiction)

The design is: input `bounds` in logical points, output image in physical pixels. The "no translation needed" phrase correctly means no `scrollOffset` addition is required — not that the implementer skips the logical→physical scaling. This is a standard display API pattern. The spec consistently uses this split: annotation `bbox` fields are in logical viewport points; the drawBuffer and returned image dimensions are physical pixels.

### Nit

**Nit 3 (clarity): "no translation needed" is accurate but potentially misleading alongside the logical/physical distinction.**  
A reader could parse "pass the annotation's bbox directly; no translation needed" to mean the bounds are in the same space as the physical buffer pixels — but they're not; they're in logical points and the implementation must scale by `scale` before cropping. The phrase correctly means "no scrollOffset translation needed" (as opposed to content-space coordinates), but the logical→physical scaling step is never mentioned in the bounds description.

The surrounding text in A.1 does explain the relationship (`buffer pixel at (px, py)` ↔ `logical point (px/scale, py/scale)`), but the connection to the bounds parameter isn't drawn explicitly.

**Recommended addition to §14.3 `surf_ace_read_buffer` bounds description:** "Implementation MUST multiply `bounds` coordinates by `SurfaceViewport.scale` to derive the physical pixel crop rectangle before slicing the buffer."

---

## Focus Area 3: A.1 resolution text — internal consistency with rest of spec

### What was checked
- A.1 coordinate definition, drawBuffer pixel size formula, content-space formula, iOS/Electron impl guidance, multi-scroll note, v2 upgrade path
- Cross-checked against §13.2 (annotations register), §14.3 (`surf_ace_read`, `surf_ace_read_buffer`), wire `Stroke` schema (§10), `Viewport` schema (§10)

### Result: Internally consistent

All formulas are coherent:
- `content_x = viewport_x + scrollOffset.x` appears identically in A.1, §13.2, and §14.3. ✓
- drawBuffer physical pixel size formula (`width × scale, height × scale`) matches `SurfaceViewport` schema (`width: int`, `height: int`, `scale: number`). ✓
- Crop bounds in logical points aligned with annotation `bbox` fields (both in logical viewport points). ✓
- `scrollOffset: {x,y}` field shape in A.1 matches register definition in §13.2 and `surf_ace_read` return in §14.3. ✓
- v2 extension path (`scrollOffsetAtFirstStroke`/`scrollOffsetAtLastStroke` added to `DrawingFlushEvent`) doesn't conflict with any v1 schema definition — wire `Stroke` schema is `additionalProperties: false` but the extension targets the flush envelope payload, not `Stroke`. ✓
- "Status: Resolved — 2026-03-03" timestamp is consistent with the Last Updated date at top of spec. ✓

### No nits on A.1 internal consistency.

---

## Summary Table

| Item | Finding | Severity |
|---|---|---|
| scrollOffset in §13.2 vs §14.3 | Consistent | — |
| scrollOffset vs wire Stroke schema | Consistent (provider-computed by design) | — |
| Per-batch scrollOffset never explicitly stated | Ambiguous for implementers | Nit |
| "Latest known scrollPosition" could conflict with register clear | Implementation trap | Nit |
| bounds in logical points, buffer in physical pixels, "no translation" phrase | Accurate but potentially misleading | Nit |
| A.1 resolution internal consistency | Fully consistent | — |

**Overall verdict: NITS ONLY.** No wire-breaking changes, no schema contradictions, no functional errors in the A.1 additions.
