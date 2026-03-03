# T100 Connection Lifecycle — Independent Adversarial Review

Date: 2026-02-26
Branch: `per-stream-state` at `b82df6659`
Spec: `/Users/mike/shared-workspace/clawline/specs/connection-lifecycle.md`
Reviewer: Independent (did not author the implementation)

## Scorecard: Acceptance Criteria

| # | Criterion | Verdict | Evidence |
|---|-----------|---------|----------|
| AC1 | Exactly one phase-transition write seam (coordinator) | **PASS** | `ConnectionLifecycleCoordinator.transition()` at coordinator:596 is the sole phase-mutation path. All 24 legal transitions validated in `isLegalTransition` at coordinator:622-649. |
| AC2 | ChatViewModel no longer schedules reconnect directly | **PASS** | Zero matches for `scheduleReconnect`/`reconnectTimer` in ChatViewModel. All reconnect intents delegate to coordinator: `manualRetry()` (CVM:464), `appDidBecomeActive()` (CVM:505), `reconnectIntentTransportInterrupted()` (CVM:1502). |
| AC3 | All lifecycle event entrypoints epoch-scoped; stale events ignored | **PASS** | `handleTransportEvent` at coordinator:236 checks `event.epoch == currentEpoch` and `phase != .idle && phase != .failed`. Stale events logged at coordinator:237. |
| AC4 | Replay gate prevents `live` until replay completion | **PASS** | `completeReplay` at coordinator:499-519 is the only path to `transition(to: .live)`. It fires only when `replayRemainingCount` reaches 0. |
| AC5 | `auth_result` replay metadata decoding present and validated | **PASS** | `handleAuthResult` at coordinator:294-357 validates `replayCount >= 0` (fails to `.protocolMismatch` otherwise), defaults `replayTruncated` to false, defaults `historyReset` to false. |
| AC6 | `replayCount=0` deterministically emits start+complete → live | **PASS** | `beginReplay` at coordinator:376-378: if `replayExpectedCount == 0`, calls `completeReplay` immediately after emitting `replayStarted`. |
| AC7 | Late cache restore cannot overwrite replay-applied messages/cursor | **PASS** | CVM:1717-1719: `guard writerCurrentEpoch == epoch, firstReplayAppliedEpoch != epoch`. CVM:877-879: `handleLifecycleServerMessage` sets `firstReplayAppliedEpoch = epoch` and cancels all restore tasks before processing replay data. |
| AC8 | Cursor for reconnect snapshot from canonical writer-owned state | **PASS** | Coordinator stores `canonicalCursor` actor-locally (coordinator:103). `startConnecting` at coordinator:551 reads `canonicalCursor` synchronously — no `await @MainActor` fetch. Writer pushes updates via `updateCanonicalCursor` (CVM:891, CVM:1725). |
| AC9 | `session_replaced` → `failed`; no auto-reconnect | **PASS** | Coordinator:304-305 (`failureReason == .sessionReplaced → fail(.sessionReplaced)`). `fail()` at coordinator:521-528 cancels reconnect task for sessionReplaced. `manualRetry()` at coordinator:204-218 is the only re-entry from `failed`. |
| AC10 | App background/foreground follow coordinator contract | **PASS** | `appDidEnterBackground` at coordinator:184 cancels timers, stops attempt, calls `moveToIdleIfNeeded`. `moveToIdleIfNeeded` at coordinator:613-619 explicitly skips `failed` phase. `appDidBecomeActive` at coordinator:165-181 implements <2s cooldown, >=60s counter reset, failed-no-auto-retry. |
| AC11 | Single-writer audit: writes confined to ConversationStoreWriter | **FAIL** | No `ConversationStoreWriter` type exists. See F3 below. |
| AC12 | iOS app target builds after integration | **NOT VERIFIED** | Build not executed during this review. |

**Score: 10/12 criteria PASS, 1 FAIL, 1 NOT VERIFIED**

---

## Previously-Identified Issues

### F3: No ConversationStoreWriter formal type — CONFIRMED FAIL

**Spec requirement** (lines 86-88): "All message/cursor/store mutations flow through one seam: `ConversationStoreWriter` (nested, `@MainActor`, 1:1 owned by `ChatViewModel`)."

