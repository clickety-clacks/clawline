# Clawline Inbound Admission and Backpressure

Status: Draft (implementation-ready)
Last updated: 2026-03-02
Owner: Clawline provider (server)

## 1. Goal

Define a deterministic inbound message contract for Clawline WebSocket `message` payloads so that:

1. `ack` is sent only after the message is durably clearable/recoverable.
2. Backpressure is explicit (no silent limbo).
3. Queue stalls cannot block a stream indefinitely without terminal visibility.

This spec addresses the observed "poison head" failure mode where one in-flight message can block later messages on the same stream queue.

## 2. Non-Goals

1. No changes to core gateway queueing/lane systems.
2. No redesign of `/alert` endpoint queue policy in this phase.
3. No changes to session key semantics.
4. No heavy event-sourcing table or full per-message history log.

## 3. Scope

In scope:

1. Provider-side Clawline inbound path for WebSocket `payload.type = "message"` in `src/clawline/server.ts`.
2. Provider dedupe behavior for `(deviceId, clientId)` when prior attempts are partial.
3. Provider observability and compact durable metadata for message provenance.

Out of scope:

1. `/alert` request format and overlay behavior.
2. Model/provider selection and response content generation.

## 4. Problem Summary

Current behavior allows a gap between "message acknowledged" and "message guaranteed to dispatch or fail explicitly".

A message may be persisted and acked, then fail/hang before dispatch starts. Retries with the same `clientId` may short-circuit as duplicates, creating a condition where the message appears accepted but never reaches agent run dispatch.

## 5. Terms

1. `clientId`: Clawline client message id (`c_*`), idempotency key per device.
2. `queueKey`: per-stream processing key (user + stream key).
3. `admitted`: message accepted into durable dispatch intent state.
4. `clearable`: message can no longer be silently lost; it will either dispatch or fail terminally.

## 6. Binding Invariants

1. `ack` implies clearable
: Sending `ack` means the message is in a durable state where it will either dispatch or reach an explicit terminal failure state.

2. Explicit backpressure
: If clearable admission cannot be obtained within bounds, return explicit backpressure failure (`backpressure`) and do not `ack`.

3. Bounded queue-head age
: A queue head task cannot wait forever. If it exceeds configured max age, it transitions to explicit terminal failure and releases queue progress.

4. Single lifecycle mutation seam
: All inbound lifecycle transitions must use one transition API (`transitionInboundLifecycle(...)`).

5. Lightweight provenance
: Every inbound message must have enough metadata/logging to answer "what happened" without replaying full payload history.

## 7. Durable Lifecycle State Model

Lifecycle state is stored on the existing `messages` table (no side table in this phase).

Required columns:

1. `lifecycleState` (enum/int)
2. `lifecycleUpdatedAt` (unix ms)
3. `terminalReasonCode` (nullable short string)

Required states:

1. `received`
2. `admitted`
3. `dispatch_started`
4. `dispatch_finished`
5. `dispatch_failed`
6. `rejected_backpressure`
7. `expired_in_queue`

Allowed transitions only:

1. `null -> received`
2. `received -> admitted`
3. `received -> rejected_backpressure`
4. `admitted -> dispatch_started`
5. `admitted -> expired_in_queue`
6. `dispatch_started -> dispatch_finished`
7. `dispatch_started -> dispatch_failed`

No other transitions are valid.

## 8. Transition API Contract

All lifecycle writes must go through:

`transitionInboundLifecycle(params: { deviceId: string; clientId: string; from: LifecycleState | null; to: LifecycleState; queueKey: string; reasonCode?: string; nowMs: number; })`

Required behavior:

1. Performs compare-and-set on `(from, to)` in one DB transaction.
2. Writes `lifecycleState`, `lifecycleUpdatedAt`, `terminalReasonCode`.
3. Emits exactly one transition log on success.
4. Invokes queue-state callback to update `pendingCount`.
5. Returns deterministic result (`applied` or `invalid_transition`).
6. Must not partially apply DB write without callback or callback without DB write.

## 9. Admission Phase (Implements 1 and 2)

For each inbound message:

1. Parse + validate payload.
2. Resolve `queueKey`.
3. Acquire per-message admission lock keyed by `(deviceId, clientId)`.
4. If no row exists, create it via transition `null -> received`.
5. Enter admission attempt with timeout `admissionTimeoutMs`.

`admissionTimeoutMs` definition:

1. Starts when lock is acquired and admission evaluation begins.
2. Ends when one terminal admission result is durably written (`admitted` or `rejected_backpressure`).
3. Covers waiting for queue-slot availability and transition write.
4. Does not cover post-admission dispatch execution.

Admission outcomes:

1. Outcome A: `admitted`
: Persist `received -> admitted`, then send `ack`.

2. Outcome B: `rejected_backpressure`
: Persist `received -> rejected_backpressure` with reason, send explicit `backpressure` error, do not send `ack`.

## 10. Queue-Head Staleness Phase (Implements 3)

`expired_in_queue` is not an admission outcome. It is a post-admission timeout.

Trigger:

1. Message is in `admitted`.
2. Message has not reached `dispatch_started`.
3. `now - admittedAt >= queueHeadMaxAgeMs` for that message.

Timeout semantics:

1. `queueHeadMaxAgeMs` is total wait time since `admitted`, not just time while currently queue head.
2. Implementation still uses one active timer/check path per queue key (or equivalent O(active-queues) mechanism).

Action:

