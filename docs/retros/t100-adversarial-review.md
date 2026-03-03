# T100 Connection Lifecycle — Adversarial Implementation Review

**Spec:** `specs/connection-lifecycle.md`
**Commit:** `22e3faf1c` on `per-stream-state` branch
**Transition surface contract:** `specs/per-stream-transition-surface-contract.md`
**Date:** 2026-02-25
**Reviewer:** Claude (adversarial review agent)

---

## Score: 33/40 criteria verified PASS (7 FAIL)

Of the spec's 12 formal acceptance criteria: **9 PASS, 2 FAIL, 1 NOT VERIFIED**

| # | Criterion | Verdict |
|---|-----------|---------|
| AC1 | Single phase-transition write seam | PASS |
| AC2 | ChatViewModel no longer schedules reconnect | PASS |
| AC3 | All lifecycle events epoch-scoped; stale dropped | PASS |
| AC4 | Replay gate prevents live until completion | PASS |
| AC5 | auth_result replay metadata decoded/validated | PASS |
| AC6 | replayCount=0 deterministic path | PASS |
| AC7 | Late cache restore cannot overwrite replay | PASS |
| AC8 | Cursor from canonical writer-owned state | PASS |
| AC9 | session_replaced → failed, no auto-reconnect | PASS |
| AC10 | App background/foreground follow contract | **FAIL** |
| AC11 | Single-writer audit (ConversationStoreWriter) | **FAIL** |
| AC12 | iOS app target builds | NOT VERIFIED |

---

## CRITICAL: Terminal server events silently dropped during live/replaying phases

**Spec requirement (Terminal server-event override):** "Terminal server events force transition to `failed` from any active phase (`connecting`, `authenticating`, `replaying`, `live`). Terminal server events include: `auth_failed`, `token_revoked`, `session_replaced`, provider `error` event with `fatal: true`, and unrecoverable protocol mismatch."

**What happens:** `handleAuthResult()` at `ConnectionLifecycleCoordinator.swift:302` has:
```swift
guard phase == .authenticating else { return }
```

Terminal events (`session_replaced`, `token_revoked`, `auth_failed`) arriving during `live`, `replaying`, or `connecting` phase are **silently dropped**.

**Concrete failure scenario:** User is in `live` phase. Server sends `session_replaced`. ProviderChatService emits lifecycle event `.authResult(success: false, failureReason: .sessionReplaced)`. Coordinator drops it because phase is `live`. ProviderChatService also disconnects the socket, causing a `.transportClosed` event. Coordinator processes the transport close as a non-terminal interruption: `live → recovering → reconnect loop`. Result: **exactly the reconnect loop the spec was designed to prevent**.

**Fix:** Handle terminal failure reasons BEFORE the phase guard. Extract terminal event detection:
```swift
private func handleAuthResult(...) {
    // Terminal events override from any active phase
    if !success, let reason = failureReason,
       [.sessionReplaced, .tokenRevoked].contains(reason) {
        fail(mapFailureReason(reason))
        return
    }
    guard phase == .authenticating else { return }
    // ... rest of auth flow
}
```

---

## Detailed Findings by Spec Section

### Lifecycle Model (Legal Transitions)

**PASS.** `isLegalTransition(from:to:)` at line 495 matches all 21 legal transitions in the spec character-for-character. No extra transitions allowed. Invalid transitions logged and rejected.

### Epoch Contract

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Epoch increments on `→ connecting` | PASS | `currentEpoch += 1` in `startConnecting()` at line 434 |
| Stale epoch events dropped with log | PASS | `handleTransportEvent()` line 236: `guard event.epoch == currentEpoch` |
| Phase-gated rejection (idle/failed) | PASS | Line 240: `guard phase != .idle && phase != .failed` |
| Atomic epoch/cursor/dispatch (no await) | PASS | `startConnecting()` lines 434-442: epoch increment, transition, emit, startAttempt — all synchronous on actor |
| Service entry is synchronous | PASS | `startConnectionAttempt()` creates a `Task` internally; closure dispatch is synchronous |
| Coordinator input vocabulary matches spec | PASS | `LifecycleTransportEvent.Payload` cases match spec exactly |
| Coordinator output vocabulary matches spec | PASS | `ConnectionLifecycleOutput` cases match spec exactly |
| Cursor handoff via updateCanonicalCursor | PASS | `handleLifecycleServerMessage` calls `updateCanonicalCursor(message.id)` after apply |