**Finding:** Zero matches for `ConversationStoreWriter` anywhere in the codebase. Writer seam is implemented as ad-hoc epoch-gated methods directly in ChatViewModel (`handleLifecycleServerMessage`, `handleHistoryResetRequired`, `handleLifecycleOutput`). The epoch-gating logic (`writerCurrentEpoch`, `firstReplayAppliedEpoch`) works correctly but lacks the formal type boundary the spec requires.

**Impact:** Without a formal writer type, there is no compile-time enforcement of the write-seam boundary. Store mutations are scattered across 20+ call sites in ChatViewModel. Any new code can bypass the writer seam without triggering review friction.

**Evidence:**
- `sessionMessages` mutated directly at CVM:900, CVM:1111
- `messages` mutated directly at CVM:244, CVM:257, CVM:901, CVM:1101, CVM:1909, CVM:1955
- `pendingLocalMessages` mutated directly at CVM:621, CVM:902, CVM:1127, CVM:1181, CVM:1491
- `messageFailures` mutated directly at CVM:903, CVM:1129, CVM:1179, CVM:1489

### F4: No canonical cursor persistence (debounced 500ms) — CONFIRMED FAIL

**Spec requirement** (lines 372-376): "Writer persists canonical auth cursor using user/device-scoped key. Persistence timing: update persisted canonical cursor after each successful replay/live server-message apply (debounced max 500ms). On app launch/auth bootstrap, writer restores persisted canonical cursor before first reconnect attempt."

**Finding:** The canonical cursor lives only in coordinator actor-local memory (`coordinator:103 canonicalCursor`). There is no persistence of the canonical auth cursor. The coordinator's `seedCanonicalCursor` at CVM:476-479 reads from `chatService.replayCursorSnapshot().values.max()` — this is the per-stream replay cursor snapshot from `ProviderChatService`, NOT a dedicated canonical cursor persistence key.

Message content persistence exists with 500ms debounce (`persistMessages` at CVM:1746-1768), but that persists message payloads, not the canonical auth cursor separately.

**Impact:** On app kill/relaunch, the canonical cursor is reconstructed from per-stream replay cursors rather than from a persisted canonical value. If the per-stream cursors are stale or incomplete, the canonical cursor at relaunch may diverge from the last known-good value.

### F5: StreamSwitchCoordinator.reset() not called on history reset — CONFIRMED FAIL

**Spec requirement** (lines 279-281): "ChatViewModel invokes `StreamSwitchCoordinator.reset()` on that completion before forwarding subsequent replay apply for the same epoch."

**Finding:** `handleHistoryResetRequired(epoch:)` at CVM:899-910 clears message state (sessionMessages, messages, pendingLocalMessages, messageFailures) and cursors, but does NOT call `StreamSwitchCoordinator.reset()`. Zero matches for `.reset()` in ChatViewModel.

**Impact:** On a provider-authoritative history reset, stale/phantom stream metadata (streamsBySessionKey, orderedSessionKeys) survives. The UI may show streams that no longer exist on the server.

### F6: No user mutation queue (50-cap) — CONFIRMED FAIL

**Spec requirement** (lines 348-351): "`writerCurrentEpoch` initializes as `nil`; user-initiated local mutations are queued until first epoch-bearing lifecycle output arrives. Queue cap is 50 pending user mutations; overflowed operations are dropped with user-visible error feedback."

**Finding:** Zero matches for mutation queue, 50-cap, or overflow error feedback in ChatViewModel. `writerCurrentEpoch` exists (CVM:330) and is updated in `handleLifecycleOutput` (CVM:1135-1136), but user-initiated sends (CVM:564-631) proceed directly without epoch-gating or queuing.

**Impact:** User sends attempted before the first lifecycle epoch is established are not queued. In practice, the `canSend` guard at CVM:280-282 (checking `sendButtonConnectionState == .connected`) partially mitigates this because the button is disabled until `live`, but the spec's explicit queue mechanism is absent.

### F7: Cursor writes outside writer seam — CONFIRMED (corollary of F3)

**Spec requirement** (line 379): "remove cursor writes outside writer seam."

**Finding:** Since no writer seam exists (F3), all cursor writes are technically "outside" it:
- `chatService.setReplayCursor(cachedLast, ...)` at CVM:1723 (inside cache restore)
- `chatService.setReplayCursor(nil, ...)` at CVM:1740, CVM:1893, CVM:1935
- `lifecycleCoordinator.updateCanonicalCursor(message.id)` at CVM:891
- `lifecycleCoordinator.updateCanonicalCursor(nil)` at CVM:907, CVM:1741

