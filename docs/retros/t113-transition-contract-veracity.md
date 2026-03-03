# T113 Transition Surface Contract — Veracity Review

**Spec reviewed:** `specs/per-stream-transition-surface-contract.md`
**Code verified against:** `~/src/worktrees/per-stream-state` branch, file `ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift` (4,521 lines)
**Date:** 2026-02-25
**Reviewer:** Claude (adversarial veracity agent)

---

## Summary

| Section | Verdict | Notes |
|---------|---------|-------|
| 1. Temporal Model | **PASS** | All structural claims verified |
| 2. Async Continuation Contract | **PASS** | Guard patterns match code |
| 3. Async Operation Lifecycle | **PASS** | Cleanup model matches morph implementation |
| 4. Caller Inventory Obligation | **PASS** | update() signature and viewDidLayoutSubviews verified |
| 5. Property Shim Safety | **PASS** | Shim pattern character-for-character match; deinit claim accurate |
| 6. Emission Idempotency | **FAIL** | Section 6.2 overstates when `force:true` is restricted to |
| 7. Async Boundary Classification | **FAIL** (4 entries) | 4 of 22 entries have inaccurate descriptions |
| 8. Compliance Checklist | **PASS** | Follows from sections 1-6 |

**Overall: 6 PASS, 2 FAIL (Section 6 and Section 7).**
The failures are description-accuracy issues, not missing guards or unsafe code. The code itself is sound; the spec's descriptions of the code need correction in 5 specific places.

---

## Section 1: Temporal Model — PASS

### 1.1 Definitions — PASS
All definitions are structural/conceptual and consistent with the code's architecture.

### 1.2 Epoch Rule — PASS

**Claim: "The stream-context switch seam runs only inside update()"**
`runStreamContextSwitchSeam` is defined at line 2275 and has exactly one call site: line 1672, inside `update()`. No other caller exists. **Verified.**

**Claim: "update() is not re-entrant"**
Structurally true. `update()` is a synchronous method on a `@MainActor` class. No explicit re-entrancy guard exists (no `isUpdating` flag), but Swift's actor model guarantees single-threaded synchronous execution on `@MainActor`. The spec's claim is correct; the guarantee is structural, not defensive. **Verified.**

### 1.3 Epoch Stability — PASS

**Claim: "callbackSessionKey() returns lastAppliedEffectiveSessionKey"**
Lines 324-326: `private func callbackSessionKey() -> String? { lastAppliedEffectiveSessionKey }`. Character-for-character match. **Verified.**

**Claim: "activeStateKey() falls back to channelOverride"**
Lines 333-341: Returns `lastAppliedEffectiveSessionKey` if set, then `channelOverride` if non-empty, then `nil`. Matches spec. **Verified.**

---

## Section 2: Async Continuation Contract — PASS

### 2.1 Universal Guard Rule — PASS
The prescribed pattern (`activeSessionGenerationToken()` capture + `callbackSessionKey()` + `restoreGeneration` validation) matches the actual guard patterns found across all 10 fully-guarded async boundaries. See Section 7 verification below for per-entry evidence.

### 2.2 Exceptions — PASS
- **Fire-and-forget visual tweens:** Entrance animation at `willDisplay` (line 1066) confirmed: `UIView.animate` with no completion, only `cell.alpha` and `cell.transform` writes. No per-stream state access.
- **willResignActive:** Handler at line 1040 confirmed: `handleWillResignActive` calls `callbackSessionKey()` live and persists whatever session is current. No token capture. Correct by design.

### 2.3 dataSource.apply Special Case — PASS
The `afterSnapshotApplied` closure (line 1813) guards on `callbackSessionKey() == effectiveSessionKey` only, no generation check. Both animated and non-animated apply paths use the same closure. Spec description is accurate.

---

## Section 3: Async Operation Lifecycle — PASS

### 3.1–3.2 Setup-Yield-Resume-Cleanup Model — PASS
The morph animation is the canonical example. Verified at lines 2797-2905:
- **Capture:** `morphToken = activeSessionGenerationToken()` at line 2809, `morphTargetMessageId = targetId` set.
- **Yield:** `DispatchQueue.main.async` at line 2844.
- **Resume:** Token validated (session + generation) at lines 2846-2856.
- **Cleanup on abort:** `morphTargetMessageId = nil`, `deferScrollToBottomUntilMorphCompletes = false` at lines 2849-2851.
- **Cleanup on success:** Same properties cleared after animation completes.

