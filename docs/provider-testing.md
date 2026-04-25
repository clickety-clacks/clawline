# Provider Test Requirements (Clawline)

## Purpose

Define the minimum functional and behavioral coverage required for the Clawline provider implementation. This is a contract for contributors, not optional guidance.

All requirements in this document are normative. Treat each bullet as MUST for the provider implementation. Storage retention is an explicit product decision: v1 keeps all messages and media files indefinitely (no automatic pruning). Features explicitly marked “Not MVP” in `architecture.md` are intentionally excluded from required tests.

Replay/cursor, same-stream ordering, and alert fallback memory-pressure behavior
is further specified in `specs/clawline-replay-and-memory-pressure-invariants.md`.
If this document and that spec appear to conflict for those surfaces, update both
before implementation; do not implement from scratch notes.

## Test layers

1. **Unit tests** for pure logic (pairing/auth, token validation, allowlist, revocation, message routing).
2. **Integration tests** using a real in-process HTTP/WS server and real clients.
3. **Schema contract tests** that assert JSON behavior defined in this document. When the protocol evolves, update this document and tests together.

## Configuration defaults (v1)

Use these defaults when building fixtures; override per-test only when needed.

| Setting | Default |
| --- | --- |
| `pairing.maxPendingRequests` | `100` |
| `auth.jwtSigningKey` | required (HS256) |
| `auth.tokenTtlSeconds` | `31536000` |
| `pairing.maxRequestsPerMinute` | `5` |
| `auth.maxAttemptsPerMinute` | `5` |
| `pairing.pendingTtlSeconds` | `300` |
| `sessions.maxMessagesPerSecond` | `5` |
| `sessions.maxTypingPerSecond` | `2` |
| `sessions.typingAutoExpireSeconds` | `10` |
| `sessions.maxReplayMessagesPerStream` | `20` |
| `sessions.maxQueuedMessages` | `20` |
| `sessions.streamInactivitySeconds` | `300` |

### State file shapes referenced in tests

Tests refer to the allowlist/denylist JSON files defined in `provider-architecture.md`. The allowlist entry structure is:
```json
{
  "deviceId": "uuid",
  "claimedName": "optional label",
  "deviceInfo": { "platform": "...", "model": "...", "osVersion": "...", "appVersion": "..." },
  "userId": "user_uuid",
  "isAdmin": true,
  "tokenDelivered": true,
  "createdAt": 1704672000000,
  "lastSeenAt": 1704672000000
}
```
`createdAt` and `lastSeenAt` are Unix epoch milliseconds stored in the allowlist JSON. They are not JWT claims; tests should assert them via the JSON fixture or helper APIs that expose allowlist metadata.

## Test configuration overrides

Rate limits use a sliding rolling window per `deviceId` (last 60s for per-minute limits, last 1s for per-second limits). Windows are measured with millisecond precision (no fixed buckets): each request timestamp is recorded, and the server trims timestamps older than the window before counting. Counters persist across disconnects within the window (reconnects do not reset limits). On restart the in-memory history is cleared (intentionally).

## Required test scenarios (must pass)

### Pairing + Auth
- Pairing success flow returns `pair_result` with token + userId.
- `userId` is a server-generated opaque identifier (UUIDv4 string), stable for that device; tokens embed it as `sub`.
- `pair_result.reason` values: `pair_rejected` (denylist), `pair_denied` (admin denial), `pair_timeout` (expired).
- Reference table for assertions:
  | reason | Cause | Notes |
  | --- | --- | --- |
  | `pair_rejected` | DeviceId appears in denylist | Sent immediately; socket closes |
  | `pair_denied` | Admin explicitly denies during `pair_decision` | socket closes |
  | `pair_timeout` | Pending request exceeded 5-minute TTL | `pair_result` sent if requester still connected |
