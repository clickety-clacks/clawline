# T113 Phase 1 Adversarial Review

**Date:** 2026-02-24
**Reviewer:** Opus (architecture agent, per-stream-state branch)
**Commit reviewed:** `c110f5618` ("Implement T113 phase 1 stream-state and cursor gates")
**Spec:** `/Users/mike/shared-workspace/clawline/specs/per-stream-state-encapsulation.md`
**Architecture plan:** `/Users/mike/shared-workspace/clawline/specs/t113-architecture-plan.md`
**Branch:** `per-stream-state` (16 commits ahead of main, clean working tree)

---

## Phase 1 Completion Gate Results

### Gate 1: forceReRead flows from ChatViewModel → ChatView → controller

**PASS**

Evidence:

- `ChatViewModel.swift`: `forceReReadGenerationBySession: [String: Int]` replaces removed `lastServerMessageIdBySession`. Public reader `forceReReadGeneration(for:)` and private `armForceReRead(for:)` exist.
- `armForceReRead` called in 4 places: reconnect (all sessions), cache restore, cursor clear, and implicitly via the reconnect path for Siri.
- `ChatView.swift:934`: `forceReReadGeneration: viewModel.forceReReadGeneration(for: sessionKey)` — NOT hardcoded false.
- `ChatView.swift:1078`: same call for prewarm shells.
- `MessageFlowCollectionView.swift`: `forceReReadGeneration: Int = 0` parameter on struct and `update(...)` method. Passed to `runStreamContextSwitchSeam`.
- `runStreamContextSwitchSeam` compares `forceReReadGeneration > incomingState.lastSeenForceReReadGeneration` to detect same-key re-read, triggers `prepareSameKeyReread` which bumps generation, reloads persisted state, and resets `restorePhase = .pendingTail`.
- Preview controller passes `forceReReadGeneration: 0` (correct — previews should not trigger re-reads).

End-to-end signal path is complete and functional.

---

### Gate 2: One-shot callback registry implemented and used for restore

**PASS**

Evidence:

- `PerStreamRuntimeState.registeredMessageLoadCallbacksByMessageId: [String: [MessageLoadCallback]]` — field present.
- `registerOnMessageLoad(sessionKey:messageId:callback:)` — guards non-empty key/id, guards `callbackSessionKey() == sessionKey`, fires immediately if `isMessageMaterialized`, otherwise appends to registry.
- `fireRegisteredMessageLoadCallbacksIfMaterialized(for:messageIds:)` — called in `afterSnapshotApplied` closure. Checks layout attributes, removes callbacks before firing (one-shot). Guards `callbackSessionKey() == sessionKey`.
- `clearRegisteredMessageLoadCallbacks(for:)` — called during switch-out in `runStreamContextSwitchSeam`. Expires all outgoing callbacks.
- `expireRegisteredMessageLoadCallbacks(for:messageIds:)` — called when messages are removed from dataset. Expires callbacks for deleted messages.
- `isMessageMaterialized(sessionKey:messageId:)` — checks `dataSource.indexPath(for:)` + `layoutAttributesForItem(at:)` after `layoutIfNeeded()`.

Registration call sites (4 total):
1. `scheduleRestoreAttemptOnMessageAppearance` — triggers `attemptRestoreScrollIfNeeded(token:)` on message materialization.
2. `flashMessage(messageId:isUnreadTap:)` — triggers `performPendingFlashIfPossible()`.
3. `checkFirstUnreadCrossingIfNeeded()` — when unread anchor is outside tail window, registers callback for re-check on materialization.
4. `scrollToMessageCentered(messageId:animated:)` — retries scroll-to-message when target isn't yet in data source.

Spec compliance:
- One-shot: callbacks removed from dict before firing. ✓
- Fire immediately if materialized: checked in `registerOnMessageLoad`. ✓
- Expire on switch-away: `clearRegisteredMessageLoadCallbacks` in seam. ✓
- Expire on message deletion: `expireRegisteredMessageLoadCallbacks` on removed IDs. ✓
- Allowed uses (scroll-to-message, flash/highlight, unread anchor): all 4 call sites match. ✓
- Disallowed uses (geometric restore fallback, event bus): not present. ✓

---

### Gate 3: Canonical auth cursor — nil when incomplete, max when complete, no bias

**PASS**

