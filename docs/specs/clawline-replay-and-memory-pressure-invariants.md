# Clawline Replay and Memory-Pressure Invariants

Date: 2026-04-21

Status: canonical implementation spec for the Clawline replay/cursor,
same-stream ordering, and alert fallback memory-pressure fixes.

## Goal

Fix two user-visible message loss classes without widening beyond Clawline:

- newest or near-newest same-stream messages/replies can go missing during
  active use;
- reconnect replay can under-feed non-active streams when the client sends only
  a singular replay cursor.

The same implementation pass must preserve the original memory-pressure
requirement for alert fallback routing.

## Non-Goals

- No durable conversation pruning.
- No OpenClaw core session-store API change.
- No Clawline chat identity change.
- No launchd, LaunchAgent, LaunchDaemon, or TARS service plist change.
- No reuse of `streamReadStates` as replay cursor state.

## Replay Cursor Contract

The auth wire contract supports per-stream replay cursors:

```ts
auth: {
  type: "auth";
  protocolVersion: 1;
  token: string;
  deviceId: string;
  lastMessageId?: string | null;
  replayCursorsBySessionKey?: Record<string, string>;
}
```

`replayCursorsBySessionKey` is the preferred replay input. Keys are subscribed
session keys. Values are finalized/replayable server event IDs (`s_*`) that the
client fully processed for that exact stream.

`lastMessageId` remains a compatibility fallback. A legacy single anchor applies
only to the stream that owns that event. It must not globally anchor unrelated
streams.

For each subscribed stream:

- If a valid per-stream cursor exists for that stream, replay messages after it.
- Otherwise, if `lastMessageId` owns that stream, replay messages after it.
- Otherwise, use latest-window recovery for that stream.
- Missing, stale, cross-user, or unsubscribed anchors are not usable anchors.
- Invalid per-stream entries affect only that stream; they must not poison valid
  entries for other streams.
- Per-stream cursors win over `lastMessageId` for explicit keys.

Streaming partials are not replay cursors. A partial assistant update may share
the same `s_*` message ID as the later final assistant message, but clients must
not persist that partial ID as the stream replay cursor. The persistent cursor
advances only when a finalized/replayable event is applied. Replay duplicate
suppression must not drop a final message solely because a prior partial with
the same `id` was processed.

Replay selection uses `sessions.maxReplayMessagesPerStream` as `cap`. It must
select the newest `cap + 1` eligible finalized rows for each stream, drop the
extra oldest row when present, deliver the newest `cap` rows oldest-to-newest,
and use the extra row as the truncation signal. Do not use a per-stream
`COUNT(*)` query on the reconnect hot path. If any stream has more eligible rows
than the cap, `auth_result.replayTruncated` is true.

If at least one subscribed stream had no usable anchor and used latest-window
recovery, `auth_result.historyReset` is true. The global flag is conservative:
it cannot be false just because another stream had a valid anchor.
Protocol v1 does not expose per-stream reset metadata, so clients must treat
`historyReset: true` as a connection-level local-cache reset for all subscribed
streams and keep only the events delivered by the new auth/replay epoch.

Replay messages are delivered oldest-to-newest after `auth_result`. If
`sendJson` fails for `auth_result`, stream snapshots/session info, or any replay
message, abort replay immediately, close/remove the stale session, and require
the client to reconnect. Partial in-band retry is not allowed.

## Replay/Live Barrier

A newly authenticated socket must not observe live messages ahead of its replay.
The provider must install an explicit replay barrier for that socket.

The implementation may either buffer live sends for that socket until replay
drains or keep the socket out of live broadcast eligibility and perform an
equivalent post-replay gap fill. Whichever approach is chosen must prove:

- replay-selected messages are delivered before live messages for the same
  stream;
- live messages created while replay is in progress are not lost;
- duplicate server message IDs are suppressed across replay/live crossover;
- send failure during replay removes the stale session instead of leaving a
  socket that receives later broadcasts.

Post-replay gap-fill messages, if used, are delivered after the replay phase as
live messages and are not counted in `auth_result.replayCount`.

After replay messages and any immediately queued post-replay gap-fill live
messages have been sent, the provider emits `{ "type": "sync_complete" }`.
Clients must not run reconnect missing-final detection or discard cached
partials until this control event arrives.

## Client Cursor Ownership

`ProviderChatService` owns replay cursor storage per session key. UI lifecycle
state may read snapshots but must not become the authoritative cursor owner.

Every fully processed finalized/replayable server event with an `s_*` ID and
known session key must advance `ProviderChatService`'s cursor for that session
key. Streaming partials must not advance the persistent replay cursor. This
includes finalized/replayable events received through lifecycle replay paths:
after the lifecycle layer applies such an event, it must advance the
transport-owned per-stream cursor map rather than only updating a singular
coordinator cursor.

