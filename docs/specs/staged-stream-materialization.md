# Staged Stream Materialization

## Problem Statement

UI/engine separation fixed swipe-time jank, but first activation of large unvisited streams still blocks the main thread during initial snapshot materialization.

Observed on device:
- `FlowLayout.prepare items=500 dt=1.3146`
- `MFCV.update snapshotApply changed=500 morph=0 dt=1.4086`
- End-to-end first-visit stall observed around `1.4s` to `2.7s`.

Root cause:
- First visit currently applies full history in one diffable snapshot.
- `UICollectionViewDiffableDataSource.apply` + layout preparation for hundreds of items is main-thread UIKit work.
- Debounce/settle gating moves *when* this cost happens, not *how much* work runs.

## Goal

Reduce first-visit activation stall by reducing first materialization size, while preserving correctness for unread state, anchors, and stream-switch ordering.

## Non-Goals

- No no-op apply suppression in this spec.
- No warm cache / LRU materialization cache in this spec.
- No rewrite of `MessageFlowLayout` algorithm.
- No change to UI/engine separation ownership model.

## Why Current Design Existed

Full-history apply kept chat semantics simple (single snapshot = full history available immediately) and avoided staged-state complexity. This spec intentionally trades some complexity for large first-visit latency reduction.

## Proposed Approach (Staged Apply Only)

### Stage model (two stages only)

1. **Tail stage**: apply recent tail window only.
2. **Full stage**: expand from tail window to full history once tail render is complete and queue is idle.

No intermediate stage.

### Initial tail window size (with math)

Use `N = 50` items for first stage.

Justification from current measurements:
- Measured `500 items -> 1.4s to 2.7s`.
- Linear approximation: `50 items ~= 140ms to 270ms` (10% of 500).
- `100 items` would be roughly `280ms to 540ms`, still too visible for first paint.

So the spec chooses 50 as the initial window to target materially lower first-frame stall.

### When staged apply is used

- Only for first activation of an unvisited stream when `messageCount > 50`.
- If `messageCount <= 50`, apply full snapshot directly.
- Revisits remain on existing path (already smooth in current observations).

## User-visible Behavior

### During swipe/intent
- Existing UI/engine behavior remains: immediate stream intent UI, spinner while engine activation is pending.

### First visit to a large stream
- Page appears with recent tail first (last 50).
- Spinner remains until tail stage is rendered.
- Full history appears afterward (single expansion stage).

### Revisits
- Behavior unchanged from current smooth revisit path.

## Mutation Seam Discipline

New staged state must have explicit single-write paths.

### Owned state

- `materializationStageBySessionKey: [String: Stage]`
- `windowBoundsBySessionKey: [String: WindowBounds]` (tail/full)
- `expansionLifecycleBySessionKey: [String: ExpansionState]`

### Single mutation seam

All staged-state mutations go through one method in `MessageFlowCollectionViewController`:
- `advanceMaterialization(sessionKey:event:) -> MaterializationPlan`

No direct writes outside this seam.

### Ordering guarantee

- All stage transitions and snapshot applies are serialized on MainActor through a single apply queue/dispatcher.
- Incoming-message events and expansion events both enter the same seam and are ordered FIFO by enqueue time.
- Epoch checks cancel stale work when stream intent changes.

## Edge Cases (Concrete Mechanisms)

### 1) Anchor preservation during prepend/full expansion

Mechanism:
- Before tail->full apply, capture anchor as `(anchorMessageId, anchorFrameMinY, contentOffsetY)` for top fully visible non-typing item.
- Apply full snapshot.
- After layout, resolve new `anchorMessageId` frame and set `contentOffset.y += (newMinY - oldMinY)` (clamped to content bounds).

This is explicit contentOffset compensation, not heuristic scrolling.

### 2) New messages arriving during expansion

Mechanism:
- New messages do not bypass staged seam.
- If expansion is pending/in-flight, append events are queued in the same serialized seam.
- Full-stage snapshot is built from authoritative message source at execution time, so it includes any messages that arrived during tail stage.
- Result: no dropped/duplicated IDs, deterministic order.

### 3) Unread marker outside tail window

Mechanism:
- Unread metadata remains in logical state even if marker item is not yet materialized in tail stage.
- UI shows unread count/state without requiring marker cell presence.
- On full-stage expansion, if marker becomes materialized, existing unread-anchor logic resolves and renders marker normally.
- Unread is never auto-cleared just because marker is outside tail window.

### 4) Programmatic selection

- Programmatic selection still commits engine immediately (existing invariant).
- If target stream is unvisited and `messageCount > 50`, it still uses tail->full staged materialization inside engine-active path.

## Interaction with UI/Engine Separation

No coupling change:
- UI intent: `uiSelectedSessionKey` remains instant.
- Engine activation: `engineActiveSessionKey` remains debounced (pager) / immediate (programmatic).
- Staged materialization starts only after engine-active commit for target stream.

## Acceptance Criteria

1. First activation of a stream with `messageCount > 50` renders with tail-window snapshot first (`N=50`).
2. Expansion path is exactly two stages: `tail -> full`.
3. Tail stage clears spinner on first rendered content; full-stage expansion can complete afterward.
4. Staged state has one write seam (`advanceMaterialization(sessionKey:event:)`) with no direct external mutation.
5. Expansion + incoming-message ordering is deterministic via single serialized seam.
6. Anchor compensation keeps viewport stable across full expansion (no visible jump).
7. Unread state remains correct when unread marker starts outside tail window and later becomes materialized.
8. No `UICollectionView` consistency/assertion regressions introduced.
9. UI/engine separation invariants remain unchanged.

## Files Touched (planned)

- `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`
  - Tail/full stage snapshot planning.
  - Staged state seam + serialized apply dispatcher.
  - Anchor compensation integration for expansion.

- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift` (only if needed)
  - Epoch wiring reuse for cancellation semantics (no ownership shift of UI/engine keys).

- `ios/Clawline/Clawline/Views/Chat/ChatView.swift` (optional)
  - Spinner clear trigger alignment with tail-stage completion if current hook requires explicit pulse.

## Rollout / Validation Notes

- Keep existing `[STREAM_SWITCH]` and `[KBTIMING]` instrumentation enabled during rollout.
- Validate at least:
  - Tail-stage apply duration vs prior full first-visit duration.
  - Time-to-first-visible-content on large streams.
  - Correctness for unread/anchor behavior during tail->full expansion.
