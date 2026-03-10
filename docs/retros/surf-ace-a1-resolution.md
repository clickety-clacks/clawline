# Surf Ace Appendix A.1 Resolution — Annotation Coordinate Space

**Date:** 2026-03-03  
**Decision:** Viewport coordinates (Option A)  
**Status:** Resolved and written into spec

---

## The Question

When a user draws on a Surf Ace surface, do the stroke coordinates stored in the `annotations` register live in **viewport space** (where the pen touched the screen) or **content space** (position within the scrollable document)?

---

## Recommendation: Viewport Coordinates

**Short answer:** Strokes are captured, stored, and composited in viewport coordinates. CLU uses the per-annotation `scrollOffset` field to reconstruct content position when needed.

---

## Rationale

### 1. The drawBuffer settles the question

The `drawBuffer` is defined as a pixel image with the same dimensions as the surface viewport. If strokes were stored in content coordinates, every scroll event would require re-projecting all strokes back into viewport space to update the buffer — expensive and complex. With viewport coordinates, strokes composite at their raw captured positions with zero transform. The buffer, annotation bboxes, and `surf_ace_read_buffer(bounds)` are all in the same space: CLU can pass an annotation's `bbox` directly as `bounds` and get a pixel-perfect crop.

### 2. Implementation is natural on both platforms

- **iOS (PencilKit):** Placing `PKCanvasView` as a fixed overlay over the scroll view's visible area (not inside the scroll view) gives viewport coordinates directly. The alternative — placing the canvas inside the scroll view for content coordinates — requires an unbounded canvas that grows with the document, complex hit-testing, and coordinate remapping. Significantly harder.
- **Electron:** An HTML canvas at `position: fixed` over the content frame gives viewport coordinates natively. The natural, simple implementation.

### 3. Content coordinates create a drawBuffer consistency problem

If strokes were stored in content coordinates, the provider would need to know the scroll offset at time of each stroke to composite correctly. The wire `DrawingFlushEvent` doesn't carry scroll offset (and the provider only knows it approximately). This creates an inherent approximation error that doesn't exist with viewport coordinates.

### 4. Multi-scroll disambiguation is solvable

The main argument for content coordinates is that strokes from different scroll positions are spatial disconnected in viewport space. The solution: add `scrollOffset: { x, y }` to each annotation register entry, captured at flush-receive time. CLU gets:
```
content_x = stroke_x + scrollOffset.x
content_y = stroke_y + scrollOffset.y
```
For single-scroll sessions (the common case), this is exact. For multi-scroll sessions, CLU can detect divergent `scrollOffset` values across annotation batches and handle them as distinct spatial groups rather than a unified map.

---

## What Changed in the Spec

1. **Appendix A.1** — replaced "Unresolved" with full decision, coordinate definition, drawBuffer implication, CLU mapping formula, iOS/Electron implementation notes, multi-scroll limitation, and v2 upgrade path.

2. **§13.2 annotations register** — added `scrollOffset: {x, y}` to the per-stroke register entry shape. Provider captures scroll state at flush-receive time and attaches it to each batch.

3. **§14.3 surf_ace_read** — annotation schema in tool return doc updated to include `scrollOffset`, with note that all coordinates are viewport-space.

4. **§14.3 surf_ace_read_buffer** — `bounds` parameter doc updated to explicitly state viewport coordinates and note that annotation bboxes can be passed directly.

5. **A.2 and A.6** — status lines updated to note A.1 is resolved.

---

## v2 Upgrade Path

v2 should extend the wire `DrawingFlushEvent` with `scrollOffsetAtFirstStroke` and `scrollOffsetAtLastStroke`. This replaces the provider's best-effort scroll capture with the surface's authoritative per-batch value. A full content-coordinate model (surface translates on-device before reporting) is also viable but requires a protocol version bump.

---

## What Was Deliberately Not Changed

- The wire `Stroke` schema (in `DrawingFlushEvent`) was not modified. `scrollOffset` is a **provider-computed field** added to the register representation only. The surface never needs to know the scroll offset — it captures raw pen positions and reports them. The provider adds context from the `scrollPosition` register.
- No new wire messages required.
- Fully backward compatible within v1.
