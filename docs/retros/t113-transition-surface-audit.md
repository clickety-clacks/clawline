# T113 Transition Surface Audit

**Date:** 2026-02-25
**Reviewer:** Opus (architecture agent, per-stream-state branch)
**Branch:** `per-stream-state` @ `77b38fcc8`
**Scope:** All old code paths that interact with new per-stream state. Focus on boundaries where code written before the branch touches state introduced or restructured by the branch.

---

## Context

Four rounds of device bugs after passing adversarial review. Every bug lived at the old↔new boundary. Prior reviews verified new code against spec but never checked how old code interacts with new code.

This audit reads the full diff (per-stream-state vs main, 1226 lines changed across 10 files, 4484 total lines in MessageFlowCollectionView.swift) and traces every interaction surface where old code paths touch, read, write, or react to new per-stream state.

---

## Part 1: Transition Surface Findings

### TS-1: `viewDidLayoutSubviews` calls `update()` with missing session-critical parameters

**Severity: BLOCKING**

**Location:** `MessageFlowCollectionView.swift:906-918`

```swift
override func viewDidLayoutSubviews() {
    // ... bounds change detection ...
    if let viewModel {
        update(
            viewModel: viewModel,
            isCompact: isCompact,
            isActiveSession: isActiveSession,
            isRenderPolicyFrozen: isRenderPolicyFrozen,
            isInputActive: isInputActive,
            topInset: topInset,
            truncationBottomInset: truncationBottomInset,
            firstUnreadMessageId: self.firstUnreadMessageId,
            unreadCount: self.unreadCount
            // MISSING: sessionKey, forceReReadGeneration, onScrollEvent, onExpand, isDark
        )
    }
}
```

The `update()` method signature has defaults for omitted parameters:
- `sessionKey: String? = nil` → `effectiveSessionKey` becomes `viewModel.engineActiveSessionKey` instead of `channelOverride`
- `onScrollEvent: ... = nil` → **sets `self.onScrollEvent = nil`** (line 1642)
- `onExpand: ... = nil` → **sets `self.onExpand = nil`** (line 1640)
- `isDark: Bool? = nil` → skips appearance comparison (benign)
- `forceReReadGeneration: Int = 0` → won't trigger re-read (benign)

**Four consequences:**

1. **`self.onScrollEvent = nil`**: After any bounds change (rotation, keyboard, multitasking), all `MessageFlowScrollEvent` emissions are silently dropped until the next SwiftUI-driven `updateUIViewController`. This means `isAtBottomChanged`, `didReceiveNewMessagesWhileScrolledUp`, etc. do not reach ChatView. The scroll button state stops updating.

2. **`self.onExpand = nil`**: After bounds change, tap-to-expand callbacks are silently dropped.

3. **`self.channelOverride = nil`** (line 1636: `self.channelOverride = sessionKey`): For the active page, `channelOverride` was the same as `engineActiveSessionKey`, so `effectiveSessionKey` is unchanged. But `channelOverride` being nil affects `scheduleTailToFullPromotionIfNeeded` (line 1575: `self.channelOverride ?? self.viewModel?.engineActiveSessionKey`) and `runMaterializationRefreshPass` (line 1606: `sessionKey: channelOverride`). After the bounds change, `runMaterializationRefreshPass` would pass `sessionKey: nil` to `update()`, causing the same cascade.

4. **For offscreen page controllers**: `channelOverride` was "B" (the offscreen session), but now `effectiveSessionKey` becomes `engineActiveSessionKey` = "A". The seam detects a "switch" from B→A and executes: flush B's scroll state, cancel B's deferred work, clear B's callbacks, prepare A as incoming, set `lastAppliedEffectiveSessionKey = "A"`. The offscreen controller for page B now thinks it owns page A. All `callbackSessionKey()` calls return "A". When SwiftUI next calls `updateUIViewController` with `sessionKey: "B"`, another spurious switch happens (A→B).

**Risk:** Wrong behavior. Scroll button stops responding after rotation/keyboard. Offscreen controllers corrupt active session state. This is the exact class of bug that caused the 4 rounds of device failures — old code calling `update()` without awareness of the new session-key contract.