- Admin tooling surfaces a "Create account" action that asks the provider to mint a new `userId` (UUIDv4 string) before the admin sends `pair_decision`. In other words, `pair_decision.userId` is always supplied, but the value itself originates from the provider rather than being typed manually. Tests should model this by calling a helper that returns a fresh UUID when `approve: true` targets a brand-new account; reusing an existing UUID attaches the device to that account.
- Pairing request without `protocolVersion` is rejected with `invalid_message` and closes the connection.
- Pairing/auth with unknown `protocolVersion` is rejected with `invalid_message` and closes the connection.
- Explicit test: `protocolVersion: 2` (future value) on either `pair_request` or `auth` returns `invalid_message` and closes the socket.
- Non-integer `protocolVersion` (string, null, float) is rejected with `invalid_message` and closes the connection.
- First device auto-approval works when no admins exist.
- If first-admin bootstrap occurs and other pending requests exist, the newly approved admin receives `pair_approval_request` for them immediately (or on next connect).
- If multiple devices race for first-admin, the winner is the first `pair_request` message received by the server (not connection time); losers remain pending and can be approved once an admin exists (otherwise they time out).
- If the first-admin winner disconnects before receiving `pair_result`, `tokenDelivered` remains false and the device may re-request; losers are not auto-promoted.
- There is no admin-less auto-promotion; if no admin connects to approve pending requests, they simply time out (operator intervention required).
- Reconnect before token delivery: if a device disconnects before receiving `pair_result`, a subsequent `pair_request` with the same `deviceId` issues a fresh JWT (same `userId`/`isAdmin`, new `iat`/`exp`).
- Admin approval flow: `pair_approval_request` broadcast to admin, `pair_decision` approves/denies (when approving, `userId` is required).
- If no admins are connected, pending requests are queued and delivered when an admin connects (or time out).
- If a `pair_request` arrives while another pending request for the same `deviceId` exists, treat it as a reconnect: keep the original pending request/TTL (do not reset) and allow `pair_result` to be delivered on the new connection. Apply the normal per-minute rate limit if the device spams repeated requests.
- If a reconnecting `pair_request` includes different `claimedName` or `deviceInfo`, keep the original pending values (do not update).
- Pending pair requests expire after 5 minutes with `pair_result` `reason: pair_timeout`.
- `pair_timeout` results in `pair_result` `success: false` and closes the WebSocket.
- Pending pair requests remain in the queue until approved/denied or TTL expiry, even if the requester disconnects; expiration removes the pending entry. If the requester is disconnected at expiry, no `pair_result` is delivered.
- Pending pair requests are not persisted across provider restart; clients must re-request pairing after a restart.
- While a request is pending, any attempt to send `auth` MUST yield `{ type: "auth_result", success: false, reason: "device_not_approved" }` before the socket closes; tests should assert on this reason string (the schema lists it).
- Allowlist entry is created on approval with `tokenDelivered: false` and flips to `true` after `pair_result` is sent.
- `tokenDelivered` flips to `true` only after `pair_result` is successfully delivered; if the connection drops before delivery, keep `tokenDelivered: false` and re-issue on the next `pair_request`.
- "Successfully delivered" means the WebSocket send completes without error while the connection is open; if the send fails, do not flip `tokenDelivered`.
- Invalid `deviceId` format (non-UUIDv4) returns `invalid_message` (connection remains open).
- `deviceId` is globally unique within a provider instance; a new pairing with an existing `deviceId` is treated as the same device (reconnect), not a separate user.
- `pair_request` is rate limited to 5 per minute per deviceId; excess requests return `rate_limited` and close the connection.
- Pending pairing queue is capped (`maxPendingRequests`, default 100); when full, new `pair_request` returns `rate_limited`.
- Missing `deviceInfo.platform` or `deviceInfo.model` returns `invalid_message` (connection remains open).
- `deviceInfo` must be a JSON object with non-empty UTF-8 strings for `platform` and `model`; empty strings, `null`, or `{}` return `invalid_message`.
- Omitting optional `deviceInfo.osVersion` and `deviceInfo.appVersion` is valid.
- Re-pairing behavior decision tree:
  1. If no allowlist entry exists for `deviceId`: normal pairing flow (success produces new entry).
  2. If allowlist entry exists with `tokenDelivered: false`: re-issue JWT, keep same `userId`/`isAdmin`.
  3. If allowlist entry exists with `tokenDelivered: true` and `lastSeenAt` is null **and** `now - createdAt <= 600s`: allow one crash-only re-issue (same `userId`/`isAdmin`), then set `lastSeenAt` immediately.
  4. All other cases (`tokenDelivered: true` with `lastSeenAt` set or elapsed > 600s): respond with `invalid_message`, close the socket, and instruct operator to revoke manually.