**Score: 8/8**

### Replay Gate Contract

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| auth_result replayCount validation | PASS | Line 318: `guard let replayCount, replayCount >= 0 else { fail(.protocolMismatch) }` |
| replayTruncated defaults false | PASS | Line 323: `self.replayTruncated = replayTruncated ?? false` |
| historyReset defaults false | PASS | Line 325: `let shouldResetHistory = historyReset ?? false` |
| replayCount=0 → start+complete+live | PASS | `beginReplay()` line 354: `if replayExpectedCount == 0 { completeReplay() }` after emitting `.replayStarted` |
| Non-message events don't decrement counter | PASS | `replayMessageDisposition()` returns `nil` for non-`"message"` types |
| Invalid message envelope → recovering | PASS | `.invalidMessageEnvelope` case triggers `transition(to: .recovering, ...)` |
| Overshoot detection | PASS | Lines 387-399: tracks per-epoch overshoots, transitions to recovering |
| 3 consecutive overshoots → failed | PASS | Line 395: `if consecutiveReplayOvershoots >= 3 { fail(.protocolMismatch) }` |
| Overshoot events dropped (not applied) | PASS | Early return at line 399 without `emit(.serverMessage(...))` |
| Overshoot counter reset on reaching live | PASS | `completeReplay()` line 418: `consecutiveReplayOvershoots = 0` |
| Total replay timeout formula | PASS | Line 359: `min(300.0, max(30.0, Double(replayExpectedCount) * 0.25))` |
| Progress timeout 30s | PASS | `resetReplayProgressTimeout()` line 377: `Task.sleep(for: .seconds(30))` |
| Progress timeout resets on each replay message | PASS | Line 404: `resetReplayProgressTimeout(epoch: epoch)` after decrement |
| Transport close during replay → recovering | PASS | `handleTransportInterrupted()` line 286: `.replaying` → `.recovering` |
| Cancel replay timers on transport close | PASS | `transition()` calls `cancelPhaseTimers()` which cancels all timer tasks |
| historyTruncated emitted after completion | PASS | `completeReplay()` line 419: `if replayTruncated { emit(.historyTruncated(epoch:)) }` |

**Score: 16/16**

### History Reset

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| historyResetRequired emitted before replayStarted | PASS | `handleAuthResult()` line 332: emits `historyResetRequired` then returns; `beginReplay` called from `acknowledgeHistoryReset` |
| Ack required before replayStarted | PASS | `awaitingHistoryResetAckEpoch` blocks replay start |
| Buffer up to 500 messages while awaiting ack | PASS | `handleServerMessage()` line 371: `bufferedServerMessages.append(data)` with overflow check |
| Overflow > 500 → failed (protocolOverflow) | PASS | Line 373: `if bufferedServerMessages.count > 500 { fail(.protocolOverflow) }` |
| 5s ack timeout → failed (historyResetTimeout) | PASS | Line 337: `Task.sleep(for: .seconds(5))` → `handleHistoryResetAckTimeout` |
| Clear set on history reset | **PARTIAL** | `handleHistoryResetRequired` clears sessionMessages, messages, pendingLocalMessages, messageFailures, replay cursors, canonical cursor. Does NOT explicitly clear `lastServerMessageId` (may not exist as separate property). |
| StreamSwitchCoordinator.reset() on history reset | **FAIL** | `handleHistoryResetRequired` does not call `StreamSwitchCoordinator.reset()` |
| Cursor clear on history reset | PASS | `lifecycleCoordinator.updateCanonicalCursor(nil)` called |

**Score: 6/8**