**Fix:** `viewDidLayoutSubviews` must pass all stored parameters:
```swift
if let viewModel {
    update(
        viewModel: viewModel,
        isCompact: isCompact,
        isActiveSession: isActiveSession,
        isRenderPolicyFrozen: isRenderPolicyFrozen,
        isInputActive: isInputActive,
        topInset: topInset,
        truncationBottomInset: truncationBottomInset,
        firstUnreadMessageId: self.firstUnreadMessageId,
        unreadCount: self.unreadCount,
        onExpand: onExpand,
        sessionKey: channelOverride,
        forceReReadGeneration: 0,
        onScrollEvent: onScrollEvent,
        isDark: currentIsDark
    )
}
```

---

### TS-2: `scheduleReconfigure` async block reads shim properties without session binding

**Severity: MINOR**

**Location:** `MessageFlowCollectionView.swift:4157-4169`

```swift
private func scheduleReconfigure(for messageId: String) {
    pendingReconfigureIds.insert(messageId)  // writes to activeStateKey()'s state
    DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        let ids = Array(self.pendingReconfigureIds)  // reads from activeStateKey() AT EXECUTION TIME
        self.pendingReconfigureIds.removeAll()
        // ...
    }
}
```

If the active session changes between `insert` and the async block's execution, the async block drains the *new* session's `pendingReconfigureIds` (which may be empty) and leaves the *original* session's inserted ID orphaned.

**Risk:** Missed reconfigure for one message. Self-healing on next update cycle. Low practical impact.

**Same pattern in:** `scheduleLayoutInvalidation()` (line 4240) — reads `dirtySizeIds` through shim in async block.

---

### TS-3: `emitHideIndicatorIfChanged(force: true)` fires on every steady-state update

**Severity: MINOR (performance)**

**Location:** `MessageFlowCollectionView.swift:2293, 2302, 2314` (all three paths in `runStreamContextSwitchSeam`)

The no-switch path (line 2297-2304) calls `emitHideIndicatorIfChanged(force: true)` on every `update()` invocation, even when the session key is unchanged and no state has changed.

This emits `.isAtBottomChanged(sessionKey:, isAtBottom:)` on every SwiftUI update cycle. ChatView's `handleMessageFlowScrollEvent` then writes to `scrollButtonStateBySessionKey[sessionKey]` even when the value is identical. Since `ScrollButtonState` is `Equatable`, SwiftUI should short-circuit the diff, but the dictionary mutation still occurs.

**Risk:** Performance. Unnecessary work on every frame. Not a correctness issue.

---

### TS-4: Morph completion callback reads shim properties without session binding

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift:2862-2871`

The morph animation completes 2+ seconds after start. The completion closure reads `self.deferScrollToBottomUntilMorphCompletes` and `self.morphTargetMessageId` through shim properties. If the user switched sessions during the morph, these read from the new active session's state, not the session that started the morph.

**Risk:** Stale `deferScrollToBottomUntilMorphCompletes = true` in the original session's per-stream state. Orphaned but harmless — the value is unconditionally overwritten on the next morph. `morphTargetMessageId` is set to nil (correct) but for the new session (wrong session, but also harmless since the new session has no active morph).

---

### TS-5: `deinit` only cancels one session's `pendingBottomInsetHeightCapInvalidation`

**Severity: COSMETIC**

**Location:** `MessageFlowCollectionView.swift:698-701`

```swift
deinit {
    NotificationCenter.default.removeObserver(self, ...)
    pendingBottomInsetHeightCapInvalidation?.cancel()  // reads from activeStateKey()
}
```

The shim reads from `activeStateKey()` which only returns one session's value. DispatchWorkItems and Timers for other sessions are not cancelled. Since all callbacks capture `[weak self]`, they will harmlessly no-op after deallocation. But the timers run until they fire, wasting CPU.

**Risk:** No correctness issue. Minor resource leak on controller deallocation.

---

### TS-6: `bubbleSizingV2MeasurementCache` is controller-level, not per-stream

**Severity: INFORMATIONAL**

**Location:** `MessageFlowCollectionView.swift:108`

The LRU cache (800 entries) is shared across all sessions. Since `BubbleSizingV2.CacheKey` now includes `sessionKey` (branch change to `BubbleSizingV2.swift`), different sessions' measurements don't collide. But rapid switching between many sessions can evict entries, causing re-measurement on switch-back.

**Risk:** Performance on switch-back (cache miss → re-measure). Not a correctness issue.

---

### TS-7: `clearAllBubbleV2State()` clears shared LRU but only active session's key mappings

**Severity: INFORMATIONAL**

**Location:** `MessageFlowCollectionView.swift:812-816`

Called from `invalidateFor(.envChanged)` on bounds changes. Clears the shared `bubbleSizingV2MeasurementCache` (all sessions) but only clears `bubbleSizingV2KeysByMessageId` and `bubbleSizingV2LinkPreviewStateVersionByMessageId` for the active session (via shims). Other sessions retain stale key mappings pointing to evicted cache entries.

**Risk:** On switch-back, per-stream state has stale key mappings. Cache lookup misses → re-measure (correct but wasteful). The stale mappings are cleaned up when `invalidateFor(.envChanged)` runs during the switch-back update (since `needsFullLayout` is true on session change).

---

### TS-8: `scheduleBubbleSizingV2ViewportAnchorCompensation` dispatches unbound async work

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift:4129-4147`