- Re-pairing outside the above exception requires operator removal of the allowlist entry (or revocation); tests should not expect automatic recovery.
- Because `lastSeenAt` flips to a timestamp on the first successful `auth`, case (3) can only happen if the device never authenticated after receiving its token (e.g., provider crash in-between). Tests should model this by suppressing the initial `auth`.
- Denylisted devices receive `pair_result` `reason: pair_rejected`.
- Admin denial returns `pair_result` `reason: pair_denied`.
- `pair_decision` with malformed `userId` (non-UUIDv4 or empty string) returns `invalid_message` without closing the admin connection.
- If an admin denies while the requester is disconnected, the pending entry is removed immediately and the next `pair_request` from that `deviceId` receives `pair_denied` (does not wait for TTL).
- `pair_result` failure closes the WebSocket.
- Non-admin devices attempting `pair_decision` are rejected with `invalid_message` (connection remains open).
- First-admin losers stay pending even if the winner drops before receiving `pair_result`; when the bootstrap device eventually authenticates, the provider replays the queued `pair_approval_request`s to that admin so no request is lost.
- Admin decision race: first `pair_decision` wins; subsequent decisions for the same `deviceId` return `invalid_message` without closing the admin connection.
- `pair_decision` for an unknown `deviceId` returns `invalid_message` without closing the admin connection.
- `pair_decision` for an expired pending request is treated as unknown and returns `invalid_message` without closing the admin connection.
- `pair_decision` with `approve: true` and missing `userId` returns `invalid_message` without closing the admin connection.
- `pair_decision` messages inherit the protocol version from the already-authenticated admin socket and therefore do not include a `protocolVersion` field; tests should assert that admins on mismatched versions are rejected earlier during `auth`.
- If `tokenDelivered: true` but `lastSeenAt` is null and `createdAt` is within 10 minutes, allow a one-time re-issue without operator intervention. This is the only exception to the previous bullet and should be explicitly asserted in tests.
- Auth success returns `auth_result` and opens session.
- `auth_result` success includes `sessionId` (per-connection identifier).
- `auth_result` success includes `userId`.
- `sessionId` is diagnostic-only; clients never send it back.
- Auth failure returns `auth_result` with `success: false` and `reason: auth_failed`, then closes socket.
- Malformed/garbage token (non-JWT, empty string) returns `auth_result` `auth_failed` and closes socket.
- Expired (but not revoked) tokens are treated as `auth_failed` (not `token_revoked`).
- Valid JWT presented with a `deviceId` that differs from the token’s `deviceId` claim fails auth with `auth_failed` and closes the connection.
- JWTs missing the `deviceId` claim fail auth with `auth_failed` and close the connection.
- JWT `deviceId` claim must be a UUIDv4; invalid formats fail auth with `auth_failed`.
- JWT claims (v1): `sub` (userId), `deviceId` (claim key is exactly `"deviceId"`), `iat`, `exp`. Tokens are HS256-signed. Admin status is not part of the token; tests should assert it via `auth_result.isAdmin` and allowlist edits.
- Tokens expire after `tokenTtlSeconds` (default 1 year). V1 has no refresh flow; expired tokens require re-pairing (operator removal of allowlist entry).
- Revoked token fails auth with `reason: token_revoked`, then disconnects.
- Revoking a token while a session is active closes the session immediately.
- Revocation aborts any in-flight stream (no final message).
- Revocation-aborted streams still have a message record (created at receipt), marked failed, and no final assistant message is emitted.
- Implementation detail for tests: revocation sets `messages.streaming = 2` for any in-progress row (same as other failures).
- Queued messages belonging to streams whose only subscribed connection was revoked keep their durable message records and are marked failed (`messages.streaming = 2`); only in-memory queue entries are dropped. The corresponding client must resend after re-auth/pair with new `c_*` ids.
- Revocation drops any queued in-memory work for affected streams and does not emit per-message errors (session closes with `token_revoked`).
- Test: enqueue two messages on one stream, revoke the subscribed device before generation; ensure the durable records are marked failed, the stream queue is cleared with no `error` per message, and clients must resend after re-auth.
- If the last admin device is revoked, recovery is an operator action (reset state / remove allowlist); there is no in-protocol recovery.
- Auth without `protocolVersion` is rejected with `invalid_message` and closes the connection.
- `GET /version` (no auth) returns `{ "protocolVersion": 1 }`; tests should call it before pairing/auth to ensure version mismatches are caught by the client before attempting a socket connection.
- On every successful `auth`, the provider must persist `lastSeenAt=now` to the allowlist JSON before sending `auth_result`; tests should verify the timestamp changes even if the process crashes immediately afterward. During an active session the provider may batch updates, but it must flush at least once per minute and on disconnect. If the persist succeeds but the socket dies before `auth_result` arrives, the client simply retries `auth`; the earlier write stands (and counts toward re-issue prevention) and the retry counts toward the normal rate limit.
- `auth_result` is sent before replay; `replayCount` equals the number of finalized replay messages that are queued to follow (post-truncation). If replay fails mid-delivery, the provider closes the socket and the client must reconnect; partial deliveries are not retried in-band. `replayTruncated` indicates truncation.
- When no replay messages are sent, `replayCount: 0` and `replayTruncated: false` (both fields present).
- Excess auth attempts (5 per minute per deviceId) are rate-limited (`rate_limited`) and the connection is closed.
- `message` or `typing` sent before `auth` returns `error` with code `auth_failed` and closes the connection.

