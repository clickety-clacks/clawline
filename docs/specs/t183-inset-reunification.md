# T183: Bottom Inset Race Condition — Reunification Scoping Report

**Date:** 2026-03-24
**Branch:** `t183-inset-recon`
**Status:** Architecture/scoping pass (no code changes)

## Executive Summary

The Feb 13 unification commit (`6384052e1f`) consolidated all inset math into `ChatLayoutCoordinator` via a pure-function `insetLayoutState()` + coordinator-owned bar height cache. Seven subsequent commits re-introduced timing dependencies and async gaps that produce two intermittent failure modes: too-little-inset (message stuck behind keyboard) and too-much-inset (gap between message and keyboard).

Four race conditions were identified. **RC1 and RC2 are the primary causes** and both live inside `ChatLayoutCoordinator`. RC3 and RC4 are secondary and lower-risk.

## Original Design Intent (6384052e1f)

The unification commit established:

1. **`ChatInsetLayoutState`** — immutable struct bundling `barHeight`, `keyboardInset`, `inputBarTopFromScreenBottom`, `listBottomInset`
2. **`insetLayoutState(inputs:metrics:barHeight:)` (static)** — pure function; single formula for all inset math
3. **`runtimeInsetLayoutState(...)` (instance)** — wraps the static method with bar-height cache/fallback resolution
4. **`effectiveKeyboardInset` on `ChatLayoutInputs`** — single source of truth for keyboard contribution
5. **`lastKnownGoodBarHeight` guard** — rejects transient zero-height reports during keyboard transitions
6. **ChatView simplified** — no more inline inset math; calls coordinator exclusively

**Key invariant:** all inset writes flow through `ChatLayoutCoordinator.applyTransitionIfPossible()` → `list.setBottomInset()`. No direct `contentInset.bottom` mutations outside that path.

## How Subsequent Commits Re-fragmented

| # | Commit | What it added | Fragmentation introduced |
|---|--------|--------------|--------------------------|
| 1 | `cb72c69915` | Seed `setDesiredBottomGap` in `updateUIView` | Duplicate gap-setting call outside coordinator transition path |
| 2 | `a429a14985` | Split `isUserInteracting` from `isActivelyDraggingOrTracking` | Correct fix, no fragmentation |
| 3 | `f7f1fbb60d` | Capture `previousBottomInset`/`newBottomInset` by value in debounce | Correct fix, no fragmentation |
| 4 | `fad25cbab1` | Gate deferred remeasure on `isInputActive` | Added cross-component coupling (ChatView focus → collection view remeasure gates) |
| 5 | `524ac4abcb` | Deferred bottom-inset remeasure system | Introduced secondary inset-dependent timer loop with per-stream state |
| 6 | `010d9023c2` | Continuous `effectiveKeyboardInset`, no-op early-exit guard, debounced height-cap invalidation | Changed `effectiveKeyboardInset` formula (removed `keyboardVisible` gate, added safe-area subtraction + blending). Added `generation` counter and `isApplyingTransition` guard with async pending dispatch — **this is where RC2 was introduced** |
| 7 | `a3abff5d5f` | Bypass input gates on keyboard-dismiss for visible bubbles | Layered bypass flag on top of commit 4's gates |

Commits 5–7 are internally sound in isolation but together create a three-layer deferred-remeasure system (height cap debounce → deferred ID set → bypass flag) that interacts poorly with the coordinator's transition guard.

## Race Conditions — Detailed Analysis

### RC1: Bar Height vs. Keyboard Height (both failure modes)

**Paths:**
- **Bar height:** `layoutSubviews` → `onBarHeightChange` → `updateBarHeight` (synchronous to `barHeightCache`) + `DispatchQueue.main.async { _measuredHeight.wrappedValue = snapped }` (async to SwiftUI @State)
- **Keyboard height:** `keyboardWillChangeFrame` → `onChange` callback → `keyboardHeight` @State → `onChange(of: layoutInputs)` → `updateInputs` + `markInputsChanged`

**Problem:** These two paths feed the coordinator independently. When a keyboard notification fires before the bar has its first stable measurement, `currentInsetBarHeight()` returns the bootstrap `minInputBarHeight` (44pt) instead of the real height (~88pt+). The inset is computed with the wrong bar height component.

**Too-little-inset scenario:** Keyboard appears → `keyboardHeight` updates → coordinator computes inset with bootstrap 44pt bar → inset is ~44pt short → message partially behind keyboard.