### Mutation Policy (Writer)

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| ConversationStoreWriter formal type exists | **FAIL** | No `ConversationStoreWriter` type in the diff or codebase. All writes happen directly in ChatViewModel methods. |
| writerCurrentEpoch tracked | PASS | `writerCurrentEpoch` property in ChatViewModel, updated in `handleLifecycleOutput` |
| firstReplayAppliedEpoch gate | PASS | `firstReplayAppliedEpoch` set in `handleLifecycleServerMessage`, checked in `restoreCachedMessagesIfNeeded` |
| Cache restore epoch-gated + replay barrier | PASS | `restoreCachedMessagesIfNeeded(for:epoch:)` checks both `writerCurrentEpoch` and `firstReplayAppliedEpoch` |
| Cache restore re-checks epoch at commit time | PASS | `@MainActor` commit closure re-checks `writerCurrentEpoch` and `firstReplayAppliedEpoch` |
| In-flight restore cancelled on epoch change | PASS | `restoreTaskBySessionKey.values.forEach { $0.cancel() }` in `handleLifecycleOutput` on epoch change |
| In-flight restore cancelled on first replay | PASS | Same cancellation in `handleLifecycleServerMessage` |
| Lifecycle output stream unbounded FIFO | PASS | `AsyncStream(bufferingPolicy: .unbounded)` in `outputs` property |
| ChatViewModel consumes @MainActor in order | PASS | `observeLifecycleOutputs()` is `@MainActor`, calls `handleLifecycleOutput` synchronously |
| User mutation queue (50-cap) | **FAIL** | No user mutation queue implementation. No `pendingUserMutations`, no 50-cap overflow, no queue flush on first epoch. |
| Cursor writes confined to writer seam | **FAIL** | ProviderChatService still writes `replayCursorBySessionKey` directly in `handleMessage()`. Spec requires: "remove cursor writes outside writer seam." |
| Canonical cursor persistence (debounced 500ms) | **FAIL** | No canonical cursor persistence to disk. Cursor is seeded from `replayCursorSnapshot()` on auth change but not persisted independently with debounce. |

**Score: 8/12**

### Reconnect / Recovering Policy

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Backoff: start 1s | PASS | `reconnectBackoff = .seconds(1)` in `resetRecoveringState()` |
| Backoff: double each attempt | PASS | `reconnectBackoff = min(previousBackoff * 2, .seconds(30))` |
| Backoff: cap 30s | PASS | `.seconds(30)` cap in doubling |
| Backoff: 0-1s jitter | PASS | `reconnectBackoffWithJitter()` adds `randomJitterMs()` (0...1000) |
| Connect timeout 10s | PASS | `Task.sleep(for: .seconds(10))` in `startConnecting()` |
| Auth timeout 12s | PASS | `Task.sleep(for: .seconds(12))` in `handleTransportOpened()` |
| 20 consecutive attempts → failed | PASS | `if recoveringAttemptCount >= 20 { fail(.reconnectAttemptsExhausted) }` |
| Counter/backoff reset on reaching live | PASS | `resetRecoveringState()` in `completeReplay()` |
| Reconnect idempotent (one timer max) | PASS | `guard reconnectTask == nil else { return }` in `scheduleReconnect()` |
| Manual retry from failed: counter reset | PASS | `case .failed: resetRecoveringState(); startConnecting(...)` |
| Manual retry from recovering: backoff reset to 1s, no counter increment | PASS | `reconnectBackoff = .seconds(1)` (line 210), no `resetRecoveringState()` call |
| session_replaced → failed, no auto-reconnect | PASS | `fail(.sessionReplaced)` cancels reconnect task |
| failed → connecting only via manual retry | PASS | `startIfNeeded()` guards on `phase == .idle`; `manualRetry()` is the only `failed → connecting` path |

**Score: 13/13**

### App Lifecycle Contract

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Background: cancel reconnect timer | PASS | `cancelAllTimers()` in `appDidEnterBackground()` |
| Background: close active transport | PASS | `stopAttempt()` in `appDidEnterBackground()` |
| Background: non-terminal phases → idle | **FAIL** | `moveToIdleIfNeeded()` includes `failed` in its match set. Spec says only `connecting/authenticating/replaying/live/recovering → idle` on background. `failed` should NOT transition to `idle`. **Bug: background followed by foreground auto-retries from a failed state.** |
| Foreground: idle + reconnectEnabled → connecting | PASS | `guard reconnectEnabled, phase == .idle else { return }; startConnecting(...)` |
| Foreground: failed → no auto-retry | **DEPENDS** | If background bug (above) is present, `failed` becomes `idle` on background, and foreground auto-retries. **Broken by the background bug.** |
| Foreground: <2s cooldown delay | PASS | `if sinceBackground < 2 { reconnectTask = Task { sleep(2 - since); startIfNeeded() } }` |
| Foreground: >=60s resets counter/backoff | PASS | `if timeIntervalSince(lastBackgroundedAt) >= 60 { resetRecoveringState() }` |
| Foreground: <60s preserves counter/backoff | PASS | No reset when < 60s |