### 3.3 Multi-Yield — PASS
The morph has two yields (async dispatch, then UIView.animate completion). Both validate the same `morphToken`. Confirmed at lines 2871-2905: the completion block re-validates `callbackSessionKey() == morphToken.sessionKey` AND `restoreGeneration == morphToken.generation`.

---

## Section 4: Caller Inventory Obligation — PASS

### 4.1–4.2 Default-Parameter Hazard — PASS
`update()` signature at lines 1618-1632 confirmed. Session-critical parameters with defaults:
- `sessionKey: String? = nil` — default falls back to `engineActiveSessionKey` (line 1660)
- `onScrollEvent: ... = nil` — default clears stored callback
- `onExpand: ... = nil` — default clears stored callback
- `forceReReadGeneration: Int = 0` — default means "no forced re-read"
- `isDark: Bool? = nil` — default means "no theme override"

All match spec's enumeration.

### 4.3 viewDidLayoutSubviews Rule — PASS
`viewDidLayoutSubviews` at line 862 calls `update()` at lines 907-922 with:
- `sessionKey: channelOverride` — **confirmed** (line 918)
- `onScrollEvent: onScrollEvent` — **confirmed** (line 921)
- `onExpand: onExpand` — **confirmed** (line 917)
- `isDark: currentIsDark` — **confirmed** (line 922)
- `forceReReadGeneration: 0` — **confirmed** (line 919)

All stored parameters passed explicitly. Matches spec exactly.

---

## Section 5: Property Shim Safety — PASS

### 5.1 Shim Pattern — PASS
Spec shows: `get { activeStateKey().flatMap { readState(for: $0).morphTargetMessageId } }`
Actual code at lines 481-487: character-for-character match. 35 total shims confirmed (lines 353-668), all following the identical `activeStateKey().flatMap { readState(for: $0).property }` getter pattern and `guard let key = activeStateKey() else { return }; mutateState(for: key) { $0.property = newValue }` setter pattern.

### 5.4 deinit Special Case — PASS (description accurate)
`deinit` at lines 698-701 only cancels `pendingBottomInsetHeightCapInvalidation?.cancel()` and removes the notification observer. It does NOT iterate `perStreamStateBySessionKey`. The spec accurately describes this as a limitation and prescribes the rule for improvement. The spec's factual claim about current behavior is correct.

---

## Section 6: Emission Idempotency — FAIL

### 6.1 Steady-State Emission Rule — PASS
`emitHideIndicatorIfChanged(force:)` at lines 2060-2069 confirmed: compares `lastReportedHideIndicator != shouldHide` and only emits on change (when `force: false`).

### 6.2 When Forced Emission Is Required — FAIL

**Spec claim:** "Forced emission (`force: true`) is permitted only when the emission cache is known to be stale or uninitialized: 1. Session switch. 2. First activation."

**Actual code:** `setSBBState(_:)` at lines 2048-2052 calls `emitHideIndicatorIfChanged(force: true)` on **every SBB state transition**, not just session switch or first activation:

```swift
private func setSBBState(_ newState: SBBState) {
    guard sbbState != newState else { return }
    sbbState = newState
    emitHideIndicatorIfChanged(force: true)  // line 2051
}
```

`setSBBState` is called from 11+ sites during normal scroll interaction:
- `scrollViewWillBeginDragging` (line 1026): `.atBottom` → `.atBottomDragging`
- `handleUserScrolled` (lines 2107-2118): various transitions during drag/scroll
- `handleUserScrollSettled` (line 2141): → `.atBottom`
- `syncUnreadStateWithSBBState` (lines 2171-2174): `.scrolledUp` ↔ `.scrolledUpUnread`
- `checkFirstUnreadCrossingIfNeeded` (lines 2225, 2251): `.scrolledUpUnread` → `.scrolledUp`