Evidence:

- `ProviderChatService.resolveAuthLastMessageId(replayCursorSnapshot:knownSessionKeys:)`:
  ```swift
  let normalizedKnownKeys = knownSessionKeys
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  guard normalizedKnownKeys.allSatisfy({ replayCursorSnapshot[$0]?.isEmpty == false }) else {
      return nil   // <-- nil when ANY known session lacks cursor
  }
  return replayCursorSnapshot.values.max()   // <-- max when ALL complete
  ```

- No `activeSessionKey` parameter in `resolveAuthLastMessageId`. No active-session-first bias anywhere.
- `knownSessionKeys` tracked from `handleSessionInfo`, `handleStreamSnapshot`, `handleStreamDeleted`.
- `replayCursorBySessionKey` pruned on `handleStreamSnapshot` (stale keys removed).
- Cursor advanced per-stream on each `s_` prefixed message in `handleMessagePayload`.
- Cursor persisted to `UserDefaults` under user+device-scoped key.
- `ChatViewModel` stripped of `lastServerMessageIdBySession`; all cursor writes go through `chatService.setReplayCursor(...)`.
- No WebSocket URL cleanup in diff (embellishment was correctly excluded).

Architecture plan rules satisfied:
- Active-session-first cursor selection: ABSENT. ✓
- Global fallback to engineActiveSessionKey cursor: ABSENT. ✓
- Sending max-cursor when any stream lacks cursor: returns nil instead. ✓
- Per-stream cursors sent in auth only when ALL sessions have cursors. ✓

---

### Gate 4: Timer callbacks validate (sessionKey, generation) not just key

**FAIL — 1 of 5 timer types missing both cancellation and generation guard**

Four timer types correctly use `activeSessionGenerationToken()` capture + generation validation:

| Timer | Token capture | Generation check in callback | Cancel in `cancelDeferredWork` |
|---|---|---|---|
| `scheduleBottomInsetHeightCapInvalidation` | ✓ `activeSessionGenerationToken()` | ✓ `readState(for: token.sessionKey).restoreGeneration == token.generation` | ✓ `pendingBottomInsetHeightCapInvalidation?.cancel()` |
| `scheduleDeferredBottomInsetRemeasure` | ✓ `activeSessionGenerationToken()` | ✓ same pattern | ✓ `bottomInsetRemeasureTimer?.invalidate()` |
| `scheduleBubbleSizingV2Remeasure` | ✓ `activeSessionGenerationToken()` | ✓ same pattern | ✓ `bubbleSizingV2RemeasureDebounceTimer?.invalidate()` |
| `scheduleBubbleSizingV2DeferredFlushAfterRest` | ✓ `activeSessionGenerationToken()` | ✓ same pattern | ✓ `bubbleSizingV2DeferredFlushTimer?.invalidate()` |
| **`schedulePersistScrollState`** | **✗ captures sessionKey only** | **✗ no generation check** | **✗ NOT cancelled in `cancelDeferredWork`** |

**The scroll persistence debounce timer is the only timer not generation-guarded and not cancelled on switch.**

This is a spec violation of two rules:

1. **Flush-on-switch contract (spec section "Flush-on-switch contract"):** "On stream-context switch, outgoing key must always flush immediately **and cancel its debounce timer.**"

   The immediate flush happens (step 2: `persistScrollStateNow(sessionKey: outgoingKey, bypassSuspension: true)`). But the outgoing session's debounce timer is NOT cancelled. It can fire after the switch.

2. **Timer / Queue Ownership rule 2:** "Timer callback validates both owning `sessionKey` and owning generation token before mutating state."

   The timer captures `sessionKey` but not generation. Its callback calls `persistScrollStateNow(sessionKey:)`.

**Impact:** After a stream switch, the outgoing session's debounce timer fires within 0.35s. It calls `persistScrollStateNow(sessionKey: outgoingKey)`. This reads **live geometry from the collection view**, which now displays the **incoming session's content**. It writes that geometry as the outgoing session's persisted scroll position, **overwriting the correct data that was just flushed in step 2**.

This is a data corruption bug: the outgoing session's persisted scroll position gets replaced with the incoming session's geometry.

**Fix required (two changes):**
1. Add `scrollStateWriteDebounceTimer` to `cancelDeferredWork`:
   ```swift
   state.scrollStateWriteDebounceTimer?.invalidate()
   state.scrollStateWriteDebounceTimer = nil
   ```