The `DispatchQueue.main.async` closure adjusts `contentOffset` based on a captured anchor. It does NOT validate the active session key or generation. If the session changes before the async block runs, the offset adjustment applies to the new session's display — but since the anchor was captured for the old session, the adjustment would be incorrect geometry.

**Risk:** Subtle scroll position jump on the new session after a rapid switch + bounds change. Very narrow timing window. The anchor capture and async block must straddle a session switch.

---

## Part 2: Completeness Verification (Gates + Acceptance Checks vs Full Codebase)

For each gate and acceptance check, I evaluate whether the FULL codebase (old + new together) satisfies the check, considering the transition surface findings above.

### Phase 1 Completion Gates

| Gate | Against new code only | Against full codebase | Delta |
|---|---|---|---|
| 1. forceReRead end-to-end | PASS | **PASS** | No change. `viewDidLayoutSubviews` passes `forceReReadGeneration: 0` by default, which correctly does not trigger re-read. |
| 2. One-shot callback registry | PASS | **PASS** | Registration uses explicit `sessionKey` parameter, not shim. Fire path guards `callbackSessionKey()`. TS-1 could cause `callbackSessionKey()` to return wrong key for offscreen controllers, but fire path's `callbackSessionKey() == sessionKey` guard prevents firing in wrong context — it just delays firing until the next correct update. |
| 3. Canonical auth cursor | PASS | **PASS** | Cursor logic is in `ProviderChatService`, not affected by MFCV transition surfaces. |
| 4. Timer generation validation | PASS | **PASS** | All 5 timer types capture `(sessionKey, generation)` at schedule time and validate before mutation. TS-1 cannot defeat generation guards because the generation was captured for the correct session. A stale `lastAppliedEffectiveSessionKey` would cause `activeSessionGenerationToken()` to return a different session's token, which won't match the captured token — timer callback returns early. Safe. |
| 5. Spec text updated | PASS | **PASS** | No interaction with old code. |
| 6. Acceptance checks 1-25 | 25/25 | **See below** | Several checks affected by TS-1. |

### Acceptance Checks 1-25

