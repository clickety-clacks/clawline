# T113 Transition Surface Re-Audit

**Date:** 2026-02-25
**Reviewer:** Opus (architecture agent, per-stream-state branch)
**Branch:** `per-stream-state` @ `e5cf4936b`
**Prior audit:** `t113-transition-surface-audit.md` (findings TS-1 through TS-8, branch @ `77b38fcc8`)
**Fix commits under review:**
- `e5cf4936b` — Fix transition surface session binding and async guards
- `1894f6927` — Fix switch-entry SBB emit and stale snapshot restore jumps
- `c3ea60a65` — Fix reconnect auth payload risk and same-key restore jump

---

## Part 1: Verification of Original Findings

### TS-1: `viewDidLayoutSubviews` missing session-critical parameters — FIXED

**Original severity:** BLOCKING

**Evidence:** `viewDidLayoutSubviews()` (line ~918) now passes all five previously-missing parameters:

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
        onExpand: onExpand,              // ✅ was nil
        sessionKey: channelOverride,     // ✅ was nil
        forceReReadGeneration: 0,        // ✅ explicit
        onScrollEvent: onScrollEvent,    // ✅ was nil
        isDark: currentIsDark            // ✅ was nil
    )
}
```

All four consequences from the original finding are resolved:
1. `onScrollEvent` preserved → scroll button state survives bounds changes
2. `onExpand` preserved → expand callbacks survive bounds changes
3. `channelOverride` preserved → `effectiveSessionKey` resolves correctly for offscreen controllers
4. No spurious session switches in offscreen page controllers

**Verdict: FIXED. No residual risk.**

---

### TS-3: Force-emit on every steady-state update — FIXED

**Original severity:** MINOR (performance)

**Evidence:** The no-switch/steady-state path in `runStreamContextSwitchSeam` (line ~2307) now calls:

```swift
emitHideIndicatorIfChanged()  // force: false (default)
```

Not:

```swift
emitHideIndicatorIfChanged(force: true)  // ← removed
```

With `force: false`, emission only occurs when `lastReportedHideIndicator != shouldHide` — an actual state change. The `force: true` variant is retained only in the actual switch path (line ~2319), which is correct since a session switch always needs to emit the new session's SBB state.

**Verdict: FIXED. Steady-state no longer emits on every update cycle.**

---

### TS-8: Viewport anchor compensation unbound async work — FIXED

**Original severity:** LOW

**Evidence:** `scheduleBubbleSizingV2ViewportAnchorCompensation` (line ~4134) now captures a session generation token at schedule time and validates it in the async block:

```swift
guard let token = activeSessionGenerationToken() else { return }
DispatchQueue.main.async { [weak self] in
    guard let self else { return }
    guard self.callbackSessionKey() == token.sessionKey else { return }
    guard self.readState(for: token.sessionKey).restoreGeneration == token.generation else { return }
    // ... offset adjustment proceeds only if session+generation match
}
```

This follows the same token-capture pattern used by other async scheduling methods (e.g., `scheduleBubbleSizingV2DeferredFlushAfterRest`).

**Verdict: FIXED. Cross-session offset adjustment prevented by dual guard.**

---

### TS-2, TS-4, TS-5, TS-6, TS-7: Unchanged (as expected)

These were rated MINOR/LOW/COSMETIC/INFORMATIONAL and were not targeted by the fix commits. Their status is unchanged:

| Finding | Original Severity | Current Status |
|---|---|---|
| TS-2: `scheduleReconfigure` async reads wrong session | MINOR | Unchanged. Self-healing. |
| TS-4: Morph completion reads wrong session | LOW | Unchanged. See TS-10 below for expanded analysis. |
| TS-5: `deinit` partial timer cleanup | COSMETIC | Unchanged. Weak refs prevent harm. |
| TS-6: Shared LRU cache across sessions | INFO | Unchanged. By design. |
| TS-7: `clearAllBubbleV2State` partial cleanup | INFO | Unchanged. Self-healing on switch. |

---

## Part 2: Acceptance Checks 1–25 (Full Codebase)

All checks re-evaluated against `e5cf4936b`. Previously: 23 PASS, 1 FAIL (check 9), 1 CONDITIONAL (check 14).

| # | Description | Previous | Current | Notes |
|---|---|---|---|---|
| 1 | Switch A→B→A restores position | PASS | **PASS** | Seam persists outgoing, loads incoming from UserDefaults |
| 2 | First activation tail→full restore | PASS | **PASS** | pendingTail → pendingFullConfirmation → confirmed pipeline |
| 3 | Pending timers from A do not mutate B | PASS | **PASS** | All timers per-stream; cancelled on switch; generation guards |
| 4 | Drag/morph deferral from A does not auto-scroll B | PASS | **PASS** | morphTargetMessageId/deferScroll per-stream; callbackSessionKey guard |
| 5 | SBB correct after switch when not at bottom | PASS | **PASS** | sbbState per-stream; set from persisted state; forced emit on switch |
| 6 | Same-key re-read re-arms restore | PASS | **PASS** | Flushes live position, increments restoreGeneration, re-loads persisted |
| 7 | No persisted state → deterministic bottom | PASS | **PASS** | sbbState=.atBottom, restorePhase=.none; fallback scrollToBottom |
| 8 | Frozen→unfrozen path | PASS | **PASS** | Seam runs before frozen guard; next update() runs full path |
| 9 | Prewarm/offscreen do not mutate active runtime | **FAIL** | **PASS** | **TS-1 fix**: viewDidLayoutSubviews passes sessionKey: channelOverride; isOffscreenSession early-return prevents active-state mutation |
| 10 | Message-ID collisions across streams | PASS | **PASS** | Each controller has own dataSource + messagesById; per-stream fingerprints |
| 11 | Switch during pendingFullConfirmation | PASS | **PASS** | Outgoing persisted; returning re-loads fresh; retries reset |
| 12 | Bounded confirmation retries converge | PASS | **PASS** | restoreMaxConfirmationRetries=3; falls back to bottom |
| 13 | Deleted stream keys pruned | PASS | **PASS** | prunePerStreamState + pruneMaterializationState on every update() |
| 14 | Mutation callback without resolved key no-ops | **COND** | **PASS** | **TS-1 fix**: channelOverride preserved; callbackSessionKey() returns correct key for all controllers |
| 15 | Same-key re-read no persist overwrite | PASS | **PASS** | suspendScrollPersistence flag checked in schedulePersist and persistNow |
| 16 | Switch A→B: B classification uses B's lastMessageId | PASS | **PASS** | lastMessageId per-stream; read after seam binds to B |
| 17 | Frozen→unfrozen triggers follow-up | PASS | **PASS** | Seam ran during frozen pass; unfrozen update() runs full path |
| 18 | Scroll delegates during seam mutate outgoing | PASS | **PASS** | Delegates use callbackSessionKey(); outgoing persisted before key change |
| 19 | Replay cursor isolated per stream | PASS | **PASS** | replayCursorBySessionKey in ProviderChatService |
| 20 | Concurrent replay cannot advance sibling | PASS | **PASS** | setReplayCursor keyed by sessionKey; no cross-session writes |
| 21 | Stale (key, gen) replay callbacks no-op | PASS | **PASS** | RestoreAttemptToken + triple guard: sessionKey, generation, restoredSet |
| 22 | No direct message-store writes | PASS | **PASS** | Controller only reads; mutations flow through ChatViewModel |
| 23 | Callback registry fires once, expires correctly | PASS | **PASS** | removeValue(forKey:) before fire; expire on removal; clear on switch |
| 24 | Reload trigger normalization | PASS | **PASS** | forceReReadGeneration monotonic; lastSeen tracked with max() |
| 25 | Transport cursor storage owned by transport | PASS | **PASS** | Cursors in ProviderChatService only; controller has zero cursor refs |

**Score: 25/25 PASS** (previously 23/25)

---

## Part 3: New Transition Surface Issues Introduced by Fixes

### TS-9: Missing `refreshLastKnownScrollSnapshot` in bubble sizing compensation

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift:~4153`