**Score: 6/8**

### Terminal Server Events

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Terminal events → failed from any active phase | **FAIL** | `handleAuthResult()` guards `phase == .authenticating`. Terminal events during `live`/`replaying`/`connecting` are dropped. See CRITICAL section above. |

**Score: 0/1**

### Diagnostics

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Phase transitions logged | PASS | `transition()` logs `from`, `to`, `epoch` |
| Stale event drops logged | PASS | `handleTransportEvent()` logs `eventEpoch`, `currentEpoch` |
| Replay start/completion logged | PASS | `completeReplay()` logs epoch, expected count, duration, truncated |
| Reconnect attempt index/backoff logged | PASS | `executeRecoveringReconnect()` logs index and backoff |

**Score: 4/4**

### Transition Surface Contract Compliance

| Requirement | Verdict | Evidence |
|-------------|---------|----------|
| Actor serialization (no concurrent state access) | PASS | `ConnectionLifecycleCoordinator` is an `actor`; all state mutations are serialized |
| Deferred handlers validate epoch before proceeding | PASS | All `Task`-based timeout handlers check `currentEpoch == epoch` and `phase` before acting |
| No @MainActor cross-isolation await in transition path | PASS | `startConnecting()` path is fully synchronous on the actor — no `await` between epoch increment and dispatch |
| Cleanup on guard failure (timers cancelled on phase exit) | PASS | `cancelPhaseTimers()` called on every transition |

**Score: 4/4**

---

## Summary of FAIL Items

### Critical (correctness bug)

| # | Issue | Spec Section | Impact |
|---|-------|-------------|--------|
| F1 | Terminal server events dropped during live/replaying | Terminal server-event override | `session_replaced` during `live` causes reconnect loop instead of `failed`. **Defeats primary spec goal.** |
| F2 | Background transitions `failed → idle` | App Lifecycle Contract | Foreground after background auto-retries from failed state. |

### Structural (spec mechanism not implemented)

| # | Issue | Spec Section | Impact |
|---|-------|-------------|--------|
| F3 | No `ConversationStoreWriter` formal type | Architecture Decision §2 | Write seam is behavioral, not structural. No compile-time enforcement of write boundary. |
| F4 | No canonical cursor persistence | Cursor Resume Contract | App relaunch loses canonical cursor; falls back to `replayCursorSnapshot().values.max()` seeding. |
| F5 | `StreamSwitchCoordinator.reset()` not called on history reset | History Reset | Stale stream metadata may survive provider-authoritative history reset. |
| F6 | No user mutation queue (50-cap) | Mutation Policy | User-initiated local mutations during pre-epoch state are not queued or capped. |
| F7 | Cursor writes outside writer seam | Integration Boundaries | `ProviderChatService.handleMessage()` still writes `replayCursorBySessionKey` directly. |

### Concern (not strict FAIL)

| # | Issue | Notes |
|---|-------|-------|
| C1 | ProviderChatService dual event paths | Old message processing (decode, cursor update, broadcast) still runs alongside lifecycle events. Dead code in lifecycle path but creates confusion and cursor write leaks (F7). |
| C2 | `cancelPhaseTimers(for:)` ignores parameter | Cancels ALL phase timers on every transition. Harmless (handlers re-check epoch/phase) but wasteful. |

---

## Recommended Fix Priority

1. **F1 (terminal events)** — Must fix before any testing. This is a correctness bug that creates exactly the reconnect loop the spec was designed to prevent.
2. **F2 (background/failed)** — Must fix. Exclude `.failed` from `moveToIdleIfNeeded`'s match in the background path.
3. **F7 + C1 (dual paths)** — Should fix. Strip old message processing from `ProviderChatService.handleMessage()` when in lifecycle mode. Remove direct cursor writes.
4. **F5 (StreamSwitchCoordinator.reset)** — Should fix. One-line addition to `handleHistoryResetRequired`.
5. **F3, F4, F6** — Can defer. These are structural improvements (formal writer type, cursor persistence, mutation queue) that don't cause immediate bugs but leave enforcement gaps.