The canonical cursor updates do flow through coordinator's actor-isolated `updateCanonicalCursor`, which provides correct isolation. But per-stream replay cursors are mutated directly via `chatService.setReplayCursor(...)` from multiple ChatViewModel call sites, with no writer type boundary.

### C1: Dual event paths in ProviderChatService — CONFIRMED, MEDIUM SEVERITY

**Spec requirement** (line 338): "Replay/live server messages are delivered to writer only as `LifecycleOutput.serverMessage(epoch,payload)` on this same stream (no direct service-to-writer path)."

**Finding:** Two dual-emission paths exist:

**1. Message path (PCS:663-681):**
When `lifecycleEpoch` is non-nil, `handleMessage` emits the raw data to `lifecycleTransportEventBroadcaster` (PCS:665) AND the decoded `Message` to `messageBroadcaster` (PCS:680) unconditionally.

**Mitigant:** ChatViewModel no longer subscribes to `incomingMessages` — confirmed zero matches. The `messageBroadcaster.send()` is dead code for the lifecycle consumer. However, `incomingMessages` remains part of the `ChatServicing` protocol (protocol:56), so any future subscriber would receive un-epoch-gated messages.

**2. Transport-close path (PCS:981-1040):**
Socket close emits BOTH `emitLifecycleEvent(.transportClosed(...))` (PCS:1021/1035) AND `emitServiceEvent(.connectionInterrupted(...))` (PCS:1018/1027). ChatViewModel handles the service event at CVM:1499-1502 and calls `lifecycleCoordinator.reconnectIntentTransportInterrupted()`. This creates two paths to the coordinator for the same transport close:
  - Path A: `lifecycleTransportEvents` → `handleTransportEvent` → `handleTransportInterrupted`
  - Path B: `serviceEvents` → `connectionInterrupted` → `reconnectIntentTransportInterrupted`

Both can trigger `transition(to: .recovering)`. Epoch gating prevents double-transition (second path finds phase already `recovering`), but this is fragile and spec-violating.

**3. Auth timeout (PCS:209, PCS:1119-1121):**
`ProviderChatService` retains `authTimeout: Duration = .seconds(12)` and a competing timeout in `awaitAuthResult` (PCS:1082-1129). This is only called from the legacy `connectInternal` path, NOT the lifecycle path. But the spec (lines 131-133) says "ProviderChatService must not independently enforce its own auth timeout." The constant and mechanism remain in code.

---

## Race Fix (b82df6659) Assessment

**Transport events race: FIXED**

The fix creates `lifecycleTransportEventsSubscription` synchronously in `startObserving()` (CVM:522) before any Task that calls `startIfNeeded()`. The subscription is a pre-created `AsyncStream` stored as an instance property, so events emitted by `ProviderChatService` after `startConnectionAttempt` are buffered in the stream regardless of when the consuming `for await` loop begins.

**Lifecycle outputs race: NOT FULLY FIXED**

The `outputs` subscription is created asynchronously in `observeLifecycleOutputs()` (CVM:551: `let outputs = await lifecycleCoordinator.outputs`). This crosses the actor boundary. Meanwhile, `startIfNeeded()` is called from a separate `Task` (CVM:480). Both Tasks compete for actor access:

- If `observeLifecycleOutputs` reaches the actor first → continuation is set → subsequent outputs buffered → correct
- If `startIfNeeded` reaches the actor first → `emit()` fires with `continuation == nil` → outputs dropped → phase transition and restoreCacheRequested lost

The `AsyncStream(bufferingPolicy: .unbounded)` build closure runs synchronously during `init` (sets continuation immediately), so once `outputs` is accessed, the continuation is live. The race window is between Task creation and first actor access.

**Practical risk:** Low in most scenarios (the observation Task is created before the lifecycle Task on the same `@MainActor`, so in typical FIFO scheduling it wins the actor race), but not guaranteed by Swift Concurrency semantics.

---

## Epoch Ownership Assessment

**Does coordinator own epoch and pass to service?** YES.