### Streaming + Messaging
- Non-streaming response sends one `message` with `streaming: false`.
- Streaming response sends multiple `message` events with same `id` and `streaming: true`, then a final `message` with `streaming: false` and full content.
- Streaming updates always include the full accumulated content so far (no deltas).
- Final streaming message content equals the full accumulated content.
- Database column `messages.streaming` uses integer states: `0 = finalized`, `1 = active`, `2 = failed/inactive`, `3 = queued/no-final-yet`. Tests should assert transitions explicitly.
- Server sends `ack` after the message record is durably persisted; if the record cannot be written, return `error` `server_error` and do not `ack`.
- The provider creates a message record at receipt time (before `ack`) and persists the content hash with that record. Records include an `ackSent` flag to handle crashes between persistence and `ack`.
- Records are created with `ackSent: false`. After a successful `ack` send, persist `ackSent: true`. If the send fails, keep `ackSent: false` and resend `ack` when the client retries.
- Message record creation and duplicate detection must be atomic (e.g., unique constraint on `deviceId` + `id`); concurrent duplicates result in one record and the rest are treated as retries.
- Test atomicity: two connections send the same `id` + `content` simultaneously; only one record is created, only one generation occurs, and both receive `ack`.
- In concurrent-duplicate cases, both connections receive `ack`, but assistant output is delivered only on the currently active connection (the socket whose auth completed most recently; older sockets are closed via `session_replaced`).
- If the provider crashes after record creation but before `ack`, the retry sees `ackSent: false` and is treated as an in-flight retry: send `ack` and proceed with generation (no `invalid_message`).
- If a client resends the same `id` after an `ack` timeout, the provider treats it as an idempotent retry.
- If a client resends pending `ack` IDs after reconnect, the provider treats them as idempotent retries.
- Session takeover: old connection is closed immediately after `session_replaced` is sent; it must not accept or ack new messages after that.
- The content hash for a duplicate `id` must reflect the first accepted content.
- Assistant responses after the new connection authenticates are delivered on the new connection only.
- Clients correlate responses by message `id`; the old connection should not wait for responses after `session_replaced`.
- If a stream is active when the new connection authenticates, move it to the new socket: send the latest full snapshot (`streaming: true`) to that connection, continue delivering updates there, and immediately close the old socket with `session_replaced`. Live resume is only possible during this overlap window. If both sockets disconnect, the client waits for reconnect replay; it retries with a new `id` only after the stream is failed/inactive with no final.
- The server signals takeover via the normal `session_replaced` error on the old socket; the new socket receives the same `s_*` stream id so the client can continue rendering the in-flight message without a new identifier.
- If the new connection fails to authenticate, the old connection remains active (no session takeover).
- If the old connection is already closed and the new connection fails auth, any stream queues that no longer have subscribed connections are dropped.
- If the new connection authenticates but immediately drops, the device has no active connection and must re-auth.
- Unacked messages from the old connection are not replayed; the client must resend after reconnect.
- Server-sent `message` events include `timestamp` (Unix epoch ms).
- Server-sent `message` events include `sessionKey` for every persisted or replayable chat event; clients route UI streams and advance replay cursors by that exact key.
- Echoed user messages always use a server-generated `s_` identifier even though the originating client supplied a `c_` id. The echo includes `clientMessageId` with that original `c_` id so clients can replace the correct optimistic local message.
- Assistant messages generated as a reply to a client message include `replyToMessageId` with the echoed user message's server `s_*` id. They may also include `replyToClientMessageId` for local diagnostics, but clients must use `replyToMessageId` for cross-device reply correlation. Independent outbound assistant messages omit both reply fields.
- `ServerMessage.deviceId` is present only on echoed user messages (`role: "user"`) so clients can attribute which device sent it; assistant/system messages omit it. Tests should ensure this behavior.
- `content` length over 64KB of UTF-8 encoded bytes (65,536 bytes) returns `payload_too_large`.
- Client-provided `id` on user messages is accepted only if it uses the `c_` prefix.
- Client `message.sessionKey` selects the target stream. Legacy clients may omit it, which routes to that connection's default Main stream. Multi-stream clients must include it for every non-default stream send.
- Invalid `id` prefixes are rejected with `invalid_message`.
- Client messages using an `s_` prefix are rejected with `invalid_message`.
- Missing `id` on client `message` is rejected with `invalid_message`.
- Content hash covers the `content` field only and is combined with attachment equality for duplicate detection.
- Duplicate handling decision tree (all checks run inside the single transaction):
  - Message records are inserted with `streaming = 1` (active) immediately after receipt; only the provider updates the field to `0` (finalized), `2` (failed), or `3` (queued/no-final-yet).
  1. If no message record exists: treat as a fresh generation.
  2. If a record exists, compute the SHA-256 hash of the raw `content` bytes and compare attachments (order-sensitive; inline images match on `mimeType` + decoded bytes; URL attachments match on `url`). If either mismatches—or if the attachment order differs—return `invalid_message`.
  3. If `messages.streaming = 2` (failed/inactive), return `invalid_message` (do not restart).
  4. If `messages.streaming = 1` (active stream): resend `ack` (if needed) and continue streaming on the currently active connection; no new generation starts.
  5. If `messages.streaming = 3` (queued/no-final-yet): resend `ack` (if needed), re-run adapter execution as a single queued entry, and continue as normal. `ackSent` only determines whether another `ack` is emitted; it never blocks this queued recovery path.
  6. If `messages.streaming = 0` and the final assistant event exists: resend `ack` (if needed); do not regenerate.
- Treat missing/undefined/null `attachments` as an empty array for equality checks.
- When a record exists for the `id`, duplicate handling runs before attachment/schema validation; retries that match the stored record are accepted even if the retry payload includes unexpected attachment fields.
- If an `ack` is dropped and the client resends the same `id`, the provider must not double-generate (idempotent retry).
- If a retry arrives and the record shows `ackSent: true`, resend `ack` and apply record-based idempotent handling; only the `messages.streaming = 3` queued/no-final-yet branch may re-run adapter execution.
- Cancel requests return `invalid_message` (v1 does not support cancellation).
- Server-assigned message IDs use `s_` prefix and are globally unique.

