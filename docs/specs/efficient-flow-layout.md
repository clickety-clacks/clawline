# Efficient Flow Layout for Bubble Height Changes

**Status:** Draft
**Author:** CLU + dictation agent analysis
**Date:** 2026-02-16

---

## 1. Problem Statement

`MessageFlowLayout.prepare()` rebuilds all cached layout attributes on any invalidation. Both `invalidateLayout()` and `invalidateLayout(with:)` set a global `needsRebuild = true` flag. When `prepare()` runs, it iterates every item (`0..<itemCount`), calls `sizeForItemAt` for each, and rebuilds all frames from scratch.

This means a single bubble height change (e.g., a link preview finishing its load) triggers O(n) remeasurement across the entire message history. With 500 messages, this produces ~950ms main-thread stalls on iPhone, blocking gesture recognition and causing interaction failures during dictation and typing.

## 2. Key Insight

Chat bubble layout is effectively a one-dimensional vertical list:

- **Width is fixed.** All bubbles (including single-link previews at full width) have stable horizontal position and width for a given layout regime.
- **Height changes are local.** When one bubble's height changes, no other bubble needs remeasuring.
- **The only downstream effect is vertical position.** Everything below the changed bubble shifts by the height delta.

Therefore, a single-item height change should be O(n) addition (shift y-positions) rather than O(n) remeasurement (re-call `sizeForItemAt` for every item). With a prefix-offset structure, it can be O(1).

### 2.1 Measure-Once Principle

The vast majority of bubbles (plain text, markdown, system messages, etc.) have heights that are **stable after first measurement**. Their content does not change, and their height is not affected by external factors like inset or container changes. Once measured, their cached height is permanent — `sizeForItemAt` should never be called for them again unless their content changes.

Only a small subset of bubble types have **externally-dependent heights** — those using viewport-aware height caps (`isSingleLinkPreview`, `prefersScreenAwareHeightCap`): link previews, tables, images, galleries, terminal sessions. These are the only items that may need remeasurement when external geometry changes.

This creates a two-layer optimization:

1. **Measure-once bubbles:** Measured on first display, cached permanently. Skipped entirely on all subsequent layout passes.
2. **Capped bubbles:** May need remeasurement on relevant triggers (rotation, compactness flip). When they do remeasure, use the y-shift path (Section 5.3) instead of rebuilding the entire list — only the changed item is remeasured, and everything below it shifts by the height delta.

### 2.2 Capped Bubble Recalculation Timing

Capped bubbles only need their height recalculated when two conditions are both true:
1. The bubble is **visible on screen**.
2. **Scrolling has stopped.**

There is no reason to recalculate a capped bubble's height while the user is actively scrolling, while the bubble is offscreen, or while the input bar is animating. The recalculation can wait until the viewport settles.

### 2.3 Steady-State Behavior

In steady state (no rotation, no compactness flip), the only time a capped bubble remeasures is when it scrolls into view and its cached height was computed against a different geometry than what is current. This means:

- Scrolling down through already-measured content: **zero remeasurement** (all heights cached).
- Scrolling up past a capped bubble whose geometry context has changed (e.g., keyboard appeared since it was last visible): **remeasure that one bubble + y-shift below it**.
- Typing, dictating, input bar growing: **zero layout work** beyond content inset adjustment.
- New message arriving: **measure the new bubble once**, append to layout. No existing bubbles touched.

The expensive full-list rebuild becomes a rare event triggered only by structural geometry changes (rotation, size class), not by routine interaction.

## 3. Current Architecture

### 3.1 Layout Storage

Layout attributes are cached in `cachedAttributes: [IndexPath: UICollectionViewLayoutAttributes]` plus a `cachedContentSize`. Item order is implicit by index path. There is no persistent per-item measured size store owned by the layout — size lookup routes through the delegate/cache on each rebuild.

### 3.2 Invalidation Model

All invalidation is binary: `needsRebuild = true` → full rebuild in `prepare()`. There is no distinction between "one item changed height" and "everything changed." Item-scoped invalidation does not exist.

### 3.3 Height Cap System

Bubble height caps are computed by `BubbleSizingV2.BubbleHeightPolicy.resolve(...)` using:

**Formula:** `cap = containerHeight - topInset - bottomInset - (padding * 2)`

