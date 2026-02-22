# Connection Lifecycle (Root-Cause Fix Spec)

Date: 2026-02-20
Owner: Clawline iOS client
Status: Ready for implementation handoff

## Goal

Fix the shared root cause behind three connection/login bugs by introducing one canonical lifecycle authority for connect/auth/replay/live/recover sequencing, with explicit epoch gating and single-writer data mutation.

Bugs this spec must eliminate:
1. Rapid reconnect cycling (~2s reconnect loop)
2. Stale or empty initial content after login (fixed only by app restart)
3. Cursor resume failure on reconnect (server replays from scratch)

## Non-Goals

- No provider protocol redesign.
- No pairing flow redesign.
- No stream-switch UI/engine redesign (that stays in `stream-switch-coordinator.md`).
- No message layout/materialization redesign (that stays in staged materialization specs).

## Prior Art Used

- `/Users/mike/shared-workspace/clawline/specs/connection-state-ui.md`
- `/Users/mike/shared-workspace/clawline/specs/t069-connection-state-full-audit-retro.md`
- `/Users/mike/shared-workspace/clawline/ios-provider-connection.md`
- `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md`
- `/Users/mike/shared-workspace/clawline/specs/staged-stream-materialization.md`
- `/Users/mike/shared-workspace/clawline/specs/staged-stream-materialization-arch-review.md`
- `/Users/mike/shared-workspace/clawline/specs/staged-stream-materialization-arch-review-2.md`
- `/Users/mike/shared-workspace/clawline/specs/stream-switch-coordinator.md`
- `/Users/mike/shared-workspace/clawline/specs/stream-switch-coordinator-arch-review.md`
- `/Users/mike/shared-workspace/clawline/specs/stream-switch-separation-code-review.md`

State-machine prior-art lookup note:
- Requested file `clawline-ws-state-machine.mmd` was searched under `/Users/mike/.openclaw/workspace`, `/Users/mike/shared-workspace`, and `/Users/mike/src/clawline`; no file found.

## Current-Code Root Cause (What Exists Today)

Observed from current code:
- `ProviderChatService` mutates runtime transport state (`.connecting`, `.connected`, `.disconnected`, `.failed`) and emits interruption events.
- `ChatViewModel` independently mutates connection state (`transitionConnectionState`) and independently schedules reconnect (`scheduleReconnect`) from multiple triggers (`stateStream`, `serviceEvents`, auth-change, scene-active, manual reconnect).
- `ChatViewModel.connectionSnapshot()` sends only one cursor (`engineActiveSessionKey` cursor fallback), while replay and message apply occur for many session keys.
- Cache restore (`restoreCachedMessagesIfNeeded`) can apply asynchronously after connection/replay events and can rewrite `lastServerMessageIdBySession`.

Shared failure mechanism:
- No single lifecycle authority, no stale-attempt rejection token, and no replay-vs-cache write barrier.
- Result: old attempt callbacks and late cache restores can overwrite fresh state and reschedule reconnect repeatedly.

## Architecture Decision

Introduce one lifecycle authority and one store-writer seam.

### 1) Lifecycle authority

Add `ConnectionLifecycleCoordinator` (actor) as the only owner of connection phase transitions and reconnect scheduling.

Responsibilities:
- Own lifecycle phase.
- Own `ConnectionEpoch` and stale-event rejection.
- Own reconnect backoff timer.
- Own replay gate (started/completed) for current epoch.
- Emit normalized lifecycle outputs to `ChatViewModel`.

Hard boundary:
- `ChatViewModel`, `ProviderChatService`, and `URLSessionWebSocketConnector` must not transition connection phase directly.
- They emit events/intents; coordinator decides transitions.

Reconnect trigger contract (deduplicated):
- Valid reconnect intents: transport interruption, connect/auth timeout, explicit manual retry, app foreground when phase is `idle` and reconnect is enabled.
- Invalid/ignored reconnect intents: any reconnect request while phase is `connecting`, `authenticating`, `replaying`, or `live`.
- Reconnect scheduling is idempotent per phase: one pending reconnect timer max.

