# T183 Inset Reunification — Refactor Spec

## Problem Statement

Two related bugs stem from re-fragmented inset/scroll coordination:

**T183 — Bottom inset race condition (#152).**
The bottom content inset intermittently miscalculates when the keyboard appears or the input bar resizes.
Two failure modes: (a) too-little inset — bottom message stuck behind keyboard; (b) too-much inset — bottom message hovers above keyboard with visible gap. Works correctly most of the time, confirming race timing.

**T181 — Stream switch scroll bounce.**
When switching between streams, scroll position first restores to the old position then immediately forces a scroll-to-bottom. Root cause: scroll restore reads `collectionView.contentInset.bottom` directly, which is stale when a coordinator animation is in-flight.

## Root Cause Analysis

Commit 6384052e1f ("Unify chat inset state") established a clean single-writer model via `ChatLayoutCoordinator`. Seven subsequent commits re-introduced multi-path writes and async gaps. Four race conditions result:

**RC1 (both inset failure modes):** Bar height and keyboard height are delivered via independent async paths. Bar height arrives via `setOnBarHeightChange` callback → `updateBarHeight()` → `markInputsChanged()` (which schedules a `Task { @MainActor }` fallback). Keyboard height arrives via `@State` onChange in SwiftUI. When keyboard notification fires before the bar has a stable measurement, `currentInsetBarHeight()` returns `MessageInputBarMetrics.minInputBarHeight` (44pt) instead of the real height (~88pt+), producing an underfilled inset. The correction arrives later via a separate `applyTransitionIfPossible` pass, but the generation guard (RC2) can silently drop it.

**RC2 (too-much-inset):** `applyTransitionIfPossible` has three interacting mechanisms: `isApplyingTransition` flag, `pendingInputs` queue, and `generation` counter. When an animation is in-flight and new inputs arrive:
1. Inputs are queued in `pendingInputs` (line 202)
2. A reentrant async dispatch is scheduled (lines 203-205)
3. On animation completion, the `generation == currentGeneration` guard (line 272) can fail if the reentrant dispatch already incremented generation — causing the completion handler to skip clearing `isApplyingTransition` and skip processing `pendingInputs`
4. The reentrant path also processes `pendingInputs` via `DispatchQueue.main.async` (lines 277-280), adding another async hop

This creates a window where `lastAppliedInset` is updated eagerly (line 242) but the actual UIKit inset application is silently dropped, leaving UIKit stuck at the old value.

**RC3 (scroll bounce):** `attemptRestoreScrollIfNeeded` (MessageFlowCollectionView.swift:2715) reads `collectionView.contentInset.bottom` to compute `maxY`. During a coordinator animation, the model layer (`contentInset.bottom`) is the **presentation** value, not the target. `currentBottomInset` (line 1138) already holds the coordinator's target value but is not used. When restore fires mid-animation, `maxY` is wrong → scroll offset is wrong → immediate correction creates visible bounce.

**RC4 (secondary):** `willEnterForeground` and `didBecomeActive` each call `refreshFromLayoutGuide()` twice (sync + async), totaling 4 calls. Each call triggers `onChange` which feeds the coordinator. The `pendingFallback` gate in `markInputsChanged` partially coalesces, but the 4 `refreshFromLayoutGuide` calls themselves each push a new keyboard height through the SwiftUI binding, causing unnecessary transition churn.

## Changes

### Change 1: Remove generation guard; process pending synchronously

**What:** In `applyTransitionIfPossible`, remove the `generation` counter, the `currentGeneration` capture, and the completion guard that checks `self.generation == currentGeneration`. In the completion block, always clear `isApplyingTransition` and process pending inputs. Process pending inputs **synchronously** (remove the `DispatchQueue.main.async` wrapper around lines 277-280). The `.beginFromCurrentState` animation option (already present at line 267) handles interruption correctly — if a new animation starts while the old one is in flight, UIKit blends from the current presentation state.

Also remove the reentrant async dispatch at lines 203-205. Instead, just queue the inputs; the completion handler will pick them up.

**Where:** `ChatLayoutCoordinator.swift`, `applyTransitionIfPossible()` method (lines 191-288). Properties to remove: `generation` (line 126).

**Why:** Eliminates RC2. The generation guard was designed to prevent stale completions, but `.beginFromCurrentState` already handles that at the UIKit level. The generation counter creates a worse problem: silently dropping corrections.

**Risk:** Low. `.beginFromCurrentState` is the standard UIKit pattern for interruptible animations. Removing the generation guard means every completion runs — but since we also remove the async pending dispatch and process synchronously, each completion either finds no pending work (fast no-op) or immediately applies the latest state.

### Change 2: Make `updateBarHeight` call `applyTransitionIfPossible` directly

**What:** Change `updateBarHeight` to call `applyTransitionIfPossible(reason: "barHeight")` directly instead of `markInputsChanged()`. This ensures bar height and the current keyboard state are combined atomically in a single transition pass, rather than going through the fallback path which adds a `Task { @MainActor }` hop.

**Where:** `ChatLayoutCoordinator.swift`, `updateBarHeight()` method (line 378). Change `markInputsChanged()` to `applyTransitionIfPossible(reason: "barHeight")`.

**Why:** Eliminates the async gap in RC1. Bar height changes are already on `@MainActor` (verified by `dispatchPrecondition` at line 364). Calling `applyTransitionIfPossible` directly means the bar height update and the inset recalculation happen in the same runloop tick.

**Risk:** Low. `applyTransitionIfPossible` already handles the case where `latestInputs` or `latestMetrics` is nil (line 195-199). If called before keyboard state is available, it queues as `pendingInputs` and returns — same as today's fallback path but without the extra async hop.

### Change 3: Stabilize `hasStableBarHeight` on first non-zero measurement

**What:** In `currentInsetBarHeight()`, set `hasStableBarHeight = true` immediately when the first non-zero `barHeightCache` is observed (the `barHeightCandidate <= 0.5` branch at line 384-389). Currently this already happens — the code sets it at line 389. Verify this is actually the behavior and that the confirmation-tick path (lines 390-393) doesn't override it back to false in a subsequent call.

After review: the code at line 389 already sets `hasStableBarHeight = true` on first non-zero. The confirmation-tick path at lines 390-393 only sets it true (never false). **No code change needed here** — the current implementation is correct.

However, there is a coupling issue: `updateBarHeight` only calls `markInputsChanged()` (soon to be `applyTransitionIfPossible`), which calls `currentInsetBarHeight` — which is the function that sets `hasStableBarHeight`. But `currentInsetBarHeight` is only called from `applyTransitionIfPossible` when `latestInputs` and `latestMetrics` are available. If bar height arrives before SwiftUI has delivered inputs, `hasStableBarHeight` won't be set even though we have a valid measurement.

**What (revised):** Move the `hasStableBarHeight = true` flag set into `updateBarHeight()` itself, gated on the first non-zero measurement: if `!hasStableBarHeight && sanitizedHeight > 0.5`, set `hasStableBarHeight = true`. Keep the existing logic in `currentInsetBarHeight` as a fallback.

**Where:** `ChatLayoutCoordinator.swift`, `updateBarHeight()` (lines 363-379), add after line 366:
```swift
if !hasStableBarHeight && sanitizedHeight > 0.5 {
    hasStableBarHeight = true
}
```

**Why:** Ensures stable-bar-height flag is set as soon as a real measurement arrives, regardless of whether a full transition pass has run yet. This prevents the bootstrap height (44pt) from being used in a subsequent keyboard transition that arrives after bar measurement but before the fallback fires.

**Risk:** **HIGHEST RISK CHANGE.** The bar height stabilization has been carefully tuned. Setting it too eagerly could accept a transient intermediate height during initial layout. The existing `barHeightCandidate` double-confirmation path exists precisely to filter layout transients. However, the `setOnBarHeightChange` callback already has a `> 1.0` delta filter and a half-point snap (ChatView.swift:2144-2145), which should prevent transient flicker from reaching `updateBarHeight`. **Must test on device:** verify that during cold launch, the first non-zero height is the correct steady-state height, not a transient layout pass.

### Change 4: Coalesce foreground/active refreshes

**What:** Replace the 4-call pattern (2 in `willEnterForeground` + 2 in `didBecomeActive`) with a debounced approach. Both methods should set a `needsForegroundRefresh` flag and schedule a single `DispatchQueue.main.async` that calls `refreshFromLayoutGuide()` once. The sync calls can be removed because `refreshFromLayoutGuide` already handles the no-window case by retrying async.

Implementation:
```swift
private var needsForegroundRefresh = false

@objc private func willEnterForeground(_ notification: Notification) {
    scheduleForegroundRefresh()
}

@objc private func didBecomeActive(_ notification: Notification) {
    scheduleForegroundRefresh()
}

private func scheduleForegroundRefresh() {
    guard !needsForegroundRefresh else { return }
    needsForegroundRefresh = true
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.needsForegroundRefresh = false
        self.refreshFromLayoutGuide()
    }
}
```

**Where:** `ChatView.swift`, the `KeyboardTrackingView` inner class — methods at lines 2017-2033, plus new `scheduleForegroundRefresh()` and `needsForegroundRefresh` property.

**Why:** Eliminates RC4. The 4 calls fire in rapid succession during foreground entry. Each triggers `onChange` → coordinator → potential animation. Coalescing to 1 async call is sufficient: `refreshFromLayoutGuide()` reads the current layout guide frame, which is stable by the time the async block runs. The existing no-window retry (lines 1979-1985) handles the edge case where the view isn't attached yet.

**Risk:** Low. The original two-call pattern (sync + async) was added because the sync call can see a stale layout guide frame. The async-only approach lets Auto Layout settle before sampling. If foreground entry produces a momentary wrong inset, the coordinator's `markInputsChanged` fallback path will correct it on the next tick.

### Change 5: Use `currentBottomInset` for scroll restore calculations

**What:** In `attemptRestoreScrollIfNeeded`, replace `collectionView.contentInset.bottom` with `currentBottomInset` for the `maxY` calculation. Do the same in `distanceFromBottomClamped`, `liveScrollSnapshotIfAvailable`, and `persistScrollStateNow`.

Specifically, replace the pattern:
```swift
let contentInset = collectionView.contentInset
// ...
let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + contentInset.bottom)
```
with:
```swift
let topInset = collectionView.contentInset.top
// ...
let maxY = max(-topInset, collectionView.contentSize.height - collectionView.bounds.height + currentBottomInset)
```

**Where:** `MessageFlowCollectionView.swift`:
- `attemptRestoreScrollIfNeeded` (lines 2715-2717)
- `distanceFromBottomClamped` (lines 2240-2242)
- `liveScrollSnapshotIfAvailable` (lines 2512-2514)
- `persistScrollStateNow` (lines 2565-2567)

**Why:** Eliminates RC3. `currentBottomInset` is set eagerly by `setBottomInset` (line 1149) before the animation block runs, so it always reflects the coordinator's intended target. `collectionView.contentInset.bottom` during an animation reflects the in-flight presentation value, which can be anywhere between old and new.

**Risk:** Low. `currentBottomInset` is already the coordinator's truth — it's set at the top of `setBottomInset` before any animation or guard. The only place `currentBottomInset` is read today is at line 3094 (re-apply on layout setup) and line 3527 (diagnostic logging). Using it for scroll math is the natural extension.

### Change 6: Remove duplicate `setDesiredBottomGap` call in `updateUIView`

**What:** Remove the first `setDesiredBottomGap` call at line 2128 in `KeyboardPinnedContainer.updateUIView()`. Keep the second one at line 2139 (which has the explanatory comment about seeding launch layout). The first call is immediately overwritten by the second, and the coordinator's `applyTransitionIfPossible` (called at line 2156) is the authoritative path for gap changes.

**Where:** `ChatView.swift`, `KeyboardPinnedContainer.updateUIView()` (line 2128).

**Why:** Reduces confusion about write paths. The first call sets the gap, then `updateScrollButton` and `updatePageDots` run, then the second call sets the identical gap again. The first is redundant.

**Risk:** Negligible. The second call is identical and occurs 11 lines later in the same synchronous method.

## Verification Checklist — Device Test Scenarios

All tests on physical device (not simulator — keyboard behavior differs).

### T183 inset correctness
1. **Cold launch → tap input → keyboard appears:** Bottom message should be fully visible above keyboard, no gap, no overlap
2. **Type multi-line message (bar grows):** Inset should grow smoothly, bottom message stays visible
3. **Delete text back to single line (bar shrinks):** Inset should shrink, no sudden jump
4. **Dismiss keyboard via drag:** Smooth transition, no inset jump at end
5. **Rapid keyboard toggle (tap in/out 5x fast):** No stuck insets, final state correct
6. **Background app with keyboard up → return:** Keyboard still up, inset correct
7. **Background app with keyboard up → dismiss in another app → return:** Keyboard down, inset correct

### T181 scroll restore
8. **Switch streams while at bottom:** New stream should be at bottom, no bounce
9. **Switch streams while scrolled up:** New stream should restore exact scroll position, no bounce
10. **Switch streams with keyboard up:** Scroll position correct for new stream's inset state
11. **Switch streams rapidly (3x fast):** Each stream lands at correct position without visible bounce-then-correct

### Regression
12. **Smooth keyboard dismiss (T093):** Verify `effectiveKeyboardInset` blend formula still produces smooth transition (NOT changed in this refactor)
13. **Scroll-to-bottom button visibility:** SBB appears/disappears correctly during inset changes
14. **Deferred bottom-inset remeasure:** After bubble resize, inset re-measures correctly (not changed, but verify no interaction)
15. **visionOS (if available):** Verify the `currentBottomInset` dedup guard (line 1152) still prevents relayout churn

## Regression Concerns

### Must NOT break
- **effectiveKeyboardInset blend formula** — not touched, but verify smooth dismiss behavior
- **Deferred bottom-inset remeasure system** (bubble sizing V2 path) — not touched
- **setBottomInset single-writer invariant** — preserved; all changes keep coordinator as sole writer
- **isActivelyDraggingOrTracking split** — not touched
- **Input bar focus gates on remeasure** — not touched

### Watch for
- **Animation timing changes:** Removing the generation guard changes completion timing. Animations that were previously "abandoned" (generation mismatch) will now complete and process pending. This is the desired behavior but could surface if any code implicitly relied on the drop.
- **hasStableBarHeight eagerness:** The highest-risk change. If cold launch produces a transient bar height before steady state, we'll lock in the wrong value. Mitigation: the `setOnBarHeightChange` callback already filters changes < 1pt delta.
- **Foreground refresh coalescing:** If the layout guide frame isn't stable by the time the single async block runs, we'll sample wrong. Mitigation: `markInputsChanged` fallback path re-applies on the next tick.

## Highest-Risk Change: `hasStableBarHeight` (Change 3)

This change sets `hasStableBarHeight = true` in `updateBarHeight()` on first non-zero measurement, bypassing the double-confirmation path in `currentInsetBarHeight()`.

**Why it's risky:**
1. The double-confirmation path (`barHeightCandidate` + `barHeightCandidateApplyIndex`) exists because UIKit can report intermediate heights during initial layout — e.g., the hosting controller may first layout at a partial height before settling.
2. The `setOnBarHeightChange` callback filters `abs(measuredHeight - snapped) > 1.0` changes, but on first mount `measuredHeight` is 0 and any non-zero height passes. The first measurement could be a transient.
3. If we lock in a wrong height, the correction path (a subsequent `updateBarHeight` call) would need to exceed the 0.5pt delta threshold at line 373 to override it. If the real height is close to the transient, it could be filtered out.

**Mitigation:**
- Test cold launch on multiple devices (iPhone SE, iPhone 16 Pro Max, iPad)
- Log first bar height value vs steady-state value
- If transients are observed, fall back to keeping the confirmation tick but reducing the window from `applyIndex >= 1` to `applyIndex >= 0` (same-tick confirmation)

## Change Summary

| # | Change | File | Risk | Fixes |
|---|--------|------|------|-------|
| 1 | Remove generation guard, sync pending | ChatLayoutCoordinator.swift | Low | RC2 |
| 2 | updateBarHeight → applyTransitionIfPossible directly | ChatLayoutCoordinator.swift | Low | RC1 |
| 3 | hasStableBarHeight on first non-zero in updateBarHeight | ChatLayoutCoordinator.swift | **High** | RC1 |
| 4 | Coalesce foreground/active refreshes | ChatView.swift | Low | RC4 |
| 5 | Use currentBottomInset for scroll math | MessageFlowCollectionView.swift | Low | RC3 |
| 6 | Remove duplicate setDesiredBottomGap | ChatView.swift | Negligible | Cleanup |