**Inputs:**
- `containerHeight` — collection view bounds height
- `topInset` — safe area top (from ChatView geometry)
- `bottomInset` — keyboard + input bar height (from ChatLayoutCoordinator)
- `truncationBottomInset` — separate inset for truncation-aware content
- `containerPadding` — from `ChatFlowTheme.Metrics`

**Content-type selectors (determine which cap branch):**
- `isSingleLinkPreview` — single-link messages
- `prefersScreenAwareHeightCap` — tables (single), images, galleries, terminal sessions
- `allowsOuterScroll` — size class dependent

### 3.4 Recalculation Triggers

Height cap recalculation currently fires on six distinct triggers:

1. **Bottom inset change** — `ChatLayoutCoordinator` calls `setBottomInset()` → `handleBottomInsetHeightCapChange()`. Fires on keyboard appear/dismiss, input bar height growth (multiline typing, dictation bar). Currently only targets single-link-preview bubbles for reconfigure.

2. **Top inset change** — safe area top changes passed from `ChatView` into `update()`. Triggers `needsFullLayout` → full rebuild via `updateLayout()`.

3. **Container height change** — `viewDidLayoutSubviews()` detects bounds change → sets `forceReconfigureAll = true` → full rebuild.

4. **Compactness change** — `isCompact` flip → `needsFullLayout` → full rebuild via `updateLayout()`.

5. **New cell creation / scroll** — per-cell sizing during `sizeForItemAt` as cells enter visibility. Policy recomputed per cell (usually same inputs = no effective change).

6. **Async content update** — link preview height finalization via `onRequestLayout` → `handleCellRequestedLayout` → `applyMeasuredSize`. Remeasures the item, then calls `flowLayout.invalidateLayout()` triggering full rebuild.

7. **Dark mode toggle** — `isDark` change clears caches and forces reconfigure. Currently triggers full layout rebuild even though only colors change.

8. **Session switch** — `previousSessionKey != sessionKey` is part of full-layout decision. Currently triggers full rebuild even though it's a data change, not geometry.

9. **Dynamic text size** — `preferredContentSizeCategory` change affects metrics fingerprint, invalidates V2 cache keys. This is a legitimate full-rebuild trigger (typography regime change, like compactness).

### 3.5 Targeted Update Gap

`handleBottomInsetHeightCapChange()` intends to be targeted (only single-link-preview bubbles), but it still calls `flowLayout.invalidateLayout()` at the end, which triggers global rebuild. The "targeted" scope is only in which items get cache-cleared and reconfigured — the layout pass itself is still O(n).

Additionally, the targeted handler misses other inset-sensitive content types: tables, images, galleries, and terminal sessions (anything where `prefersScreenAwareTruncationHeight` returns true).

### 3.6 Ripple Behavior

When a single bubble is reconfigured/remeasured:
- `scheduleReconfigure(for:)` batches IDs and applies via `dataSource.apply(snapshot)` — this is cell-scoped.
- But layout invalidation sets global `needsRebuild`, and `prepare()` remeasures all items.
- Scroll position compensation exists (`captureBubbleSizingV2ViewportAnchor` / `scheduleBubbleSizingV2ViewportAnchorCompensation`) but runs after the full rebuild, not instead of it.

## 4. UX Analysis: When Stale Heights Are Tolerable

| Trigger | Frequency | Durable? | User Notices Stale? | Recommended Action |
|---------|-----------|----------|--------------------|--------------------|
| Bottom inset (keyboard, input bar) | High | No — ephemeral | No — user focused on input | **No layout recalc** |
| Top inset (safe area) | Rare | Yes | Briefly tolerable | **Targeted visible cells** |
| Container height (rotation) | Rare | Yes | Yes — visibly wrong | **Full rebuild** |
| Compactness (size class) | Rare | Yes | Yes — regime change | **Full rebuild** |
| Scroll / new cells | Continuous | N/A | No — offscreen | **Nothing** (lazy sizing) |
| Async content (preview load) | Per-message | Yes (local) | Yes — that one bubble | **Remeasure one + y-shift** |
| Dark mode toggle | Rare | Yes | No — colors only | **Reconfigure visuals, no sizing** |
| Session switch | Per-switch | Yes | N/A — new data | **Snapshot apply, no layout rebuild** |
| Dynamic text size | Rare | Yes | Yes — typography change | **Full rebuild** |