**Too-much-inset scenario:** The `effectiveKeyboardInset` blend formula (`visibleHeight / 24` progress) can produce a non-zero keyboard contribution even during the final dismiss frames when `keyboardHeight` is still slightly above `safeAreaBottom`. If the bar height has already stabilized to the full height, the sum overshoots.

**Location:** `ChatLayoutCoordinator.swift:381-407` (`currentInsetBarHeight`), `ChatView.swift:2141-2153` (async `_measuredHeight` dispatch)

### RC2: Transition Guard + Generation Counter Drops Corrections (too-much-inset)

**The mechanism:**
1. `applyTransitionIfPossible` starts an animated transition: `isApplyingTransition = true`, `generation += 1`, captures `currentGeneration`
2. New inputs arrive (bar height change or keyboard update) → `applyTransitionIfPossible` hits `isApplyingTransition` guard → stores `pendingInputs` → schedules `DispatchQueue.main.async` reentrant call
3. Animation completes → completion block: `guard self.generation == currentGeneration` → if generation was incremented by another path, **guard fails** → `isApplyingTransition` is never cleared → **permanent stall**

**The recovery path:** In practice, the non-animated path (`else` branch at L283) doesn't set `isApplyingTransition`, so the stall eventually self-heals on the next non-animated transition. But the correction from step 2's `pendingInputs` is **silently dropped**, leaving `lastAppliedInset` stale.

**The async gap:** The completion block dispatches pending processing via `DispatchQueue.main.async` (L277). Between the completion firing and the async executing, other events can call `applyTransitionIfPossible`, increment `generation`, and apply a transition based on stale `latestInputs`. The pending processing then overwrites `latestInputs` with older values via `updateInputs(pending.0, pending.1)`.

**Location:** `ChatLayoutCoordinator.swift:191-287` (entire `applyTransitionIfPossible`)

### RC3: Scroll Restore Reads In-Flight Inset (secondary)

`attemptRestoreScrollIfNeeded` at `MessageFlowCollectionView.swift:2715-2717` reads `collectionView.contentInset.bottom` to compute `maxY`. If the coordinator's `UIView.animate` block has already set the property (UIKit sets it immediately in the animation block, not interpolated), this value is correct. But if the coordinator's async pending dispatch hasn't fired yet, or if the list's `setBottomInset` hasn't been called, `contentInset.bottom` reflects the previous value.

**Risk:** Low. The restore uses `currentBottomInset` in bubble sizing (L3527) but reads `collectionView.contentInset` for scroll math. A mismatch causes a one-frame scroll position error on stream switch.

**Location:** `MessageFlowCollectionView.swift:2695-2727`

### RC4: Foreground/Active Double-Fire (secondary)

Both `willEnterForeground` and `didBecomeActive` fire on app return, each calling `refreshFromLayoutGuide()` synchronously AND async (4 calls total). Each produces an `onChange` callback that propagates to the coordinator. The `pendingFallback` flag coalesces the fallback path, but `onChange(of: layoutInputs)` fires synchronously on each @State mutation, generating up to 4 `updateInputs + markInputsChanged` calls.

**Risk:** Low-medium. Usually produces identical inputs so the no-op guard catches it. Fails when the keyboard was dismissed while backgrounded and the layout guide reports a sequence of intermediate heights.

**Location:** `ChatView.swift:2017-2032` (notification handlers), `ChatView.swift:1978-1997` (`refreshFromLayoutGuide`)

## Target Architecture

**Principle:** Restore the single-writer invariant from 6384052e1f. The coordinator is the **only** thing that writes insets, and it does so atomically from the latest available bar-height + keyboard-height combination.

### Changes Required

#### 1. Eliminate the generation guard and async pending dispatch (RC2 fix)

In `applyTransitionIfPossible`, the animation completion block should:
- **Always** set `isApplyingTransition = false` (no generation guard)
- Process `pendingInputs` **synchronously** in the completion (no `DispatchQueue.main.async`)

The generation counter was added to avoid stale completions, but `UIView.animate` with `.beginFromCurrentState` already handles animation interruption correctly. The guard creates more problems than it solves.

#### 2. Make `updateBarHeight` propagate through the same input path (RC1 fix)

Currently `updateBarHeight` only calls `markInputsChanged()`. It should also ensure that the next `applyTransitionIfPossible` uses the bar height atomically with the latest inputs. Two options:

- **(A) Preferred:** Have `updateBarHeight` call `applyTransitionIfPossible(reason: "barHeightChange")` directly (not via fallback). The coordinator already has `latestInputs` and `latestMetrics` stored.
- **(B) Alternative:** Merge bar height into `ChatLayoutInputs` so both keyboard and bar height arrive in one atomic update. This is heavier and changes the data flow.

Option A is simpler and preserves the existing structure.

#### 3. Remove the `DispatchQueue.main.async` for `_measuredHeight` (RC1 supplementary)

In `KeyboardPinnedContainer.updateUIView` (ChatView.swift:2146), the `_measuredHeight.wrappedValue = snapped` write is dispatched async to break SwiftUI layout cycles. This creates a one-tick lag between the coordinator having the correct bar height and SwiftUI having the correct `inputBarHeight`. Since `inputBarHeight` feeds `resolvedInputHeight` which feeds `fallbackBarHeight`, this lag can cause the coordinator to use the bootstrap value on the first transition.

**Fix:** Keep the async dispatch (the layout-cycle protection is real on iOS 26.2), but ensure the coordinator never relies on `fallbackBarHeight` after the first `updateBarHeight` call. The `hasStableBarHeight` flag should be set on the first non-zero measurement, not after a confirmation tick.

#### 4. Coalesce foreground/active callbacks (RC4 fix)

In `KeyboardLayoutGuideObserverView`, deduplicate the four `refreshFromLayoutGuide()` calls from `willEnterForeground` + `didBecomeActive`. Use a single debounced flag:
```
if !pendingForegroundRefresh {
    pendingForegroundRefresh = true
    refreshFromLayoutGuide()
    DispatchQueue.main.async { self.pendingForegroundRefresh = false; self.refreshFromLayoutGuide() }
}
```

This gives one sync + one async refresh total instead of four.

#### 5. Use `currentBottomInset` for scroll restore (RC3 fix)

In `attemptRestoreScrollIfNeeded`, replace `collectionView.contentInset.bottom` with `currentBottomInset` (the coordinator's tracked value that represents the intended state, not the in-flight UIKit value).

## Files to Change

| File | Change | Scope |
|------|--------|-------|
| `ChatLayoutCoordinator.swift` | Remove generation guard from completion; inline pending processing; make `updateBarHeight` call `applyTransitionIfPossible` directly; adopt first-measurement-stable for `hasStableBarHeight` | Medium |
| `ChatView.swift` | Coalesce foreground/active refresh in `KeyboardLayoutGuideObserverView`; no change needed to `_measuredHeight` dispatch | Small |
| `MessageFlowCollectionView.swift` | Use `currentBottomInset` in `attemptRestoreScrollIfNeeded` | Small |
| `ChatLayoutCoordinatorTests.swift` | Add tests for: generation-skipped pending, bar-height-during-animation, foreground double-fire | Medium |

## Scope Assessment

**Size:** Medium — concentrated in 3 files, ~60-80 lines changed (excluding tests).

**Risk:** Medium-high. The inset path is a "load-bearing wall" — every chat interaction touches it. The coordinator changes affect all keyboard transitions, stream switches, and app lifecycle events.

**Mitigation:**
- The existing `ChatLayoutCoordinatorTests` provide regression coverage for the pure `insetLayoutState` formula
- The changes are structural (removing complexity) not additive — we're deleting the generation guard, the async dispatch, and the fallback coalescing layers, not adding new mechanisms
- The bar-height stability heuristic change (first-measurement-stable) is the highest-risk individual change; it should be the first thing tested on device

## What NOT to Change

- The `effectiveKeyboardInset` blend formula (T093 continuous dismiss) — this is correct and should stay
- The deferred bottom-inset remeasure system (commits 5-7) — this is correctly decoupled from the coordinator; it handles bubble resizing, not inset calculation
- The `setBottomInset` implementation in `MessageFlowCollectionView` — the single-writer invariant is already preserved here
- The `isActivelyDraggingOrTracking` split (commit 2) — correct and orthogonal

## Verification Strategy

1. **Unit tests:** Add coordinator tests for the generation-skip scenario and bar-height-during-animation
2. **Device test matrix:**
   - Keyboard appear/dismiss cycling (10 rapid cycles)
   - Multi-line text expand/collapse while keyboard is visible
   - App backgrounding with keyboard up → return to foreground
   - Stream switch with keyboard up
   - Interactive keyboard dismiss (swipe down on list)
3. **Regression:** Verify T093 (smooth keyboard dismiss) and T085 (deferred remeasure) are not broken