### Replay + Reconnect
- "Finalized message" means a `message` event with `streaming: false` (complete) that is persisted to history.
- "Partial" means a `message` event with `streaming: true` (not final).
- Only one assistant stream may be active per `(userId, sessionKey)` at a time. Messages for the same user and stream are queued FIFO. Different streams for the same user may run concurrently.
- Clients should send `replayCursorsBySessionKey` on auth: an object keyed by subscribed session key whose values are the last finalized/replayable server event IDs (`s_*`) fully processed for those exact streams.
- `lastMessageId` remains a compatibility fallback for older clients. It anchors only the stream that owns that event and must not be treated as a global cursor for unrelated streams.
- Empty-string or whitespace-only `lastMessageId` payloads are rejected with `invalid_message`; omit the field or send `null` when no prior events exist.
- Empty-string or whitespace-only values inside `replayCursorsBySessionKey` are ignored for that stream; valid entries for other streams remain usable.
- Reconnect with a valid per-stream cursor replays only messages after that cursor for that stream. If more than `maxReplayMessagesPerStream` (default 20) exist after that cursor, replay the last `maxReplayMessagesPerStream` of the missing range for that stream and set `replayTruncated: true`.
- Example: if one stream cursor is followed by 800 messages in chronological order `M1..M800`, replay the newest capped window for that stream and drop older messages outside the cap.
- Messages beyond the replay cap are not recoverable in v1 (recent-only history window).
- If a stream has no usable per-stream cursor and no owning legacy `lastMessageId`, replay sends that stream's most recent `maxReplayMessagesPerStream`.
- In that case, set `historyReset: true` for the auth result. `historyReset` is a conservative connection-level flag in v1; clients clear local caches for all subscribed streams and keep only the new auth/replay epoch. Set `replayTruncated: true` if that stream has more than `maxReplayMessagesPerStream` eligible finalized messages; otherwise `false` unless another stream is truncated.
- Replay truncation detection must fetch at most `maxReplayMessagesPerStream + 1` rows per stream and deliver at most `maxReplayMessagesPerStream`; tests must not depend on per-stream `COUNT(*)` queries.
- Duplicate messages are not emitted during replay + live stream crossover (server must drop duplicates by message `id`).
- Replay ordering is oldest-to-newest.
- Replay completes before any live messages are delivered to the newly authenticated socket (no interleaving). Messages created while replay is in progress must not be lost; use an explicit replay/live barrier and duplicate suppression by server message `id`. If post-replay gap fill is used, those gap-fill messages are delivered as live messages and are excluded from `auth_result.replayCount`.
- After replay messages and any immediately queued post-replay gap-fill live messages have been sent, the provider sends `{ "type": "sync_complete" }`. Clients must not run missing-final detection from reconnect until this control event arrives.
- Queued messages are processed only after replay completes.
- Replay includes only finalized messages (partials are never replayed).
- Streaming partials do not advance replay cursors. If a partial and final assistant message share the same `id`, the final message is the replayable event and must still be applied/replayed even when the client processed the partial before disconnect.
- Replay includes server-sent assistant messages and echoed user messages.
- Replay includes messages even if referenced files are missing; clients may see `not_found` when fetching those URLs.
- Within a single stream, an unfinished assistant stream implies there are no later finalized assistant messages for that same `(userId, sessionKey)`; stopping that stream's replay before the partial does not drop assistant output for that stream. Other streams are independent.
- Replay never includes partials. If an unfinished stream exists, replay delivers all finalized messages before it, stops before the partial, and the client must retry with a new `id` (retrying the same `id` returns `invalid_message`). Unfinished streams are marked failed in the message record.
- Client requirement: after a failed/inactive stream, retry with a new `id` (never reuse the old `id`).
- If a user message was acked and generation continues after disconnect, the final assistant message is persisted and replayed on reconnect. If generation becomes inactive without a final message, the stream is marked failed and the client must retry with a new `id`.
- If no streaming updates arrive within `streamInactivitySeconds` from the time the message record was created, the stream becomes inactive (even if no output was ever sent or `ack` never reached the client).
- If no finalized message exists after the skipped partial, replay sends no additional content and the client discards the partial.
- If the client has a cached partial, it discards it once `sync_complete` arrives and no final message with that `id` arrived.
- Streaming delivery is never resumed after a disconnect/reconnect; only overlapping session takeover can continue a live stream. If the originating socket drops, active generation may continue in the background until it finalizes or becomes inactive. Finalized output is replayable; partial output is not.
- **Session takeover clarification:** if a second connection authenticates for the same `deviceId` *before* the original socket closes, the provider moves the active stream to the new socket by sending the latest full-content snapshot (`streaming: true`) and continuing full-content updates there (no deltas). This is not replay; it is the continuity expectation while both sockets overlap for a brief handoff.
- **Reconnect vs takeover summary:** Takeover requires overlapping sockets (new one authenticates before the old closes) and keeps the existing `s_*` id live; the old socket receives `session_replaced`. If the old socket closes before a replacement authenticates, live streaming stops for that client. On reconnect, replay delivers a finalized assistant message if generation completed; otherwise the client must retry with a new `c_*` id once the stream is failed/inactive.
- "Still active" means either (a) no streaming updates have been emitted yet and the elapsed time since message record creation is < `streamInactivitySeconds`, or (b) the last streaming update occurred within `streamInactivitySeconds`. "Unfinished/inactive" means no streaming updates for that window and no final message.
- Stream record states: `active` (generation ongoing), `failed` (inactive timeout or revocation), `finalized` (final response sent). "Inactive" means the record is marked `failed`.
- "Streaming update" means a `message` event with `streaming: true` for that message ID.
- Stream inactivity timer starts at message record creation (receipt), even if `ack` send fails. If no streaming update arrives within `streamInactivitySeconds`, the stream is considered inactive. After the first streaming update, the timer resets on each subsequent streaming update.
- Messages sent by the client during replay are accepted/acked but only processed after replay completes (no interleaving).
- Messages sent during replay still count toward the queue cap; if the queue is full, reject with `rate_limited`.
- Only one assistant stream may be active per `(userId, sessionKey)`; additional user messages for that stream are queued and processed sequentially.
- Each stream queue is FIFO, capped at `maxQueuedMessages` (default 20); when full, new messages for that stream are rejected with `rate_limited`.
- Queue ordering is by server receipt time for that stream across all connections; when full, reject the incoming message (no eviction of existing queue).
- The queue holds messages awaiting generation for that stream; the currently generating message is the active stream and is not part of the queue. When no connection remains subscribed to the stream, queued-but-not-started entries are dropped; during session takeover the queue persists. The active stream continues until completion or inactivity timeout.
- Queues are scoped by `(userId, sessionKey)`, not by device. Clients must resend all unacked messages after reconnect (intentional limitation).
- If no streaming updates occur for `streamInactivitySeconds` (default 300), the stream is considered failed and no partial is replayed.
- If a second connection authenticates with the same `deviceId`, the new connection wins and the old socket closes immediately.
- If the provider restarts mid-stream (no partials persisted), the client resends the original message with a new `id` and a new generation begins.
- When replay is truncated by the cap, `auth_result.replayTruncated` is true.
- If `sendJson` fails while sending `auth_result`, stream snapshot/session info, or any replay message, replay aborts immediately, the stale session is removed/closed, and the client must reconnect.