2. Either: add generation token to `schedulePersistScrollState` callback (matching the pattern used by the other 4 timers), OR rely on cancellation alone (since the spec explicitly requires cancellation for this specific timer).

Option 1 (cancellation only) is sufficient because the spec says "flush immediately and cancel" — the flush writes correct data and cancellation prevents the late overwrite. Generation-guarding would be defense-in-depth.

---

### Gate 5: Spec text updated with adversarial review resolutions

**PASS**

Evidence: `per-stream-state-encapsulation.md` was modified on Feb 24 12:57:45. Lines 73-79 contain "Adversarial Review Resolution Notes" covering all 5 blocking findings:

- Line 75: `lastAppliedEffectiveSessionKey` definition and update point. ✓
- Line 76: Scroll delegate callback key-binding rule. ✓
- Line 77: Restore phase stage-aware initialization. ✓
- Line 78: Incoming SBB initialization from persisted `atBottom`. ✓
- Line 79: Coordinator unfreeze obligation. ✓

Step 6 text (lines 51-56) updated with stage-aware restore phase logic. ✓
Offscreen/Frozen Rule (lines 66-71) updated with coordinator obligation and implementation ordering constraint. ✓

---

### Gate 6: Per-stream-state spec acceptance checks 1-25

| # | Description | Verdict | Evidence |
|---|---|---|---|
| 1 | Stream A scrolled-up → switch B → switch back A: A restores previous position and SBB state | **PASS** | `runStreamContextSwitchSeam` flushes A on switch-out, `prepareIncomingStateOnSwitch` loads persisted state and sets SBB from `atBottom` on switch-back. `PerStreamRuntimeState` preserves A's entry across the switch. |
| 2 | First activation with tail→full materialization: persisted restore target resolves correctly after full-stage retry | **PASS** | `restorePhase` starts `.pendingTail`, promotes to `.pendingFullConfirmation` on tail-stage attempt that can't confirm, retries on full-stage with bounded 3-attempt limit. `scheduleRestoreAttemptOnMessageAppearance` uses callback registry for event-driven trigger. |
| 3 | Pending debounce/timers from A do not mutate B after switch | **PARTIAL FAIL** | 4 of 5 timer types have generation guards. `scrollStateWriteDebounceTimer` lacks both cancellation in `cancelDeferredWork` and generation guard — can write A's key with B's geometry after switch. See Gate 4. |
| 4 | Drag/morph deferral from A does not auto-scroll B | **PASS** | `pendingScrollToBottomAfterInteractionEnd`, `morphTargetMessageId`, `deferScrollToBottomUntilMorphCompletes` are per-stream. Morph completion callback guards `callbackSessionKey()`. `performPendingDeferredScrollToBottomIfNeeded(sessionKey:)` takes explicit key. |
| 5 | SBB is correct immediately after switch when incoming stream is not at bottom | **PASS** | `prepareIncomingStateOnSwitch` sets `sbbState = .scrolledUp` (or `.scrolledUpUnread`) when `!persistedState.atBottom`. This happens before any layout/inset pass. |
| 6 | Same-key re-read re-arms restore and lands at persisted position | **PASS** | `prepareSameKeyReread` bumps `restoreGeneration`, reloads persisted state, resets `restorePhase = .pendingTail`, sets `suspendScrollPersistenceUntilRestoreConfirmed = true`. |
| 7 | No persisted state path starts at bottom; no inherited pinned/scrolled state from prior stream | **PASS** | When `persistedState == nil`, `prepareIncomingStateOnSwitch` sets `sbbState = .atBottom` and `restorePhase = .none` (deterministic bottom fallback). No inheritance from prior stream. |
| 8 | Frozen render / unfreeze path does not expose stale prior-stream SBB or scroll runtime | **PASS** | Seam steps 1-6 run before `isRenderPolicyFrozen` guard (implementation ordering constraint). Spec updated with coordinator unfreeze obligation (line 71). |
| 9 | Prewarm/offscreen pages do not mutate active-stream runtime and do not skip context normalization | **PASS** | Seam runs before offscreen early return. Prewarm shells get `forceReReadGeneration: 0` from preview controller. `callbackSessionKey()` guards all mutation paths. |
| 10 | Message-ID collisions across streams do not cross-contaminate caches/queues | **PASS** | `BubbleSizingV2.CacheKey` includes `sessionKey`. All per-stream caches (`fingerprints`, `sizeCache`, `lastMeasuredSizes`, etc.) are inside `PerStreamRuntimeState` entries keyed by `sessionKey`. |
| 11 | Stream switch while restore is `pendingFullConfirmation` does not apply stale retry into new stream context | **PASS** | `attemptRestoreScrollIfNeeded(token:)` validates `callbackSessionKey() == token.sessionKey` AND `runtimeState.restoreGeneration == token.generation`. Stale token → early return. |
| 12 | Async size changes after full-stage expansion do not strand restore mid-stream; bounded confirmation retries converge | **PASS** | `restoreConfirmationRetries` counts attempts. After 3 (`restoreMaxConfirmationRetries`), deterministic bottom fallback applied. `restorePhase = .confirmed`. |
| 13 | Deleted stream keys are pruned; no stale timers/callbacks mutate recreated or other streams | **PASS** | `prunePerStreamState(validSessionKeys:)` calls `cancelDeferredWork(for:cancelAll:true)` then removes entry. Cursor pruned in `handleStreamSnapshot` and `handleStreamDeleted`. |
| 14 | Any mutation callback without explicit resolved `sessionKey` no-ops | **PASS** | All UIScrollViewDelegate callbacks guard `callbackSessionKey() else { return }`. All session-keyed wrappers guard non-empty key. `mutateState(for:)` requires explicit key. |
| 15 | Same-key re-read does not overwrite persisted anchor before restore confirmation | **PASS** | `suspendScrollPersistenceUntilRestoreConfirmed = true` set in `prepareSameKeyReread`. `schedulePersistScrollState` checks this flag and returns early when suspended. `persistScrollStateNow` checks `bypassSuspension` flag. |
| 16 | Stream switch from A to B: B update classification uses B's per-stream `lastMessageId` | **PASS** | `lastMessageId` is per-stream (in `PerStreamRuntimeState`). After switch, `lastAppliedEffectiveSessionKey = B`, so computed-property shim reads B's entry. |
| 17 | Frozen→unfrozen transition triggers follow-up `update(...)` and pending restore progresses | **PASS (spec obligation)** | Spec updated (line 71) with coordinator obligation. Implementation ordering ensures seam runs before frozen guard. Coordinator-side implementation is existing ChatView behavior. |
| 18 | Scroll delegate callbacks during seam execution mutate outgoing stream entry, never incoming early | **PASS** | `callbackSessionKey()` returns `lastAppliedEffectiveSessionKey`. In `runStreamContextSwitchSeam`, `lastAppliedEffectiveSessionKey` is set to `incomingSessionKey` only AFTER all outgoing work (flush, cancel, prepare) completes. Callbacks during seam target outgoing key. |
| 19 | Replay cursor progress is isolated per stream on initial login/bootstrap | **PASS** | `setReplayCursor(message.id, for: sessionKey)` called per-message with explicit `sessionKey` in `handleMessagePayload`. No global cursor. |
| 20 | Concurrent replay across streams cannot advance sibling stream cursor state | **PASS** | `setReplayCursor` writes only to `replayCursorBySessionKey[trimmedKey]`. No cross-stream mutation. |
| 21 | Replay callbacks with stale `(sessionKey, generation)` no-op | **PASS** | UI restore callbacks validate `(sessionKey, generation)` via `RestoreAttemptToken`. Cursor writes are per-key (not generation-gated, but per-key writes are idempotent for cursors). |
| 22 | Message writes remain exclusively in T105 canonical insertion seam; no direct message-store writes introduced | **PASS** | Branch introduces no new `sessionMessages` writes. Cursor writes moved to `chatService.setReplayCursor(...)`. All existing direct writes are pre-existing (T105 scope). |
| 23 | On-message-load callback registry: fires once, fires if materialized, expires on switch/deletion | **PASS** | See Gate 2 analysis. All 5 behavioral requirements verified. |
| 24 | Reload trigger normalization: cache restore, reconnect, cursor clear, Siri arm forceReRead | **PASS** | `armForceReRead` called in: reconnect (all sessions), `restoreCachedMessagesIfNeeded` (per session), `clearCursor(for:)` (per session). Siri path goes through connect which triggers reconnect arming. |
| 25 | Transport replay cursor storage owned by transport layer; ChatViewModel holds no cursor persistence | **PASS** | `lastServerMessageIdBySession` removed from ChatViewModel. `persistLastServerMessageId` / `restoreLastServerMessageIdIfNeeded` removed. All persistence in `ProviderChatService.replayCursorBySessionKey` with UserDefaults. |

