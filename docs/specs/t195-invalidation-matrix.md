# T195 — MessageFlowCollectionView Invalidation Matrix

**Generated:** 2026-03-28 by clawline-profiler agent (eezo)
**Source:** `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`

## Current vs Recommended Behavior

| Invalidation Path | Current Behavior | Recommended Behavior | Change? |
|---|---|---|---|
| Initial activation of a stream | Builds the active snapshot, often tail first and later full; layout prepares every item via `:2075` and `:5065`. | Keep. One place a broad pass is expected. | No |
| Single append, width/metrics unchanged | Incremental append fast path at `:5111`. Falls back to wider layout rebuild if it misses. | Keep current fast path. | No |
| Message content changed (messageChanged) | Marks id dirty, returns `.fullRebuild` at `:825`. Clears size state only for dirty ids, but runs full layout prepare over active snapshot at `:4942`. | Keep targeted size invalidation for changed ids. Prefer targeted relayout when measured delta is known and row packing unchanged. Full rebuild should be fallback, not default. | **Yes, medium risk** |
| Message removed | Clears cache only for removed ids at `:830`. Snapshot shape change drives layout rebuild. | Keep. Positions recomputed, remaining size caches stay valid. | No |
| Async preview/embed height changed | V2 batches changed ids, invalidates only those ids, schedules reconfigure at `:4738` and `:4914`. | Keep this targeted model. | No |
| Content width / measurement inputs changed | `updateLayout()` detects changed inputs, clears all size/V2 state via `.envChanged` at `:3452` and `:3466`. | Keep. Real global geometry invalidation. | No |
| Font scale changed | Triggers env invalidation and full remeasurement at `:1987`. | Keep. Typography changes affect wrapping globally. | No |
| Compactness changed | Feeds into metrics and `needsFullLayout` at `:2026`, flows into measurement-input invalidation. | Keep as full size invalidation. | No |
| Top/bottom inset or bounds shift (same width) | `updateLayout()` says sizes stay valid, schedules layout-only at `:3469`. | Keep. Layout-only is correct. | No |
| Session switch | `needsFullLayout` true when `previousSessionKey != sessionKey` at `:2026`. Per-stream caches scoped at `:157`. | Keep layout rebuild. Don't clear size caches for stream switch. | No |
| Tail → full materialization promotion | Snapshot window changes at `:2075`, layout rebuilds. | Keep. Not a reason to clear all size caches. | No |
| Offscreen session update | Early-return skips snapshot/apply/layout at `:2018`. | Keep. Correct and important. | No |
| **Dark/light appearance change** | **Calls `clearAllSizeState()` and sets `forceReconfigureAll = true` at `:1980`. Escalates display-only change into size invalidation.** | **Change to reconfigure-only. Keep geometry caches, refresh visible/materialized cells, avoid global remeasurement.** | **Yes, low risk** |

## Invalidation Hierarchy (Summary)

**Re-measure all** — only when global geometry inputs change:
- content width
- typography / font metrics  
- compactness / metrics fingerprint

**Re-measure changed items only** — when intrinsic content changes locally:
- message content changed
- preview/embed height finalized
- attachment-specific layout changed

**Layout rebuild only** — when positioning changed but intrinsic bubble size did not:
- insets
- stream switch
- tail/full materialization window change
- snapshot order changes with stable cached sizes

**Reconfigure only** — for pure appearance changes:
- dark/light mode
- color/chrome updates

## Proposed Fixes (Priority Order)

### Fix 1: Dark/light appearance → reconfigure-only (LOW RISK)
**File:** `MessageFlowCollectionView.swift:1980`
**Current:** `clearAllSizeState()` + `forceReconfigureAll = true`
**Proposed:** Remove `clearAllSizeState()`. Keep `forceReconfigureAll` (or equivalent reconfigure path) to refresh visible cell appearance without invalidating geometry caches.
**Rationale:** Dark/light mode changes colors, not geometry. Bubble widths, heights, wrapping — none of these change. Clearing all size state forces a full remeasure pass that produces identical results.

### Fix 2: messageChanged → targeted relayout (MEDIUM RISK)
**File:** `MessageFlowCollectionView.swift:825`
**Current:** Returns `.fullRebuild` for any message content change.
**Proposed:** Preserve dirty-id cache clearing. Route through existing targeted height-delta path when width bucket and row packing are unchanged. Use `.fullRebuild` as fallback only.
**Rationale:** When a single message's content changes and its new height is known, the only downstream effect is shifting items below it. Full layout prepare over the entire snapshot is unnecessary if the width bucket hasn't changed and row packing is stable.

## Line References

All references are to `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift`:
- `:157` — per-stream size cache scoping
- `:825` — messageChanged → `.fullRebuild`
- `:830` — message removed cache clearing
- `:1980` — appearance change `clearAllSizeState()`
- `:1987` — font scale env invalidation
- `:2018` — offscreen session early-return
- `:2026` — `needsFullLayout` on session switch
- `:2075` — snapshot build / tail-to-full
- `:3452` / `:3466` — measurement input change detection
- `:3469` — inset change layout-only path
- `:4738` — V2 preview height batching
- `:4914` — V2 reconfigure scheduling
- `:4942` — full layout prepare over active snapshot
- `:5065` — layout prepare entry
- `:5111` — append fast path