### Alert fallback session-key lookup
- Alert fallback routing MUST be pressure-safe, not merely functionally correct.
- If an alert session key is found in Clawline stream state, route through that Clawline-owned stream key.
- If it is not found in Clawline stream state, fallback lookup MUST use a dedicated existence-only index over relevant OpenClaw session-store files.
- A valid non-Clawline/global OpenClaw session key that exists in that index MUST route even when Clawline has not adopted or otherwise owned it. Rejecting an existing non-Clawline key solely because it is outside Clawline stream state is a regression.
- The fallback index stores only normalized session keys and the data needed to return the normalized key.
- The fallback index is invalidated by authoritative store file metadata, at minimum `mtimeMs` and `size`.
- Alert fallback MUST NOT use `loadMergedSessionStoreForClawline()`, `loadSessionStoreEntryForKey()`, full session entries, adoption metadata, generic merged-store/listing paths, or repeated full-store clone/iteration as the steady-state hot path.
- Tests must cover: known non-Clawline key routes successfully through the index without Clawline adoption; repeated unchanged-store lookups do not perform full-store loads/clones/merges/iterations; changed store metadata invalidates the index before answering; store file creation/deletion invalidates the index before answering; unknown key returns 404 and does not enqueue.

### Pairing + Auth (concurrency)
- First-admin bootstrap is atomic: only one device can win when two devices attempt first-admin concurrently.
- Concurrent first-admin losers remain pending and time out after 5 minutes if not approved.
- If allowlist lock contention prevents bootstrap within 10 seconds, pairing returns `server_error` but the pending request remains until TTL expiry.
- Concurrent `auth` race: when two sockets authenticate with the same `deviceId`, the server enqueues them; the newest entry that completes JWT validation wins, and older sockets receive `session_replaced` immediately after learning of the newer success.