Cursor mutation APIs must be source-specific:

- cache restore may seed a missing cursor key only;
- processed live/replay events may advance or replace the cursor for their
  stream;
- stream deletion/auth reset may clear the specific stream cursor.

Never compare `s_*` IDs to decide which cursor is newer. Event source and
connection epoch decide whether a write is allowed.

Auth sends all known per-stream cursors in `replayCursorsBySessionKey`.
`lastMessageId` is compatibility-only: use the cursor for the actively selected
chat stream at auth/reconnect time when known; otherwise omit it. Do not compute
it with `values.max()` over all streams.

## Same-Stream Dispatch Ordering

For one `(userId, streamKey)`, the full lifecycle of an inbound message is
serialized:

- validate and persist the user message;
- send ack;
- create outbound dispatcher;
- run the agent dispatch;
- wait for idle;
- clear activity signal;
- compute delivered vs queued;
- write finalized, queued, or failed state.

Interactive callbacks routed to a source stream follow the same rule.

Causal outbound replies produced by that inbound turn must not bypass the same
stream ordering guarantee. This includes normal assistant replies, rich
bubble/tool replies, and system replies produced by that inbound turn. If the
current outbound helper bypasses the per-stream queue, the implementation must
route causal replies through a reentrant same-stream mechanism or emit them
while still inside the inbound stream task.

Independent alerts and out-of-band sends are not swept into an inbound turn's
causal queue unless they are produced by that inbound turn.

Cross-stream concurrency remains allowed.

## Alert Fallback Memory-Pressure Invariant

Alert fallback routing must be pressure-safe, not merely functionally correct.

When an alert targets a session key that is not found in Clawline stream state,
the provider may fall back to OpenClaw session stores only through a dedicated
existence-only resolver. That resolver must:

- maintain an in-memory index keyed by normalized session key;
- store only the data needed to answer existence and return the normalized key;
- invalidate/rebuild from authoritative store file metadata, at minimum
  `mtimeMs` and `size`;
- check all relevant session-store files before answering from a cached index;
- detect relevant store file creation and deletion before answering from a
  cached index;
- rebuild only when a relevant store file changes.

Alert fallback must not use `loadMergedSessionStoreForClawline()`,
`loadSessionStoreEntryForKey()`, full session entries, adoption metadata, or
generic merged-store/listing paths as the steady-state lookup. Repeated alert
fallback lookup against unchanged stores must not load, clone, merge, or iterate
full session stores.

Ownership is not a routing requirement for fallback alerts. A valid
non-Clawline/global OpenClaw session key that exists in the fallback index must
remain routable even when Clawline has not adopted it and it is not present in
Clawline stream state. Rejecting such a key solely because it is not
Clawline-owned is a regression.

Full merged-store reads remain allowed for admin listing/adoption flows that
need metadata. They are not allowed for the alert hot path.

## Required Tests

- Legacy `lastMessageId` anchors only its owning stream; other streams recover
  from latest windows and report reset/truncation truthfully.
- Mixed per-stream map: valid cursor for stream A, invalid/stale/missing cursor
  for stream B, and legacy fallback for only streams without explicit map
  entries.
- Per-stream cap: fetch `cap + 1`, deliver `cap`, set `replayTruncated=true`
  when the extra row exists, and avoid per-stream `COUNT(*)`.
- Replay aborts on the first `sendJson=false` for auth result, stream
  snapshot/session info, or replay messages and removes the stale session.
- Replay/live crossover delivers replay before live, preserves messages created
  during replay, and suppresses duplicate server message IDs.
- Same stream: message B's dispatch cannot start until message A's dispatch
  lifecycle completes.
- Interactive callback dispatch for a stream cannot overlap an in-flight message
  dispatch for the same stream.
- Causal outbound replies produced by an inbound turn preserve same-stream
  ordering.
- Client auth includes `replayCursorsBySessionKey` for all known streams and
  does not replace it with a singular cursor.
- Client lifecycle replay advances `ProviderChatService` per-stream cursor
  storage after apply.
- Cache restore seeds missing cursor keys only and cannot move a live/replay
  advanced cursor backward.
- Alert fallback routes known non-Clawline session keys through the
  existence-only index.
- A valid non-Clawline/global OpenClaw session key is accepted even when it is
  not Clawline-owned or adopted.
- Repeated alert fallback lookups against unchanged stores do not perform full
  store loads, clones, merges, or iterations.
- Changed store file metadata invalidates the alert fallback index before the
  next answer.