## 5. Proposed Design

### 5.1 Invalidation Classes

Replace the single `needsRebuild` flag with three invalidation modes:

```swift
enum LayoutInvalidation {
    case fullRebuild                           // rotation, compactness, structural
    case itemHeightChange(index: Int, delta: CGFloat)  // single bubble resize
    case rangeShift(fromIndex: Int, delta: CGFloat)     // bulk y-offset shift
}
```

### 5.2 Persistent Measured Size Store

The layout should own an authoritative measured size per item, independent of the delegate cache:

```swift
var measuredHeights: [CGFloat]    // indexed by item position
var frameOrigins: [CGPoint]       // indexed by item position
```

This allows the layout to distinguish "I have a valid cached measurement" from "I need to ask the delegate."

### 5.3 Fast Path: Single-Item Height Change

When item at index `i` changes height:

1. Compute `delta = newHeight - oldHeight`.
2. Update `measuredHeights[i]` and the frame for item `i`.
3. For all items `j > i`: add `delta` to `frameOrigins[j].y`.
4. Update `cachedContentSize.height += delta`.
5. Skip `sizeForItemAt` for all items except `i`.

**Complexity:** O(n_tail) additions, zero remeasurement of unchanged items.

### 5.4 Optional O(1) Path: Cumulative Offset

For even faster handling of frequent small changes (e.g., during active dictation):

- Maintain a cumulative offset value applied to all items beyond a threshold index.
- Materialize concrete frame positions lazily only for visible items.
- Defer full offset application to idle time.

This is an optional future optimization. The O(n_tail) shift path is sufficient for the current performance target.

### 5.5 Scroll Anchor Preservation

Reuse existing viewport-anchor compensation:
1. `captureBubbleSizingV2ViewportAnchor()` before mutation.
2. Apply shifted layout.
3. `scheduleBubbleSizingV2ViewportAnchorCompensation()` corrects content offset.

No changes needed to the anchor mechanism itself.

## 6. Trigger-Specific Behavior

### 6.1 Bottom Inset Change
**Action:** No immediate layout recalculation. Apply content inset and scroll offset adjustments only. Do not invalidate layout, do not reconfigure bubbles, do not recompute height caps during the change.

**Deferred recalculation:** When scrolling stops and the viewport settles, check visible capped bubbles against current geometry. If their cached height was computed against a different bottom inset, remeasure those specific bubbles and y-shift below them. This is the same mechanism described in Section 2.2.

**Rationale:** The change is ephemeral and high-frequency. Immediate recalculation produces ~950ms stalls that harm interaction. Deferring to idle lets the user finish typing/dictating without jank, then corrects any stale capped bubble heights when it's safe.

### 6.2 Top Inset Change
**Action:** Deferred targeted update. When scrolling stops and viewport settles, identify visible capped cells (`prefersScreenAwareHeightCap` or `isSingleLinkPreview`). Remeasure only those. Apply y-shift to items below the highest affected item.

**Rationale:** Rare event, durable change, but small delta. Most conversations have few or zero capped bubbles visible. Same timing rule as bottom inset (Section 2.2): recalculate only when visible and scrolling has stopped.

### 6.3 Container Height Change (Rotation / Resize / Split-View)
**Action:** Full rebuild.

**Rationale:** Width may change (rotation, split-view/multitasking window resize, external display changes), which invalidates horizontal layout assumptions. Any change to the width regime requires full remeasurement. This is the one case where full remeasurement is justified.

### 6.4 Compactness Flip
**Action:** Full rebuild.

**Rationale:** Typography, spacing, and padding regime change affects every bubble's measurement.

### 6.5 New Cell Creation / Scroll
**Action:** Nothing global. Per-cell lazy sizing on demand as cells enter visibility.

**Rationale:** Continuous event during interaction. Global work here directly degrades scroll performance.

### 6.6 Async Content Update (Link Preview Load)
**Action:** Remeasure the single affected item. Apply y-shift to all items below it.

**Rationale:** Durable but local. Only one bubble changed. This is the primary use case for the O(n_tail) shift path.

### 6.7 Dark Mode Toggle
**Action:** Reconfigure visible cells for color changes only. Zero sizing or layout work.

**Rationale:** Dark mode changes colors, not dimensions. No bubble needs remeasuring. The current code clears caches and forces reconfigure — that is overly aggressive and should not trigger layout rebuild.