### Media (Inline + Upload)
- Inline attachments <= 256KB raw bytes (pre-base64) accepted; > 256KB rejected with `error` (`payload_too_large`).
- Max inline attachments per message: 4. Exceeding this returns `payload_too_large`.
- Total inline attachment bytes per message must be <= 256KB (sum of all inline attachment raw bytes).
- Total message payload (UTF-8 `content` bytes + inline attachment raw bytes) must be <= 320KB; exceeding this returns `payload_too_large`.
- Attachment count limit applies to both inline and URL attachments; byte limits apply only to inline data.
- `POST /upload` returns `id`, `url`, `mimeType`, `size`.
- Uploads over 100MB are rejected with `payload_too_large`.
- Multipart field name is `file`.
- Multipart uploads with a different field name are rejected with `invalid_message`.
- Message referencing a returned `url` is accepted and stored.
- Endpoint coverage matrix for integration tests:
  | Path | Method | Auth | Expected behavior |
  | --- | --- | --- | --- |
  | `/ws` | WebSocket | JWT via `auth` message | Drives pairing/auth/chat. Verify `pair_request`, `auth`, `message`, `typing`, `pair_decision`, `pair_approval_request`. |
  | `/version` | GET | None | Returns `{ "protocolVersion": 1 }`. Use as preflight check. |
  | `/upload` | POST multipart (`file` part) | `Authorization: Bearer <token>` | Enforce inline vs URL limits, emit `upload_failed_retryable` on disk errors. |
  | `/www/...` | GET | None | Serves bytes from the web root (default `workspace/www`); 404 if missing. |
- Missing or malformed `Authorization` header (`Bearer` absent/empty) on `/upload` returns `auth_failed`.
- HTTP error responses MUST return JSON bodies matching `{ "type": "error", "code": "<code>", "message": "<human-readable>" }`.
- HTTP error responses return JSON error bodies with status mappings: 400 `invalid_message`, 401 `auth_failed`, 403 `token_revoked`, 404 `not_found`, 413 `payload_too_large`, 429 `rate_limited`, 503 `upload_failed_retryable`, 500 `server_error`.
- Files are retained indefinitely in v1 unless an operator removes them from the `/www` web root (unmanaged dumping-ground).

### Error Handling
- `error` schema matches `{ type: "error", code, message, messageId? }`.
- Valid `error.code` values (v1): `auth_failed`, `token_revoked`, `invalid_message`, `payload_too_large`, `not_found`, `rate_limited`, `session_replaced`, `upload_failed_retryable`, `server_error`.
- `auth_result.reason` is a separate enumeration (`auth_failed` / `token_revoked` / `device_not_approved`) and should not be conflated with `error.code`.
- Upload errors return `error` with `upload_failed_retryable` when the server fails to persist bytes (e.g., disk full or write error).
- Pairing outcomes (denylist/admin denial/timeout) are expressed via `pair_result` (not `error`).
- Pairing denial returns `pair_result` with `success: false` and `reason: pair_denied`.
- Unknown message types return `invalid_message`.
- Typing indicator auto-clears after 10 seconds without receiving a `typing` event from that device.
- Sending `typing: true` resets the 10-second timer; sending `typing: false` clears it immediately.
- Server rate limits `message` events to 5 per second per device; excess messages return `rate_limited`.
- Server rate limits `typing` events to 2 per second per device; excess messages return `rate_limited`.
- `rate_limited` for message/typing does not close the connection.
- After `rate_limited`, clients should wait for the relevant window to elapse (1s for per-second limits, 60s for per-minute limits) before retrying.
- Session takeover sends `error` with `session_replaced` immediately when the new connection authenticates; the old connection is closed right away.
- LLM failure mid-stream emits `error` `server_error` with `messageId` and no final `message`.
- After a mid-stream failure, the provider continues with the next queued message (queue does not stall).
- Failed streams still create a message record for the client `id`.
- Server closes the connection if no pong is received within 90 seconds of the last ping.

#### Connection-closing conditions (v1)

| Condition | Response |
| --- | --- |
| Malformed JSON | Close without `error` |
| Pre-auth `message`/`typing` | `error` `auth_failed`, then close |
| `pair_request` rate limited | `error` `rate_limited`, then close |
| `auth` rate limited | `error` `rate_limited`, then close |
| `auth_failed` / `token_revoked` | `auth_result` `success: false`, then close |
| `session_replaced` | `error` `session_replaced`, then close immediately |
| `pair_result` failure (`pair_denied`/`pair_rejected`/`pair_timeout`) | `pair_result` `success: false`, then close |

`not_found` does not close the connection.

WebSocket close codes (v1):
- `1008` (Policy Violation) for `invalid_message`, `auth_failed`, `token_revoked`, `rate_limited`
- `1011` (Server Error) for `server_error`
- `1000` (Normal Closure) for `session_replaced` and `pair_result` failures
- `1002` (Protocol Error) for malformed JSON (parse failure)

#### `invalid_message` connection behavior (v1)

| Condition | Close? |
| --- | --- |
| Missing/unknown/invalid-type `protocolVersion` on `pair_request` or `auth` | Yes |
| `pair_request` from allowlisted device with `tokenDelivered: true` | Yes |
| All other `invalid_message` cases (bad `deviceId`, missing fields, invalid prefixes, cancel, unknown message types, etc.) | No |