Commit `1894f6927` established a pattern: every `setContentOffset(... animated: false)` call should be followed by `refreshLastKnownScrollSnapshot`. This was applied to:
- `scrollToBottom`
- `scrollToMessageCentered`
- `adjustContentOffsetForBottomInsetChange`
- Scroll restore attempt
- Scroll restore fallback

But `scheduleBubbleSizingV2ViewportAnchorCompensation` calls `setContentOffset(... animated: false)` without a subsequent snapshot refresh. The session key is available via the captured `token`, so adding the call is trivial.

**Risk:** Stale scroll snapshot until next scroll event. Self-correcting but inconsistent with established pattern.

**Fix:** Add `refreshLastKnownScrollSnapshot(sessionKey: token.sessionKey)` after `setContentOffset` in the async block.

---

### TS-10: Morph animation async blocks lack session guard

**Severity: MEDIUM (pre-existing, not introduced by fixes, but exposed by analysis)**

**Location:** `MessageFlowCollectionView.swift:~2840-2878`

The morph animation code predates these fix commits but was not caught by them despite the commits specifically targeting unguarded async blocks. The morph:

1. Sets `morphTargetMessageId = targetMessageId` on the current stream's per-stream state.
2. Enters `DispatchQueue.main.async`.
3. Starts a ~2-second `UIView.animate`.
4. In the completion block, clears `self.morphTargetMessageId = nil` — writes to **whatever stream is active at completion time**.
5. Checks `self.deferScrollToBottomUntilMorphCompletes` and calls `scheduleScrollToBottom` — for **whatever stream is now active**.

If the user switches streams during the 2-second morph window:
- Step 4 clears `morphTargetMessageId` on the **new** stream; the original stream retains a stale value.
- Step 5 triggers scroll-to-bottom on the **new** stream, potentially fighting with its own restore/scroll state.
- The `willDisplay` guard (`if id == morphTargetMessageId { return }`) suppresses cell alpha for the stale ID on future visits to the original stream.