### 2) Store writer seam

All message/cursor/store mutations flow through one seam in `ChatViewModel`:
- `ConversationStoreWriter` (nested, `@MainActor`, 1:1 owned by `ChatViewModel`).

Hard boundary:
- No direct writes to `sessionMessages`, `lastServerMessageIdBySession`, `messages`, or `lastServerMessageId` outside writer methods.

## Lifecycle Model

Canonical phases:
1. `idle`
2. `connecting`
3. `authenticating`
4. `replaying`
5. `live`
6. `recovering`
7. `failed`

Legal transitions only:
- `idle -> connecting`
- `connecting -> authenticating`
- `connecting -> recovering`
- `connecting -> failed`
- `connecting -> idle`
- `authenticating -> replaying`
- `authenticating -> recovering`
- `authenticating -> failed`
- `authenticating -> idle`
- `replaying -> live`
- `replaying -> recovering`
- `replaying -> failed`
- `replaying -> idle`
- `live -> recovering`
- `live -> failed`
- `live -> idle`
- `recovering -> connecting`
- `recovering -> failed`
- `recovering -> idle`
- `failed -> connecting` (explicit user retry only)
- `failed -> idle` (explicit user teardown only)

Any other transition is invalid and must be ignored with diagnostic log.

Auth timeout rule:
- If phase remains `authenticating` for 12s without `auth_result`, transition `authenticating -> recovering`.

## Epoch Contract

Every new connection attempt gets a monotonically increasing `ConnectionEpoch`.

Rules:
- Epoch increments on each `-> connecting` transition.
- All inbound connection events carry `epoch` (open, auth, message/event, close/error, reconnect timer fire).
- Coordinator applies side effects only when `event.epoch == currentEpoch`.
- Stale events are dropped and logged.

Threading requirement:
- `ProviderChatService` must tag callbacks with attempt epoch received when coordinator initiated that attempt.
- Coordinator entrypoints accept lifecycle-scoped events (epoch + payload), not raw unscoped events.
- Required handoff API shape:
  - coordinator -> service start: `startConnectionAttempt(epoch:lastMessageId:token:)`
  - service -> coordinator events: `LifecycleTransportEvent(epoch:payload:)`
  - service must not emit unscoped transport events into lifecycle path.

## Replay Gate Contract

### Auth decode precondition

For `auth_result.success == true`, decode and retain:
- `replayCount` (required int >= 0)
- `replayTruncated` (required bool)
- `historyReset` (optional bool, default `false`)

Provider contract reference:
- Existing provider auth_result contract includes these fields (see `/Users/mike/shared-workspace/clawline/ios-provider-connection.md`, authenticated-session success payload).

If required replay fields are missing/invalid, transition to `failed` (protocol mismatch).

### Replay sequencing

On auth success:
- enter `replaying`
- emit `replayStarted(epoch, replayCount, replayTruncated, historyReset)`

`replayTruncated` semantics:
- `replayCount` is authoritative for client replay completion in all cases.
- When `replayTruncated == true`, `replayCount` is the truncated replay size the provider will actually deliver for this auth epoch.
- Client does not wait for undisclosed historical events beyond `replayCount`.
- Client behavior when `replayTruncated == true`: emit `historyTruncated(epoch)` lifecycle output after replay completion.
- Client behavior when `replayTruncated == true`: emit `historyTruncated(epoch)` lifecycle output after replay completes.

Completion rule:
- replay completes after exactly `replayCount` replay-counted server `message` events for that epoch.
- replay-counted event means: successfully decoded server chat `message` payload during replay window.
- typing/control/error events do not decrement replay counter.
- `replayCount` is total replay-counted `message` events across all session keys for that auth epoch.