### Schema contract
- Schema tests target `protocolVersion: 1` as specified in this document. Update this document and tests together when the protocol evolves.
- Missing top-level `type` returns `invalid_message`.
- Invalid JSON (parse failure) closes the connection without an `error`.
- Missing required fields in `pair_request`/`auth` (except `protocolVersion`) returns `invalid_message` (connection remains open).
- Missing `content` on client `message` returns `invalid_message` (connection remains open).
- Empty-string `content` is rejected with `invalid_message`.
- `typing` schema: `{ "type": "typing", "active": boolean, "role"?: "assistant" }` (client uses `active`, server may include `role: "assistant"`).
- Client `typing` messages must not include `role`; if present, return `invalid_message`.
- `attachments` schema: `attachments?: [{ "type": "image", "mimeType": string, "data": string }, { "type": "url", "url": string }]`. Inline images use base64 `data`; URL attachments reference files under the web root.
- Each attachment object must include `type`; unknown `type` values return `invalid_message`. For `type: "image"`, `mimeType` and `data` are required and must be non-empty strings; for `type: "url"`, `url` is required and must be non-empty.
- Each `attachments` entry must be an object; non-object entries (`null`, string, number) return `invalid_message`.
- Inline image `data` must be valid base64; invalid base64 returns `invalid_message`. Base64 decoding should ignore whitespace and padding; equality compares decoded bytes.
- Allowed inline image `mimeType` values: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`. Other values return `invalid_message`.
- `auth` schema includes `lastMessageId?: string | null` for compatibility and `replayCursorsBySessionKey?: Record<string, string>` for per-stream replay recovery: `{ "type": "auth", "protocolVersion": 1, "token": string, "deviceId": string, "lastMessageId"?: string | null, "replayCursorsBySessionKey"?: Record<string, string> }`.
- `lastMessageId: null` and omitted are equivalent; empty string is `invalid_message`.

#### Message Schemas (v1)
```ts
// Client -> Server
pair_request: { type: "pair_request"; protocolVersion: 1; deviceId: string; claimedName?: string; deviceInfo: { platform: string; model: string; osVersion?: string; appVersion?: string } }
pair_decision: { type: "pair_decision"; deviceId: string; approve: boolean; userId?: string }
auth: { type: "auth"; protocolVersion: 1; token: string; deviceId: string; lastMessageId?: string | null; replayCursorsBySessionKey?: Record<string, string> }
message (client): { type: "message"; id: string; content: string; sessionKey?: string; attachments?: Attachment[] }
typing (client): { type: "typing"; active: boolean }

// Server -> Client
pair_approval_request: { type: "pair_approval_request"; deviceId: string; claimedName?: string; deviceInfo: { platform: string; model: string; osVersion?: string; appVersion?: string } }
pair_result: { type: "pair_result"; success: boolean; token?: string; userId?: string; reason?: "pair_rejected" | "pair_denied" | "pair_timeout" }
auth_result: { type: "auth_result"; success: true; userId: string; sessionId: string; isAdmin: boolean; replayCount: number; replayTruncated: boolean; historyReset: boolean } | { type: "auth_result"; success: false; reason: "auth_failed" | "token_revoked" | "device_not_approved" }
ack: { type: "ack"; id: string }
message (server): { type: "message"; id: string; role: "assistant" | "user"; content: string; timestamp: number; sessionKey: string; streaming: boolean; attachments?: Attachment[]; deviceId?: string; clientMessageId?: string; replyToMessageId?: string; replyToClientMessageId?: string }
typing: { type: "typing"; active: boolean; role?: "assistant" }
sync_complete: { type: "sync_complete" }
error: { type: "error"; code: string; message: string; messageId?: string }
```
On `auth_result` with `success: true`, `userId`, `sessionId`, `isAdmin`, `replayCount`, `replayTruncated`, and `historyReset` are required; on `success: false`, those fields may be omitted.
On `pair_result` with `success: true`, `token` and `userId` are required; on `success: false`, `reason` is required and `token`/`userId` are omitted.

### HTTP endpoints
- `GET /version` returns `{ "protocolVersion": 1 }` (no auth).

## Test harness expectations

- Use a real WS client + HTTP client against an in-process provider.
- Connect via `/ws` endpoint (required).
- Non-WebSocket requests to `/ws` return `426` (Upgrade Required).
- Simulate network loss by closing sockets mid-stream and asserting reconnection + replay behavior.
- Use temp directories for media storage and state.
- Provide a controllable clock or time-travel hook in tests (fake timers) to advance time for retention/timeout scenarios.
- Provide a deterministic JWT signing key via config for auth tests.
- Verify HTTP auth uses `Authorization: Bearer <token>` on `/upload`.
- Verify invalid/expired tokens on `/upload` fail with `auth_failed` or `token_revoked`.
- Include keepalive coverage (server sends ping every 30s; server closes if no pong within 90s; client closes if no server ping within 90s).
- Client must not send ping frames (server-initiated keepalive only).
- If a client sends a ping frame, the server ignores it (no close).
- Include malformed JSON / missing required fields tests returning `invalid_message`.
- Malformed JSON (parse failure) closes the connection.
- Include a typing auto-clear test (no `typing` events for 10s clears the indicator).
- Binding to a non-localhost address without `allowInsecurePublic: true` should fail fast.

## Non-goals (v1)

- Push notifications
- Read receipts
- Android/watchOS client coverage
- End-to-end encryption