1. Persist `admitted -> expired_in_queue` through the single transition API.
2. Set reason `queue_timeout`.
3. Emit explicit client error `queue_timeout` for that message id.
4. Release queue head so later messages on the same `queueKey` can progress.

Implementation constraint:

1. No O(n) scan per inbound message.

## 11. Dedupe Contract

Dedupe lookup remains keyed by `(deviceId, clientId)`.

Behavior is lifecycle-aware and deterministic:

1. Existing row `dispatch_finished`:
: Send `ack` replay, no new dispatch attempt.

2. Existing row `dispatch_failed`:
: Send `message_failed` error replay, no new dispatch attempt.

3. Existing row `rejected_backpressure`:
: Send `backpressure` error replay, no new dispatch attempt.

4. Existing row `expired_in_queue`:
: Send `queue_timeout` error replay, no new dispatch attempt.

5. Existing row `dispatch_started` or `admitted`:
: Send `ack` replay (already clearable), no new dispatch attempt.

6. Existing row `received`:
: Resume the same row through bounded admission flow under the same `(deviceId, clientId)` lock (no new row creation). If admission succeeds, `ack`; if rejected, explicit error.

7. Duplicate hash mismatch (`contentHash` or `attachmentsHash`) remains invalid and returns existing validation error.

Concurrency rule:

1. Exactly one row per `(deviceId, clientId)`.
2. All duplicate handling for one `(deviceId, clientId)` is serialized by the per-message lock.
3. No path may create parallel dispatch attempts for the same row.

## 12. Pending Count SSOT and Mutation Seam

`maxPendingPerQueueKey` gate is owned by one queue-state owner in Clawline server memory.

SSOT rules:

1. `pendingCount` per `queueKey` is maintained only by queue-state owner.
2. Admission checks read only this owner state (no DB scan in hot path).
3. Queue-state owner updates `pendingCount` only via lifecycle transition callbacks from `transitionInboundLifecycle(...)`.
4. Startup rebuild is mandatory before accepting new inbound messages and reconstructs pending counts from non-terminal rows.
5. If startup rebuild fails, provider must fail closed for inbound admission (return server error) until rebuild succeeds.

## 13. Provenance Requirements (Lightweight)

## 13.1 Durable metadata

Per message, persist only:

1. current lifecycle state
2. lifecycle updated timestamp
3. terminal reason code (nullable)

No per-transition history table in this phase.

## 13.2 Structured logs

Emit one structured log per lifecycle transition with:

1. `deviceId`
2. `clientId`
3. `queueKey`
4. `fromState`
5. `toState`
6. `reasonCode` (if present)
7. per-`queueKey` depth and head-age snapshot

Do not log raw content payload.

## 14. Error Surface

Client-facing codes in this spec:

1. `backpressure`
2. `queue_timeout`
3. `message_failed` (terminal dispatch failure replay)

Existing validation errors remain unchanged.

## 15. Performance Constraints

1. No heavy synchronous scans in hot path.
2. Additional DB writes are transition updates only (constant-factor per message).
3. No per-message O(n) sweeper loops.

## 16. Implementation Boundaries

1. Implementation is confined to Clawline provider code paths.
2. No core gateway behavior changes in this spec.
3. No session key routing changes.
4. If implementation discovers a required core hook, stop and issue spec revision before coding beyond scope.

## 17. Acceptance Checks

1. `ack` is never emitted unless row state is at least `admitted`.
2. Under forced pressure, client gets explicit `backpressure` and no `ack`.
3. Under forced queue-head stall, message transitions to `expired_in_queue` within bound, client gets `queue_timeout`, and next message for same `queueKey` can progress.
4. Duplicate for `received` row resumes bounded admission on same row and reaches deterministic outcome.
5. Duplicate for non-terminal clearable rows (`admitted` or `dispatch_started`) replays `ack` only and does not spawn second dispatch.
6. For any `clientId`, operators can determine terminal outcome from row metadata plus transition logs.

## 18. Test Plan

1. Unit tests for valid/invalid lifecycle transitions.
2. Unit tests for transition API compare-and-set behavior and callback atomicity.
3. Integration test: normal path (`received -> admitted -> dispatch_started -> dispatch_finished`).
4. Integration test: admission rejection (`received -> rejected_backpressure`).
5. Integration test: queue-head expiry (`admitted -> expired_in_queue`) and queue release.
6. Integration test: duplicate replay per lifecycle state branch.
7. Concurrency test: duplicate bursts cannot create multiple rows or parallel dispatches.
8. Startup test: mandatory rebuild populates pending counts before first admission.
9. Logging test: one structured transition log per transition.

## 19. Rollout

1. Ship behind `clawline.inbound.useAtomicAdmission` default off.
2. Flag-off behavior keeps legacy path unchanged.
3. New lifecycle columns are nullable while flag is off; rebuild logic ignores rows with null lifecycle state.
4. Flag-on behavior enables full lifecycle+transition API path.
5. Enable in staging first, then TARS after validation.

## 20. Open Questions

1. Default values for `admissionTimeoutMs` and `queueHeadMaxAgeMs`.
2. Whether queue-head timeout values should allow per-queue-key overrides.
3. Whether client payload should include retry hint text for `backpressure`.

## 21. Implementation Handoff

Scope boundaries:

1. Implement provider-side inbound lifecycle + bounded backpressure behavior only.
2. Do not add `/alert` queue class redesign in this phase.
3. Do not modify core gateway lane scheduling.

Primary risk:

1. Transition API correctness is safety-critical; all lifecycle writes must route through one mutation seam.
