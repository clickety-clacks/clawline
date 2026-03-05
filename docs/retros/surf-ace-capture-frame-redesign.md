# Retro: Surf Ace Capture Frame Redesign

**Date:** 2026-03-03  
**Spec:** `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

---

## What Changed

### Core model replacement (§13.2)

The old model used a persistent `drawBuffer` (composited pixel image) + `annotations` (persistent stroke register) + `dirty` flag. This was replaced with a **capture frame queue**: a FIFO queue of closed, self-contained capture frames. Each frame contains a viewport screenshot + all strokes from one annotation session + context metadata (scrollOffset, viewport, contentId, url, capturedAt).

**Frame lifecycle:** Opens on annotation mode entry → strokes accumulate → closes on annotation mode exit (Done / toggle) → frame appended to queue, strokes disappear from surface.

**Key improvement:** Image and strokes share the same coordinate space by construction (viewport is locked during annotation mode), so there is zero coordinate ambiguity.

### New §6.10: Annotation Mode

Added explicit documentation of the surface UX lock. When active: scroll disabled, link following disabled, drawing enabled. iPad: enters on pencil contact, exits on Done button. Electron: toggle button. Wire-protocol transparent — no new message types.

### §13.3: Alert gate simplified

Old model: alert fired on `dirty` flag transition, re-armed on CLU read. New model: alert fires when a closed frame enters the queue (user exits annotation mode). One alert per unread batch; re-arms when CLU reads. Alert text: `"N capture frame(s) pending on [screen name]"`.

### §13.4: Single read tool

Old model had two tools (`surf_ace_read` for registers, `surf_ace_read_buffer` for composite image). New model: single `surf_ace_read` returns up to 5 frames (pixel budget ~4MB) + register values. Frames are dequeued on read. `pendingFrames` count signals remaining queue depth.

### §14.3 surf_ace_read

Return schema updated to include `frames[]` array with full frame contents (image, strokes, metadata). `pendingFrames` added. All register fields preserved.

### §14.3 surf_ace_read_buffer

Marked deprecated. No longer needed — frame images are embedded in each frame returned by `surf_ace_read`.

### §14.3 surf_ace_annotations_remove

Added note: in the capture frame model, this tool only affects strokes from the currently open session (closed frames are immutable). Post-session stroke management is handled at the CLU layer.

### Appendix A.1

Added "Further resolution" note: capture frame model fully resolves the coordinate space question. Scroll-locked annotation mode means image and strokes are spatially coherent by construction. Removed old `drawBuffer` and `surf_ace_read_buffer` references; updated v2 path note.

### Appendix A.2

Marked resolved. Multi-scroll sessions produce multiple frames (one per annotation mode session), each spatially coherent. No stitching needed.

### Appendix A.3 (Brackets Problem)

Updated: bracket strokes now arrive together in a single frame's stroke set (whole gesture captured in one session). Geometry inference is easier but on-device classification (A.4) still recommended for reliable intent resolution. Design deferred to v2 with `semanticHints` field per frame.

### Appendix A.4

Updated: on-device classification applies per frame at frame-close time (the natural boundary). Classification at flush time (mid-session, partial strokes) is explicitly not recommended.

---

## What Was NOT Changed

- Wire protocol (§§3–11): all WS messages, schemas, event types, heartbeat, reconnect logic — unchanged
- `annotations.remove` wire operation and CLU tool — preserved (applies to open sessions)
- `snapshot.get` wire operation — unchanged
- Connection lifecycle, pairing, content operations — unchanged
- All other registers (taps, scroll, selection, page, playback, lastNavigation) — unchanged

---

## Rationale

The register model required CLU to hold conceptual state across two reads (registers + buffer), and the drawBuffer composite could represent spatially incoherent state when users drew across multiple scroll positions. The capture frame model eliminates this: each frame is a self-contained unit of annotation intent, delivered whole, with image and strokes in a guaranteed shared coordinate space.
