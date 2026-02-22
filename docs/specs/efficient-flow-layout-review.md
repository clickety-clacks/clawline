# Efficient Flow Layout Spec Review

**Date:** 2026-02-17
**Reviewer:** Dictation agent + Claude Opus cross-review
**Primary spec:** `/Users/mike/shared-workspace/clawline/specs/efficient-flow-layout.md`
**Related spec:** `/Users/mike/shared-workspace/clawline/specs/bubble-sizing-v2.md`

## Review Method
- Ran external review with Claude Opus focused on:
  1. Completeness
  2. Determinism
  3. Contradictions/gaps with current `MessageFlowLayout` and BubbleSizingV2 behavior
- Validated findings against current code paths in `MessageFlowCollectionView.swift` and `BubbleSizingV2.swift`.

## Findings

### Critical

1. Bottom-inset policy conflicts with BubbleSizingV2 correctness model
- `efficient-flow-layout.md` Section 6.1 says bottom inset changes should do zero layout recalc/reconfigure/cap recompute.
- BubbleSizingV2 cap formula currently depends on bottom inset (`singleLinkCap` and `screenAwareCap` branches), so this creates stale geometry for inset-sensitive bubbles.
- Coordination required: either explicitly accept temporary staleness for those bubble classes (with policy guardrails), or keep targeted recalc for inset-sensitive types.

2. Ownership model for measured sizes is unresolved and risks split-brain cache state
- Spec proposes layout-owned measured storage (`measuredHeights`, `frameOrigins`) while current controller already owns `sizeCache`, `lastMeasuredSizes`, and BubbleSizingV2 caches.
- Without a single owner decision, invalidation can diverge.
- Must resolve ownership in spec before implementation.

3. Incremental item-shift path is underspecified relative to diffable snapshot applies
- Current update pipeline uses diffable `dataSource.apply(snapshot)`; layout invalidation/rebuild can race or override incremental frame mutations.
- Spec needs an explicit sequencing contract for snapshot apply vs incremental shift operations.

### High

1. One-dimensional assumption is not guaranteed by current layout behavior
- Current `MessageFlowLayout.prepare()` performs horizontal packing and row wraps (`x`, `maxX`, `minimumInteritemSpacing`, row-height accumulation).
- The spec frames this as a strict 1D list; that is only valid if a stronger invariant is enforced (single-column placement / stable row membership).
- Without that invariant, a single height/width regime change can affect row packing beyond simple y-shift.

2. Measure-once claim conflicts with current fingerprint invalidation behavior
- Current fingerprint includes streaming-related mutable fields and triggers cache invalidation/reconfigure paths during updates.
- Spec should explicitly carve out mutable-content messages or refine keying rules.

3. O(n_tail) shift claim is incomplete for UIKit interaction cost
- Eliminates O(n) remeasurement, but still mutates many attributes and can trigger repeated UIKit queries.
- Spec should characterize gain as “no remeasure for unchanged items,” not “cheap overall,” and define expected worst-case behavior under heavy tail shifts.

### Medium

1. Inset-sensitive bubble coverage is incomplete in current targeted path
- Existing handler targets only `isSingleLinkPreviewBubble`; other screen-aware-capped types (tables/images/galleries/terminal sessions) can also be inset-sensitive.
- Spec notes this, but needs explicit decision on whether these classes join targeted recalc or intentionally tolerate stale heights.

2. Multi-item async updates require deterministic ordering rules
- Current batching structures are unordered sets; incremental delta application must be processed in stable index order.
- Spec should define ordering guarantees for concurrent async height updates.

3. Snap-to-pixel delta math needs stricter definition
- Spec calls out snap-to-pixel but does not mandate snapped delta computation (`snap(new) - snap(old)`) to prevent drift.

4. Scroll-anchor reuse needs explicit ordering contract
- Existing anchor compensation works today post-rebuild; incremental path should codify capture/apply/compensate sequence to avoid transient jumps.

5. Typing indicator / ephemeral items interaction not fully covered
- Frequent append/remove of non-message items can still trigger layout churn; spec should define whether these bypass incremental message-frame logic or use a dedicated path.

## Determinism Assessment

Determinism is not yet fully specified. Main risks:
- Unordered batching of async updates (Set iteration order)
- Snapshot-apply vs incremental-shift interleaving
- Ambiguous source of truth (layout-owned vs controller-owned measured sizes)

Required for deterministic behavior:
- Single mutation seam for layout state
- Ordered processing by stable index/ID
- Explicit transaction boundaries around diffable apply and incremental shifts

## BubbleSizingV2 Coordination Required

The two specs currently touch the same runtime decisions from different angles:
- `bubble-sizing-v2.md` defines sizing correctness and cap dependencies on geometry/insets.
- `efficient-flow-layout.md` defines update efficiency and attempts to suppress some recalculation triggers.

Coordination points to resolve explicitly:
1. Which bubble classes are geometry-sensitive at runtime (single-link + prefersScreenAware set), and which are truly measure-once.
2. Whether bottom-inset changes can skip recalculation for all classes, only insensitive classes, or only during active input windows.
3. Unified cache ownership/keying strategy across controller/layout/sizing layers.
4. Deterministic update ordering for async remeasure + diffable apply.

## Recommended Spec Updates Before Implementation

1. Add a mandatory invariant section defining when 1D offset-shift is valid (single-column/stable row membership conditions).
2. Resolve measured-size ownership (layout vs controller) and declare one source of truth.
3. Replace “no bottom-inset recalc” with a class-scoped policy (insensitive vs sensitive bubble types), or explicitly state accepted temporary staleness window and recovery trigger.
4. Add deterministic transaction model for diffable apply + incremental layout updates.
5. Define ordered multi-item delta application and snapped-delta math requirements.