| # | Description | New code | Full codebase | Notes |
|---|---|---|---|---|
| 1 | Switch A→B→A restores position | PASS | **PASS** | TS-1 could cause spurious switch in offscreen controller, but the flush-on-switch in the seam persists correct state before any mutation. Switch-back restores from persisted state. |
| 2 | First activation tail→full restore | PASS | **PASS** | Materialization state machine and restore phases are not affected by TS-1. `scheduleTailToFullPromotionIfNeeded` uses `channelOverride ?? engineActiveSessionKey`, which handles nil channelOverride. |
| 3 | Pending timers from A do not mutate B | PASS | **PASS** | Timer generation guards protect against cross-session mutation. Even with TS-1's wrong `lastAppliedEffectiveSessionKey`, captured generation tokens prevent mutation. |
| 4 | Drag/morph deferral from A does not auto-scroll B | PASS | **CONDITIONAL PASS** | TS-4 shows morph completion reads shim properties from wrong session after switch. But the stale value is harmless (see TS-4 analysis). |
| 5 | SBB correct after switch when not at bottom | PASS | **PASS** | `prepareIncomingStateOnSwitch` sets SBB state before any layout. Not affected by transition surfaces. |
| 6 | Same-key re-read re-arms restore | PASS | **PASS** | `forceReReadGeneration` comparison in seam is not affected by TS-1 (the bounds-change path passes 0, which doesn't trigger re-read). |
| 7 | No persisted state → deterministic bottom | PASS | **PASS** | |
| 8 | Frozen→unfrozen path | PASS | **PASS** | |
| 9 | Prewarm/offscreen do not mutate active runtime | PASS | **FAIL** | **TS-1** directly violates this. An offscreen page controller's `viewDidLayoutSubviews` calls `update()` without `sessionKey`, causing `effectiveSessionKey = engineActiveSessionKey`. The offscreen controller then runs the stream context switch seam for the ACTIVE session, mutating active-session per-stream state. |
| 10 | Message-ID collisions across streams | PASS | **PASS** | `BubbleSizingV2.CacheKey` includes `sessionKey`. |
| 11 | Switch during `pendingFullConfirmation` | PASS | **PASS** | Token validation prevents stale retry. |
| 12 | Bounded confirmation retries converge | PASS | **PASS** | |
| 13 | Deleted stream keys pruned | PASS | **PASS** | |
| 14 | Mutation callback without resolved key no-ops | PASS | **CONDITIONAL PASS** | TS-1 can cause `callbackSessionKey()` to return a wrong-but-non-nil key. The check passes for nil case but fails for wrong-key case. However, this only happens during the narrow window after `viewDidLayoutSubviews` in offscreen controllers. |
| 15 | Same-key re-read no persist overwrite | PASS | **PASS** | Suspension flag checked before any persist. |
| 16 | Switch A→B: B classification uses B's lastMessageId | PASS | **PASS** | Shim reads from `activeStateKey()` which is the newly set key. |
| 17 | Frozen→unfrozen triggers follow-up | PASS | **PASS** | |
| 18 | Scroll delegates during seam mutate outgoing | PASS | **CONDITIONAL PASS** | The seam itself doesn't trigger `scrollViewDidScroll`. But TS-1's spurious seam in offscreen controllers could cause unexpected seam execution, during which scroll delegates would target the wrong key. |
| 19 | Replay cursor isolated per stream | PASS | **PASS** | In `ProviderChatService`, not MFCV. |
| 20 | Concurrent replay cannot advance sibling | PASS | **PASS** | Same. |
| 21 | Stale (key, gen) replay callbacks no-op | PASS | **PASS** | |
| 22 | No direct message-store writes | PASS | **PASS** | |
| 23 | Callback registry fires once, expires correctly | PASS | **PASS** | |
| 24 | Reload trigger normalization | PASS | **PASS** | |
| 25 | Transport cursor storage owned by transport | PASS | **PASS** | |

**Score: 23/25 PASS, 1 FAIL (check 9), 1 CONDITIONAL PASS (check 14)**

---

## Part 3: Summary

### Blocking

**TS-1: `viewDidLayoutSubviews` calls `update()` without session-critical parameters.** This is the same class of bug as the prior 4 rounds of device failures: old code calling into new per-stream infrastructure without awareness of the session-key contract. It causes:
- Scroll event handler silently dropped after any bounds change (rotation, keyboard, multitasking)
- Expand handler dropped
- Offscreen page controllers corrupt active session's per-stream state
- Acceptance check 9 violated

### Non-blocking

| Finding | Severity | Fix needed? |
|---|---|---|
| TS-2: `scheduleReconfigure` async reads wrong session | MINOR | Optional. Self-healing. |
| TS-3: Force-emit on every update cycle | MINOR | Optional. Performance only. |
| TS-4: Morph completion reads wrong session | LOW | No. Harmless stale value. |
| TS-5: `deinit` partial timer cleanup | COSMETIC | No. Weak refs prevent harm. |
| TS-6: Shared LRU cache across sessions | INFO | No. By design. |
| TS-7: `clearAllBubbleV2State` partial cleanup | INFO | No. Self-healing on switch. |
| TS-8: Viewport anchor compensation unbound | LOW | Optional. Very narrow window. |

### Why Prior Reviews Missed This

All prior reviews (R1, R2, CCX R3, Claude Final) verified new code against spec. They checked:
- Does the seam implement the spec? Yes.
- Do timers have generation guards? Yes.
- Does the callback registry fire correctly? Yes.

They never asked: **What old code calls `update()` and does it pass the parameters that the new code now requires?** The `viewDidLayoutSubviews` call predates the branch. It has always called `update()` with a subset of parameters, using defaults for the rest. Before the branch, those defaults were harmless (there was no session key concept). After the branch, the defaults silently break session isolation.

This is the classic transition surface failure: correct new code + correct old code = broken system, because the contract between them changed and only the new call sites were updated.
