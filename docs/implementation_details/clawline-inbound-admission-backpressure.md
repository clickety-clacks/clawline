# Clawline Inbound Admission Backpressure — Non-Obvious Details

## "Poison head" failure mode — why one message can block a stream indefinitely
A message that gets persisted and acked, then fails/hangs before dispatch starts, AND has the same `clientId` as a retry, short-circuits the retry as a duplicate. The message appears accepted but never reaches agent run dispatch. Without a bounded queue-head age, this state is permanent. The invariant that fixes this: a queue head task cannot wait forever; it transitions to explicit terminal failure after configured max age and releases queue progress.

## `ack` implies clearable — not just "received"
Sending `ack` is a promise: the message is in a durable state where it will either dispatch or reach an explicit terminal failure state. If clearable admission cannot be obtained within bounds, return explicit backpressure failure (`backpressure`) and do NOT `ack`. An `ack` followed by silent failure is the pre-existing bug this spec closes.

## Single lifecycle transition API (`transitionInboundLifecycle(...)`) — no direct state mutations
All inbound lifecycle transitions must use one transition API. Direct writes to `lifecycleState` columns are boundary violations. This is the same single-writer principle as the message-stream-seam, applied to the provider side.

## Lightweight provenance is a required invariant — not optional observability
Every inbound message must have enough metadata/logging to answer "what happened to this message" without replaying full payload history. This is marked as a binding invariant, not a nice-to-have. Required columns: `lifecycleState`, `lifecycleUpdatedAt`, `terminalReasonCode`. Missing these makes post-incident debugging impossible.

## Backpressure is explicit — no silent limbo
The pre-existing failure mode was: message appears to be in-flight but is actually stuck in limbo (persisted, acked, not dispatching). The fix requires explicit backpressure: either the message is clearable (will dispatch or fail terminally), or the client gets a `backpressure` response and knows to retry. Silent limbo is not an acceptable outcome.