Replay-counted message discriminator:
- Canonical wire discriminator: JSON envelope field `type` exactly equals `\"message\"`.
- Replay-counted payload must decode as provider chat message shape from `/Users/mike/shared-workspace/clawline/ios-provider-connection.md` (server->client message event with server `s_*` id, role/content/timestamp fields).
- Only successfully decoded payloads matching that shape are replay-counted.
- Provider replay-count semantics are authoritative for the single-cursor auth contract; client does not recompute expected replay count from per-session state.
- Empty-content `message` payloads still count if they match message shape; typing indicators must not be encoded as `type == \"message\"` replay payloads.
- If `type == \"message\"` payload fails chat-message-shape decode, client does not decrement replay count, logs protocol diagnostic, and immediately transitions `replaying -> recovering` for clean retry.

If `replayCount == 0`:
- emit `replayStarted`, then immediate `replayCompleted`, then enter `live`.

Mismatch rules:
- More replay-counted events than `replayCount` => protocol mismatch; transition `replaying -> recovering`.
- If this overshoot happens on 3 consecutive epochs, transition to `failed`.
- Overshoot counter is per coordinator instance and resets to `0` on any epoch that reaches `live`.
- Overshoot event handling: replay-counted events beyond declared `replayCount` are dropped (not applied) for that epoch.
- Consecutive overshoot means consecutive replay attempts that reach `replaying` and overshoot before reaching `live`.

Timeout rules:
- Total replay timeout: `max(30s, replayCount * 250ms)`, capped at `300s`.
- Progress timeout while remaining replay count > 0: `30s` with no replay-counted message.
- Timeout => `replaying -> recovering`.

Overshoot counter lifecycle scope:
- Counter lifetime is coordinator object lifetime for current authenticated account on this device.
- Counter resets on account change/logout, on app relaunch (new coordinator instance), and on explicit user retry from `failed`.
- Explicit user retry includes the `Retry Here` action in `session_replaced` failed state.

### History reset

If `historyReset == true`, writer clears local conversation state before applying replay events for that epoch.
Required clear set:
- `sessionMessages`
- `messages`
- `lastServerMessageIdBySession`
- `lastServerMessageId`
- `pendingLocalMessages`
- `messageFailures`
- canonical auth cursor (in-memory)
- canonical auth cursor persistence key

Not cleared by this rule:
- stream metadata (`streamsBySessionKey`, `orderedSessionKeys`)
- auth/session identity
- UI stream-selection keys (`uiSelectedSessionKey`, `engineActiveSessionKey`)

Provider trigger note:
- `historyReset` is provider-auth metadata and may appear on any successful auth_result when provider indicates local history must be dropped (for example retention reset/migration).
- Client treats `historyReset=true` as authoritative regardless of why provider emitted it.

Cursor consequence of history reset:
- canonical auth cursor is set to `nil` at reset time.
- next auth attempt omits `lastMessageId` until replay/live apply establishes a new canonical cursor.
- Cursor clear executes only when processing an auth_result that explicitly carries `historyReset == true`; reconnect attempts without a new historyReset signal do not re-clear cursor.

## Mutation Policy (Writer)

Mutation categories:

1. Lifecycle-sourced server mutations (epoch-gated):
- replay/live incoming messages
- replay/live cursor updates
- replay/session provisioning payload apply

2. Cache restore mutations (epoch-gated + replay barrier):
- allowed only before first replay apply of same epoch
- dropped if replay already applied for that epoch