### 6.8 Session Switch
**Action:** Apply new data via diffable snapshot. No layout-regime rebuild.

**Rationale:** Session switch loads different message content, which is handled by the normal snapshot apply path. New messages get measured as they appear. The session change itself is not a geometry or sizing event.

### 6.9 Width Stability Invariant
Bubble widths are stable after initial measurement. The y-shift optimization depends on this invariant.

**Why this holds:** `.short` bubbles (≤3 words) use content-fit width but cannot contain link previews or media — those always produce `.long` classification. The only async width updates (`applyMeasuredSize` width path) are from link preview loads, which only occur in large bubbles that already use fixed max width. Therefore no bubble type changes width after initial measurement in practice.

## 7. Edge Cases

### 7.1 Multiple Simultaneous Height Changes
When multiple items change height in one pass (e.g., batch of link previews loading):
- Sort changed indices ascending.
- Process in a single forward pass, accumulating deltas.
- Each item's shift includes the accumulated delta from all preceding changes.
- Avoids repeated tail scans.

### 7.2 Insertions and Deletions

**Single-message append (common path):** New message arrives at the end of the list. Measure the new bubble once, append its frame to the layout, update content size. No existing bubbles are touched. This must be a fast path — it is the most frequent mutation in normal use.

**Complex mixed batches (rare path):** Multiple insertions, deletions, or moves that change item ordering. Fall back to full rebuild. This is acceptable because these are rare structural changes (e.g., message deletion, bulk history load).

### 7.3 Snap-to-Pixel
Maintain existing rounding behavior. Delta math must use snapped heights to prevent subpixel drift over many accumulated shifts.

### 7.4 Content Size and Scroll Limits
After any shift operation, update `cachedContentSize.height` by the net delta. Clamp and correct `contentOffset` as needed if the shift affects scroll bounds.

## 8. Acceptance Criteria

1. Single link preview height finalization on a 500-message conversation does not call `sizeForItemAt` for any item other than the changed one.
2. Bottom inset changes during active dictation produce zero layout invalidations.
3. No visual overlaps or gaps after targeted height changes.
4. Scroll anchor remains stable during targeted updates (no visible jumps).
5. Full rebuild still fires for rotation and compactness flip.
6. Main-thread stall during dictation on iPhone is eliminated (currently ~950ms).
7. No direct cache mutation (`sizeCache`, `lastMeasuredSizes`, V2 caches) exists outside the designated seam methods. Verified by: `grep -n 'sizeCache\[|sizeCache\.remove|lastMeasuredSizes\[|lastMeasuredSizes\.remove|bubbleSizingV2MeasurementCache|bubbleSizingV2KeysByMessageId|bubbleSizingV2LinkPreviewHeightCache|bubbleSizingV2LinkPreviewStateVersion' MessageFlowCollectionView.swift` returns only hits inside seam methods.
8. Single-message append does not trigger full layout rebuild or remeasurement of existing items.

## 9. Implementation Approach

### 9.1 Cache Mutation Seam (Step 1)

The current codebase has six separate caches storing bubble size state (`sizeCache`, `lastMeasuredSizes`, BubbleSizingV2 measurement cache, BubbleSizingV2 key/index maps, link preview height cache, layout `cachedAttributes`). Multiple call sites write directly to these caches. This is a violation of single-mutation-seam discipline and the source of defensive full-rebuild invalidation.

**Seam scope:** The controller seam covers all sizing/measurement caches owned by the controller (listed in Section 9.2). Layout-owned state (`cachedAttributes`, `cachedContentSize`, `needsRebuild`, layout signature) is explicitly out of scope — that state belongs to the layout layer and is driven by the controller's invalidation decisions, not mutated directly by sizing consumers.

`dirtySizeIds` and deferred invalidation scheduling are part of the controller's invalidation flow and should be routed through the seam's `invalidateFor(reason)` path rather than managed as separate ad-hoc state.

**Step 1 is not a new subsystem.** It is a lightweight seam inside the existing `MessageFlowCollectionViewController`:

- Add a small private method group that all cache mutations go through:
  - `readSizeState(messageId, env)`
  - `writeMeasuredSize(messageId, measurement)`
  - `recordAsyncPreview(messageId, key, height)`
  - `invalidateFor(reason)`