These are ordinary intra-session scroll events, not session switches or first activations. The `force: true` fires on every one.

**Impact:** The spec's Section 6.2 restriction is aspirational, not descriptive. The code uses `force: true` more broadly than the spec permits. This doesn't cause bugs (forced emission is strictly a superset of change-detected emission), but the spec is factually wrong about when `force: true` is used.

**Fix:** Either change the spec to say "Forced emission is used on all SBB state transitions and session switches" or change the code to use `force: false` in `setSBBState` (relying on change detection for intra-session transitions).

### 6.3 Same-Key Re-Read — not independently verified (no FAIL evidence found)

---

## Section 7: Async Boundary Classification — FAIL (4 entries)

### Fully Guarded Table (10 entries) — ALL PASS

| Entry | Verdict | Evidence |
|-------|---------|----------|
| `pendingBottomInsetHeightCapInvalidation` | PASS | Lines 1125-1143: `asyncAfter` + `DispatchWorkItem`, token capture at 1126, generation guard at 1131, `withBoundSessionKey` at 1132. |
| `pendingScrollToBottomWorkItem` | PASS | Lines 1262-1275: `DispatchQueue.main.async` + `DispatchWorkItem`, generation captured at 1262, `isCancelled` check at 1267, generation guard at 1268. |
| Morph animation escape | PASS | Lines 2844-2856: `DispatchQueue.main.async`, `morphToken` captured at 2809, session + generation validated at 2846-2856. |
| Morph completion | PASS | Lines 2871-2905: `UIView.animate` completion, same `morphToken` re-validated (multi-yield). |
| Viewport anchor compensation | PASS | Lines 4162-4183: `DispatchQueue.main.async`, token capture, session + generation guard, `refreshLastKnownScrollSnapshot` at 4182. |
| Bottom inset remeasure timer | PASS | Lines 1171-1186: `Timer` + `RunLoop.main.add`, generation guard at 1180, `withBoundSessionKey` at 1181. |
| Scroll state debounce timer | PASS | Lines 2375-2388: `Timer.scheduledTimer`, generation guard via captured `expectedGeneration`. |
| V2 remeasure debounce timer | PASS | Lines 4012-4046: `Timer` + `RunLoop.main.add`, generation guard, `withBoundSessionKey`. |
| V2 deferred flush timer | PASS | Lines 4063-4084: `Timer` + `RunLoop.main.add`, generation guard, `withBoundSessionKey`. |
| Restore attempt callback | PASS | Lines 2498-2531: `RestoreAttemptToken` (session + generation + stage), one-shot via `registerOnMessageLoad`, triple guard (session, generation, stage). |

### Session-Guarded Only Table (5 entries) — 2 PASS, 3 FAIL

| Entry | Verdict | Finding |
|-------|---------|---------|
| `scheduleTailToFullPromotionIfNeeded` | **FAIL** | Lines 1576-1596. Spec says "session key guard only." Actual guard is **compound**: `self.isActiveSession` AND `(self.channelOverride ?? self.viewModel?.engineActiveSessionKey) == sessionKey`. This queries `engineActiveSessionKey` (live view-model property), NOT `callbackSessionKey()` / `lastAppliedEffectiveSessionKey`. The guard is more complex than described and uses a non-standard session key source. |
| `dataSource.apply` completion | PASS | Line 1815: `afterSnapshotApplied` guards on `callbackSessionKey() == effectiveSessionKey`. No generation check. Matches spec. |
| `requestFlashMessage` callback | **FAIL** | Lines 2180-2188. Spec says "Registered one-shot, session-key-only guard." Two inaccuracies: (1) `performPendingFlashIfPossible()` is called immediately at line 2183 before the callback is even registered — spec omits this pre-registration attempt; (2) the callback closure itself has no internal session guard — it relies on the `fireRegisteredMessageLoadCallbacksIfMaterialized` fire-site guard at line 2484 (`callbackSessionKey() == sessionKey`). The guard is structurally present but is in the fire machinery, not in the callback closure as the spec implies. |
| `checkFirstUnreadCrossing` callback | **FAIL** | Lines 2201-2219. Method is `checkFirstUnreadCrossingIfNeeded` (spec drops "IfNeeded"). Registration only occurs in a narrow conditional branch: when message is not materialized AND stage is `.tail` AND `unreadOutsideTailWindow == true`. Spec does not describe this conditionality. The guard itself (session-key only) and one-shot nature are accurate. |
| `scrollToMessageCentered` callback | PASS | Lines 3818-3825: `callbackSessionKey()` guard, one-shot via `registerOnMessageLoad`, re-evaluates session key on callback re-invocation. Matches spec. |