Cache restore trigger and epoch assignment:
- On `idle/recovering/failed -> connecting`, coordinator increments epoch to `E`.
- Coordinator emits `phaseTransition(... -> connecting, epoch: E)` before any restore request for `E`.
- Only after that ordered phase transition emission, coordinator emits `restoreCacheRequested(epoch: E)` once.
- Writer runs cache restore for epoch `E` only.
- Cache restore is asynchronous and does not block `authenticating`.
- Restore(E) apply is atomic-at-commit (no partial apply of decoded cache payload).
- Concurrency enforcement: restore(E) background read/decode never mutates store directly; it submits one `@MainActor` commit closure to writer.
- That commit closure must re-check epoch and replay-start gate immediately before mutation; on mismatch it exits without mutation.
- If first replay event for epoch `E` arrives while restore(E) is running, writer cancels or drops any remaining restore(E) apply work atomically before replay apply.
- If writer has applied first replay event for epoch `E`, any pending/late cache-restore apply for `E` is dropped.
- Cache-restore work from older epochs is always dropped.
- Restore failure handling: if restore read/decode fails, no cache state is applied for that epoch; writer logs diagnostic and lifecycle continues.
- Cache-vs-replay precedence is intentional: replay data is authoritative, cache restore is best-effort warm start only.
- Delivery serialization guarantee:
  - Coordinator emits lifecycle outputs on one FIFO `AsyncStream<LifecycleOutput>`.
  - `ChatViewModel` consumes that stream on `@MainActor` in receive order and forwards each output to writer synchronously in that same order.
  - Writer therefore observes `phaseTransition(...connecting,E)` before `restoreCacheRequested(E)`.
  - Writer replay-start gate is explicit state `firstReplayAppliedEpoch`; writer sets it on first replay message apply for epoch `E`, and restore(E) commit checks this gate before mutation.

3. User-initiated local mutations (current-epoch scoped):
- optimistic local send placeholder
- pending/failure bookkeeping
- user resend/removal actions

Writer freshness rule:
- writer tracks `writerCurrentEpoch` from lifecycle outputs.
- request is applied only if request epoch is current for that category.
- `writerCurrentEpoch` initializes as `nil`; mutation requests are rejected until first epoch-bearing lifecycle output arrives.
- `ChatViewModel` pushes lifecycle outputs to writer in stream order on `@MainActor`; writer does not independently subscribe to coordinator.

## Cursor Resume Contract

Root-cause fix requirement for bug #3:
- reconnect auth cursor must come from canonical writer-owned cursor state across all sessions, not ad-hoc active-UI fallback state.
- no late cache restore may overwrite cursor chosen for current epoch after replay starts.

Cursor selection rule:
- Provider auth currently accepts one `lastMessageId`.
- `lastServerMessageIdBySession` remains authoritative for per-session UI/render state only.
- Writer also maintains one canonical auth cursor for reconnect auth payload.
- Scope for canonical auth cursor: current authenticated user on this device.
- Canonical cursor value is the latest successfully applied server `s_*` event id in writer serialized apply order across all session keys in that scope.
- Safety assumption from provider contract: replay cursor operates on one per-user ordered server event stream; a single canonical `lastMessageId` is therefore sufficient across sessions.
- If provider violates this assumption (divergent per-session cursor semantics), client treats it as protocol incompatibility and enters `failed`.
- Reconnect snapshot uses that canonical account-level cursor only.
- `engineActiveSessionKey` cursor is never used as fallback for auth snapshot.
- Future protocol support for multi-cursor auth payload is out of scope for this spec.

Canonical cursor persistence:
- Writer persists canonical auth cursor using user/device-scoped key.
- Persistence timing: update persisted canonical cursor after each successful replay/live server-message apply (debounced max 500ms).
- On app launch/auth bootstrap, writer restores persisted canonical cursor before first reconnect attempt.
- On `historyReset`, persisted canonical cursor is cleared together with in-memory canonical cursor.

Implementation constraint:
- remove cursor writes outside writer seam.
- cursor used for reconnect snapshot is read from writer-owned canonical state only.

## Reconnect / Recovering Policy

Backoff (per provider contract):
- start 1s
- double each attempt
- cap at 30s
- add 0-1s jitter
- per-attempt connect timeout 10s