- Route all existing direct cache writes through these methods. No behavior change.
- Mark all cache dictionaries as implementation details behind this seam.
- Add a comment-level invariant: "All bubble cache mutations go through this seam."

**Seam method contracts:**
- `readSizeState(messageId, env) -> CachedMeasurement?` — returns cached measurement if valid for the given environment, nil if stale or missing.
- `writeMeasuredSize(messageId, measurement) -> HeightDelta?` — stores measurement, returns height delta if it changed (nil if unchanged or within epsilon threshold).
- `recordAsyncPreview(messageId, key, height) -> HeightDelta?` — updates subcomponent height, returns delta if effective bubble height changed.
- `invalidateFor(reason: InvalidationReason) -> InvalidationPlan` — reason is one of: `.messageChanged(id)`, `.messagesRemoved([id])`, `.envChanged`, `.compactnessChanged`, `.containerSizeChanged`. Returns one of: `.none`, `.reconfigureItems([id])`, `.remeasureAndShift([(id, delta)])`, `.fullRebuild`.

**Why this is the right first step (per architecture principle #1 — pattern propagation):** Future agents will see one sanctioned write path and replicate it, instead of adding another ad-hoc cache and patching invalidation nearby.

**Why this is right-weight (per architecture principle #2):** No new types, no new files, no ceremony. Just a seam. Extract to a dedicated `BubbleLayoutStateStore` type only when there is a second consumer or clear pressure to do so.

### 9.2 Migration Checklist

All known cache families and their current writers must be routed through the seam before any optimization work begins.

| Cache | Current Writers | Routed? | Verification |
|-------|----------------|---------|-------------|
| `sizeCache` | `sizeForItemAt`, `applyMeasuredSize`, `updateLayout`, `handleBottomInsetHeightCapChange` | ☐ | grep for direct `sizeCache[` / `sizeCache.removeValue` outside seam |
| `lastMeasuredSizes` | `applyMeasuredSize`, `updateLayout` | ☐ | grep for direct `lastMeasuredSizes[` outside seam |
| `bubbleSizingV2MeasurementCache` | V2 measure path, `invalidateBubbleSizingV2Cache` | ☐ | grep for direct cache access outside seam |
| `bubbleSizingV2KeysByMessageId` | V2 measure path, invalidation | ☐ | grep for direct map access outside seam |
| `bubbleSizingV2LinkPreviewHeightCache` | async preview callback | ☐ | grep for direct cache access outside seam |
| `bubbleSizingV2LinkPreviewStateVersionByMessageId` | async preview callback | ☐ | grep for direct map access outside seam |

### 9.3 Sequencing

Steps are **hard-gated** — each step must be complete and verified before the next begins.

1. **Establish mutation seam** — private method group, route all writes, zero behavior change. Gate: all rows in migration checklist (9.2) marked ☑.
2. **Verify seam integrity** — confirm no direct cache mutation exists outside seam methods. Gate: grep/lint verification passes, seam integrity test added.
3. **Move invalidation decisions into the seam** — seam returns invalidation plan instead of callers deciding. Gate: behavior parity confirmed (no visual or functional regressions).
4. **Add y-shift layout path** — the algorithmic optimization from Section 5.3. Gate: seam steps 1-3 are complete.
5. **Optionally extract to dedicated type** — only if the seam outgrows its home.

**Hard rule:** No optimization work (step 4) may begin until the mutation seam is fully consolidated and verified (steps 1-2 complete). Skipping ahead recreates the split-mutation problem this spec exists to fix.

Each step ships independently. Ownership consolidation is separated from algorithm change to make regressions bisectable.

## 10. Open Questions

1. Should the persistent measured-height store live inside `MessageFlowLayout` or be owned by the controller and passed to the layout?
2. For mixed insert/delete/reconfigure batches from diffable data source, what is the right threshold to fall back to full rebuild vs. attempting incremental update?
3. Is the O(1) cumulative-offset mode worth the complexity now, or should the first implementation ship with O(n_tail) shift only?
4. ~~Should bottom inset changes defer height-cap-sensitive updates to an idle callback rather than skipping them entirely?~~ **Resolved:** Yes — defer to idle. No immediate recalc; check visible capped bubbles when scrolling stops and viewport settles (Section 6.1).