- Epoch increments at coordinator:541 (`currentEpoch += 1`)
- Passed to service synchronously at coordinator:551 (`startAttempt(epoch, canonicalCursor, authToken)`)
- No `await` between increment and dispatch (coordinator:541-551 is synchronous)
- Service captures epoch in `startConnectionAttempt` (PCS:353) and threads it through all callbacks via `startLifecycleListening(on:epoch:)` (PCS:579)

**Does service echo it?** YES.

- Every `emitLifecycleEvent(epoch:payload:)` call uses the captured epoch from `startLifecycleListening`
- Auth results, server messages, transport close all carry the correct epoch

---

## Terminal Events Assessment

**Are session_replaced/token_revoked handled from ANY active phase?** YES.

In `handleAuthResult` (coordinator:294-319), the `!success` branch with known failure reasons calls `fail()` BEFORE the `guard phase == .authenticating` check at coordinator:320. So terminal auth failures (session_replaced, token_revoked, rejected, protocol_mismatch) trigger `fail()` regardless of current phase.

Flow for terminal event during `live`:
1. Server sends error (e.g., "session_replaced")
2. `ProviderChatService.handleServerError` emits `authResult(success: false, failureReason: .sessionReplaced)` (PCS:758-768)
3. Coordinator `handleTransportEvent` passes phase guard (`live != idle, live != failed`)
4. `handleAuthResult` → `!success` → `failureReason == .sessionReplaced` → `fail(.sessionReplaced)`
5. `transition(to: .failed)` → `isLegalTransition(.live, .failed)` = true

This also works from `recovering` phase (`isLegalTransition(.recovering, .failed)` = true).

---

## Background/Failed Assessment

**Does background NOT transition failed to idle?** YES, CORRECT.

`moveToIdleIfNeeded` at coordinator:613-619:
```swift
case .idle, .failed:
    break
```
When phase is `.failed`, backgrounding does nothing. Only explicit `disconnectRequested()` or `manualRetry()` can exit `failed`.

---

## Additional Findings

### Keepalive not implemented

Spec (lines 456-459) assigns ping/pong keepalive timing to `URLSessionWebSocketConnector`. The connector is correctly transport-only (no lifecycle decisions, no reconnect scheduling), but keepalive is entirely absent. No `sendPing`, no periodic timer, no heartbeat anywhere in the codebase. The `TransportCloseReason.keepaliveTimeout` case exists but is only classified reactively from server close reasons (PCS:1032).

### Legacy connect path still exists

`ProviderChatService` retains `connectInternal` (PCS:304-351) alongside `startConnectionAttempt` (PCS:353-358). The legacy path manages its own state (`updateState(.connecting)`, `.connected`, `.failed`), has its own auth timeout, and bypasses the coordinator entirely. It's used by `SiriSendMessageIntent`. This is a maintenance hazard — two parallel connection paths with different lifecycle semantics.

### `handleIncoming` in CVM is not epoch-gated

`handleLifecycleServerMessage` at CVM:876-892 calls `handleIncoming(message)` at CVM:889 without checking `writerCurrentEpoch`. The epoch check for server messages relies on the coordinator's epoch gating (coordinator:236) and the `firstReplayAppliedEpoch` gate (CVM:877) for cache-vs-replay precedence. For lifecycle-sourced messages, coordinator epoch gating is sufficient. But `handleIncoming` itself is also called from other paths (e.g., interactive callback responses) that may not be epoch-gated.

---

## Summary

**Overall: 10/12 acceptance criteria PASS. Implementation captures the core lifecycle authority pattern correctly but is missing four spec-required structural features.**

### Blocking gaps (must fix for spec compliance):
1. **F3: ConversationStoreWriter** — No formal writer type. Store mutations scattered across ChatViewModel.
2. **F5: StreamSwitchCoordinator.reset()** — Not called on history reset. Stale stream metadata survives.
3. **F4: Canonical cursor persistence** — No debounced 500ms persistence of canonical auth cursor.

### Medium gaps (should fix):
4. **F6: User mutation queue (50-cap)** — No queue or overflow handling. Partially mitigated by UI guards.
5. **C1: Dual event paths** — Transport close triggers coordinator from two paths. Dead message broadcaster still fires.
6. **Lifecycle outputs race** — `outputs` subscription is async; window exists for dropped outputs before subscription.

### Low/future:
7. **Keepalive** — Not implemented. Spec assigns it to connector.
8. **Legacy connect path** — Parallel lifecycle-unaware connection path persists for Siri intents.