**Risk:** Stale `morphTargetMessageId` persists on original stream. Wrong-stream scroll-to-bottom on new stream. Narrow window (requires switch during morph animation) but reproducible.

**Fix:** Capture session key before morph, validate in completion block. Same pattern as TS-8 fix.

---

### TS-11: `scheduleReconfigure` / `scheduleLayoutInvalidation` async blocks lack session guards

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift:~4157, ~4240`

Same as original TS-2 observation. These async blocks read shim properties without session binding. The fix commits did not address them (correctly — they're self-healing and low-risk). Noting for completeness.

**Risk:** Missed reconfigure for one message. Self-healing on next update cycle.

---

### TS-12: `scrollToBottom(animated: true)` stale snapshot window

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift`

When `scrollToBottom` is called with `animated: true`, the snapshot is not refreshed until `scrollViewDidEndScrollingAnimation`. If a stream switch occurs mid-animation, the snapshot is stale for the original stream.

**Risk:** Stale snapshot persisted for original stream. Self-correcting when animation completes or user interacts. Very narrow window.

---

### TS-13: Same-key re-read `emitHideIndicatorIfChanged()` without `force: true`

**Severity: LOW**

**Location:** `MessageFlowCollectionView.swift:~2297`

The same-key re-read path calls `emitHideIndicatorIfChanged()` (no force). If `lastReportedHideIndicator` already matches the current SBB state, no emission occurs. This could cause the SBB state to be stale after a re-read if the state genuinely changed but `lastReportedHideIndicator` was already set to the new value from a prior scroll event.

**Risk:** SBB state emission dropped in edge case. Self-correcting on next scroll interaction.

---

### TS-14: `replayCursorsBySessionKey: nil` removes per-stream cursors from auth payload

**Severity: MEDIUM (requires server-side behavior verification)**

**Location:** `ProviderChatService.swift:~904`

Commit `c3ea60a65` ("Fix reconnect auth payload risk and same-key restore jump") changed the auth payload to always send `replayCursorsBySessionKey: nil`, removing per-stream cursors. The `lastMessageId` is now the sole replay anchor, computed as `replayCursorSnapshot.values.max()` (highest cursor across all streams).

**Scenario for message loss:**
1. User has streams A (cursor at `s_100`) and B (cursor at `s_50`).
2. WebSocket reconnects.
3. `resolveAuthLastMessageId` returns `s_100` (the max).
4. Server replays from `s_100` for all streams.
5. Stream B misses messages `s_51` through `s_100`.

**Whether this is an actual bug depends on server-side replay behavior:**
- If the server replays per-stream regardless of `lastMessageId` → no issue.
- If the server uses `lastMessageId` as a global watermark → regression. Stream B has a permanent replay gap until the next full reconnect or explicit re-fetch.

**Risk:** Potential permanent message gap on lagging streams. Needs server-side verification.

---

## Part 4: Summary

### Original Findings Status

| Finding | Original Severity | Status |
|---|---|---|
| **TS-1** | BLOCKING | **FIXED** |
| TS-2 | MINOR | Unchanged (acceptable) |
| **TS-3** | MINOR | **FIXED** |
| TS-4 | LOW | Unchanged (see TS-10 for expanded analysis) |
| TS-5 | COSMETIC | Unchanged |
| TS-6 | INFO | Unchanged |
| TS-7 | INFO | Unchanged |
| **TS-8** | LOW | **FIXED** |

### Acceptance Checks

**25/25 PASS** (up from 23 PASS, 1 FAIL, 1 CONDITIONAL)

### New Issues

| Finding | Severity | Introduced by fix? | Self-corrects? | Action |
|---|---|---|---|---|
| TS-9: Missing snapshot refresh in bubble compensation | LOW | Pattern gap from `1894f6927` | Yes | Optional fix (one-liner) |
| **TS-10**: Morph animation unguarded | **MEDIUM** | No (pre-existing, missed by fixes) | Partially | Recommended fix |
| TS-11: scheduleReconfigure/Invalidation unguarded | LOW | No (pre-existing) | Yes | No action needed |
| TS-12: scrollToBottom animated stale snapshot | LOW | No (pre-existing) | Yes | No action needed |
| TS-13: Re-read SBB emit without force | LOW | Side effect of TS-3 fix | Yes | No action needed |
| **TS-14**: replayCursorsBySessionKey: nil | **MEDIUM** | Yes (`c3ea60a65`) | No | **Needs server-side verification** |

### Bottom Line

The three blocking/notable fixes (TS-1, TS-3, TS-8) are correctly implemented. All 25 acceptance checks pass. The branch is in materially better shape than the prior audit.

Two medium-severity items warrant attention:
1. **TS-10** (morph session guard) — pre-existing but a real cross-session mutation risk in a 2-second window. Same fix pattern as TS-8.
2. **TS-14** (replay cursor nil) — introduced by fix commit `c3ea60a65`. Whether it's actually a bug depends on server-side replay semantics. If the server uses `lastMessageId` as a global watermark, lagging streams will have permanent replay gaps.

No new blocking issues. The transition surface is stable.