Terminal transitions to `failed`:
- auth/token rejection
- session replaced
- unrecoverable configuration error
- 20 consecutive recovering attempts without reaching `live`

Non-terminal transport failures stay in recovering.

`session_replaced` rule:
- must not auto-reconnect loop.
- transition to `failed`; only explicit user retry may reconnect.
- explicit choices in this failed state:
  - `Disconnect` -> `failed -> idle` (teardown, no reconnect)
  - `Retry Here` -> one manual `failed -> connecting` attempt (counter reset as above; still no automatic retry loop)

Connecting transition criteria:
- `connecting -> authenticating`: socket opened and auth payload send started successfully.
- `connecting -> recovering`: transport-level failure expected to be transient (connect timeout, network drop, socket close without terminal auth/policy reason).
- `connecting -> failed`: terminal failure known at connect/auth boundary (invalid configuration, policy/auth rejection, session replaced, unrecoverable protocol mismatch).

Live transition criteria:
- `live -> failed`: terminal server outcome while live (`auth_failed`, `token_revoked`, `session_replaced`, unrecoverable protocol mismatch).
- `live -> recovering`: non-terminal transport interruption.

## App Lifecycle Contract

Background/foreground handling is lifecycle-coordinator owned.

On `didEnterBackground`:
- cancel reconnect timer
- close active transport
- transition active phases to `idle` with reason `appBackgrounded`
- stale callbacks from pre-background epoch must be dropped

On `didBecomeActive`:
- if reconnect is enabled and phase is `idle`, start new `connecting` epoch
- if phase is `failed`, do not auto-retry

No extra `suspended` phase is added.

## Integration Boundaries

- `URLSessionWebSocketConnector`: transport only; no lifecycle decisions.
- `ProviderChatService`: protocol encode/decode + attempt-scoped event tagging; no reconnect policy ownership.
- `ChatViewModel`: UI read-model + writer host; no reconnect scheduler ownership.
- `ConnectionLifecycleCoordinator`: reconnect + phase + replay authority.

Write-seam enforcement mechanism:
- `sessionMessages`, `lastServerMessageIdBySession`, `messages`, and `lastServerMessageId` remain `private` to `ChatViewModel`.
- Only `ConversationStoreWriter` methods may mutate those properties.
- `ChatViewModel` exposes read-only projections for UI consumption.
- Any non-writer mutation of these properties is a spec violation and must fail code review.

## Diagnostics (Required)

Structured logs:
- phase transitions `(from,to,epoch,reason)`
- stale-event drops `(eventType,eventEpoch,currentEpoch)`
- replay start/completion `(epoch,replayCount,replayDuration,replayTruncated,historyReset)`
- replay/cache conflicts dropped by writer
- reconnect attempt index/backoff delay

## Acceptance Criteria

1. Exactly one phase-transition write seam exists (coordinator transition API).
2. `ChatViewModel` no longer schedules reconnect directly.
3. All lifecycle event entrypoints are epoch-scoped; stale epoch events are ignored.
4. Replay gate prevents `live` until replay completion.
5. `auth_result` replay metadata decoding is present and validated.
6. `replayCount=0` path deterministically emits start+complete and enters `live`.
7. Late cache restore cannot overwrite replay-applied messages/cursor in same epoch.
8. Cursor for reconnect snapshot is read from canonical writer-owned state (no split fallback source).
9. `session_replaced` transitions to `failed` and does not auto-reconnect.
10. App background/foreground transitions follow coordinator contract.
11. Single-writer audit: message/cursor store writes are confined to `ConversationStoreWriter`.
12. iOS app target builds after integration.

## Implementation Handoff

Primary files expected:
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- `ios/Clawline/Clawline/Services/ProviderChatService.swift`
- `ios/Clawline/Clawline/Networking/URLSessionWebSocketConnector.swift`

Spec compliance guardrail:
- Implement only what is specified above. If implementation needs behavior not listed here, stop and request spec clarification.