### Unguarded Table (7 entries) — 6 PASS, 1 FAIL

| Entry | Verdict | Finding |
|-------|---------|---------|
| `scheduleReconfigure` | PASS | Lines 4194-4206: `DispatchQueue.main.async`, no session guard. Self-healing via `snapshot.indexOfItem` filtering. |
| `scheduleLayoutInvalidation` | PASS | Lines 4277-4289: `DispatchQueue.main.async`, no session guard. Self-healing via layout invalidation idempotency. |
| Entrance animation | PASS | Line 1066: `UIView.animate` no completion, only `cell.alpha` and `cell.transform`. No per-stream state. |
| `setBottomInset` animation | **FAIL** | Lines 1081-1115. Spec claims "animation block uses live `callbackSessionKey()` for offset adjustment." **Incorrect.** The animation block does NOT call `callbackSessionKey()`. Both `shouldPinToBottom` (line 1086) and `delta` (line 1085) are pre-captured before `UIView.animate`. The block is entirely self-contained on pre-captured values. The exempt characterization is still correct, but the stated mechanism is wrong. |
| `willResignActive` handler | PASS | Lines 690/1040: NotificationCenter observer, handler calls `callbackSessionKey()` live and persists. By-design exempt. |
| `willDisplay` delegate | PASS | Lines 1045-1076: UIKit callback, shim access (`pendingEntranceAnimationIds`, `morphTargetMessageId`) within layout epoch. Reactive access. |
| `onRequestLayout` cell callback | PASS | Lines 2779/3902: Cell closure, fires asynchronously from link preview callbacks, uses shim. "Needs attention" flag is warranted. |

### Missing Async Boundaries — NONE FOUND

Comprehensive sweep of all async patterns in the file:
- 6 `DispatchQueue.main.async` — all accounted for in tables
- 1 `DispatchQueue.main.asyncAfter` — accounted for (`pendingBottomInsetHeightCapInvalidation`)
- 3 `UIView.animate` — all accounted for (entrance, setBottomInset, morph)
- 4 `Timer` instances — all accounted for
- 1 `NotificationCenter.addObserver` — accounted for (willResignActive)
- Registered callbacks (`registerOnMessageLoad`) — all accounted for

No missed async boundaries.

---

## Section 8: Compliance Checklist — PASS
The checklist follows from sections 1-6. No independent claims to verify.

---

## Consolidated Findings

### FAILs requiring spec correction (5 total):

1. **Section 6.2** — `force: true` is not restricted to session switch and first activation. `setSBBState` at line 2051 uses `force: true` on every SBB state transition during normal scroll interaction.

2. **Section 7, `scheduleTailToFullPromotionIfNeeded`** — Guard is compound (`isActiveSession` + `engineActiveSessionKey` match), not standard `callbackSessionKey()`. Spec understates the guard complexity and uses a non-standard session key source.

3. **Section 7, `requestFlashMessage` callback** — Spec omits the pre-registration immediate `performPendingFlashIfPossible()` call. The callback closure has no internal guard; session gating is in the fire machinery.

4. **Section 7, `checkFirstUnreadCrossing` callback** — Method name is `checkFirstUnreadCrossingIfNeeded` (spec drops suffix). Registration is conditional on a narrow branch (tail stage + unread outside window), not unconditional.

5. **Section 7, `setBottomInset` animation** — Spec incorrectly claims the animation block uses live `callbackSessionKey()`. All values are pre-captured. The block has no session-key access.

### None of these FAILs indicate unsafe code.
Every FAIL is a spec-description accuracy issue. The guards in the code are correct; the spec's descriptions of those guards have inaccuracies. No missing guards, no unsafe shim access, no missed async boundaries were found.