**Score: 24/25 PASS, 1 PARTIAL FAIL (check 3)**

---

## Additional Findings (Non-Gate)

### Finding A: `prepareIncomingStateOnSwitch` uses unconditional `allowTailStage: true`

**Severity: MINOR**

The spec (step 6) says: "set incoming `restorePhase` by stage: `.pendingTail` when incoming materialization stage is tail-first, `.pendingFullConfirmation` when staging is not active or stage is already full."

The code calls `prepareIncomingStateOnSwitch(sessionKey:, allowTailStage: true)` unconditionally. For revisited streams (where staging is skipped), the phase starts as `.pendingTail` and is then corrected downstream:
```swift
withBoundSessionKey(effectiveSessionKey) {
    if restorePhase == .pendingTail && !isFirstActivationForSession {
        restorePhase = .pendingFullConfirmation
    }
}
```

This achieves the correct result but the initial phase assignment is wrong per the spec's step 6 contract. During the window between the seam (step 6) and the downstream correction (step 7), the phase is `.pendingTail` when it should be `.pendingFullConfirmation`.

In practice this is harmless — no restore attempt fires in that window. But if `isRenderPolicyFrozen` suppresses step 7, the phase stays wrong until unfreeze. The correction should happen in `prepareIncomingStateOnSwitch` by checking `materializationStateBySessionKey[sessionKey]`:

```swift
let isRevisit = materializationStateBySessionKey[sessionKey] != nil
state.restorePhase = (isRevisit || !allowTailStage) ? .pendingFullConfirmation : .pendingTail
```

### Finding B: `prepareSameKeyReread` uses `+= 1` while switch path uses `&+= 1`

**Severity: COSMETIC**

`prepareSameKeyReread`: `state.restoreGeneration += 1` (trapping on overflow)
`runStreamContextSwitchSeam` switch path: `state.restoreGeneration &+= 1` (wrapping on overflow)

Functionally irrelevant (generation values won't approach `Int.max`), but the inconsistency could confuse future agents.

### Finding C: Transitional shims lack documentation markers

**Severity: MINOR**

The architecture plan (Section 8) says: "Every shim accessor is marked with `// MIGRATION SHIM — remove when all callers pass explicit sessionKey`." No such markers exist in the code. The shims are present but undocumented, which means future agents won't know they're transitional and will copy the keyless-access pattern.

### Finding D: `messagesById` classification gap from adversarial review persists

**Severity: MINOR**

The adversarial review (Finding 1.3) noted that `messagesById` is not classified in the spec — neither as per-stream nor as controller-scope. It remains a controller-global `private var messagesById: [String: Message]` that is overwritten wholesale on each `update(...)`. This is functionally correct (it's a last-applied snapshot, not accumulated state), but the spec should classify it explicitly.

---

## Summary

| Gate | Verdict |
|---|---|
| 1. forceReRead end-to-end | **PASS** |
| 2. One-shot callback registry | **PASS** |
| 3. Canonical auth cursor | **PASS** |
| 4. Timer generation validation | **FAIL** — `scrollStateWriteDebounceTimer` not cancelled on switch, no generation guard |
| 5. Spec text updated | **PASS** |
| 6. Acceptance checks 1-25 | **24/25 PASS** — check 3 partial fail (same root cause as Gate 4) |

**Blocking fix required (1):**
- Add `scrollStateWriteDebounceTimer` invalidation to `cancelDeferredWork(for:cancelAll:)`.

**Recommended fixes (non-blocking):**
- Finding A: Check materialization state in `prepareIncomingStateOnSwitch` instead of unconditional `allowTailStage: true`.
- Finding B: Use consistent `&+= 1` in both generation increment paths.
- Finding C: Add `// MIGRATION SHIM` markers to all transitional computed properties.
- Finding D: Classify `messagesById` in the spec as controller-scope.
