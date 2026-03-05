# Surf Ace Dual-Channel Redesign Summary

Date: 2026-03-04
Source spec updated: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`

## What was changed

I rewrote the Section 13/14 model from frame-queue-only to a **dual-channel design**:

1. **Channel A (Live dirty):** near-real-time deltas for the currently active frame while annotation is in progress.
2. **Channel B (Closed frame queue):** immutable finalized frames for guaranteed context-preserved delivery.

This is explicitly additive: capture frames do not replace dirty updates.

## Core rule updates now encoded in spec

- Frames are keyed by **context**, not annotation session.
- Re-entering annotation mode in the same context appends to the same context frame.
- Scroll alone does not create/switch frame context.
- Navigation/content change alone does not create a frame.
- Frame context switch finalization occurs when annotation starts in a new context.
- Annotation mode lock UX is preserved (no scroll / no link following while active; exit via Done/toggle).

## Read semantics and anti-dup

`surf_ace_read` now defines read priority:

- return `liveFrame` first (newest/live), then
- return closed `frames[]` batch (FIFO).

Closed frames remain deliverable even if CLU already consumed corresponding live dirty updates. Dedupe guidance is explicit: use stable `strokeId` per `frameId`/`contextKey`.

## Batching policy retained

Closed frame reads stay bounded by:

- max 5 frames per read, and
- ~4 MB pixel budget cap.

`pendingFrames` indicates queue remainder.

## Tool-surface migration

No new mandatory read tool was introduced.

- `surf_ace_read` response shape was extended (adds `liveFrame`, `liveDirtyStrokeIds`, `liveSeq`).
- Existing `frames[]` consumers continue working.
- `surf_ace_read_buffer` remains deprecated.

## Decision Required (left unresolved intentionally)

Added Appendix **A.8 Decision Required — Frame Flush Trigger When Context Never Changes** with options:

1. Explicit user finalization action,
2. Idle-timeout finalization,
3. Max-frame-size rollover.

Each option includes implications and tradeoffs. The spec intentionally leaves this unresolved pending Flynn/product decision.

## Other consistency fixes

- Updated §6.10 language so Done exits annotation mode but does not automatically imply immediate frame finalization.
- Updated §14.4 alert routing text to dual-channel unread-activity semantics.
- Updated appendix notes that previously assumed one frame per annotation session.
