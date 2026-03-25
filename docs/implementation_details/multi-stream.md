# Multi-Stream — Non-Obvious Details

## `sessionKey` IS the stream ID — no separate `streamId` abstraction
Phase A uses session key as the canonical stream identifier everywhere: database, REST path, WebSocket payload, iOS in-memory/UI. There is no `streamId` field or mapping table. Code that introduces a separate stream ID is incompatible with this model.

## `agent:main:main` is just another session key in this model
The global admin stream is not special-cased at the metadata level. It can appear as a `stream_sessions` row for any user that has access to it. No special identity handling required.

## Suffix generation for custom streams: 8 lowercase hex chars from secure random — regenerate on collision
Custom stream keys use `agent:<agentId>:clawline:<userId>:s_<suffix>` where suffix is 8 lowercase hex chars. Regenerate on collision for same user. Do not use sequential IDs or timestamp-based suffixes — these are guessable.

## Gaps in `orderIndex` are allowed after deletes — do NOT renumber existing rows in Phase A
After deletion, `orderIndex` values have gaps. This is intentional for Phase A. Renumbering existing rows invalidates any cached order data on connected clients. Phase A explicitly does not reorder.

## `UNIQUE (userId, orderIndex)` constraint — concurrent create must use serialized append
The `stream_sessions` table has a UNIQUE constraint on `(userId, orderIndex)`. Concurrent create requests must serialize the order assignment. Naive parallel inserts on `max(orderIndex)+1` race and produce a constraint violation.

## `stream_snapshot` must be sent BEFORE replay messages on auth
The WS `stream_snapshot` is sent after successful auth and before any replay messages. Clients that receive replay messages before the stream snapshot cannot correctly route those messages to the right stream UI.

## Hard-delete transaction order: assets → messages → events → stream row
The delete transaction must proceed in this order: (1) `message_assets` rows, (2) `messages` rows, (3) `events` rows, (4) `stream_sessions` row. Reversing this order can leave orphaned asset references. Foreign key integrity depends on this order.

## Legacy row backfill: `events.sessionKey` must be backfilled before enabling hard-delete and replay filtering
Historical event rows have `sessionKey = NULL` (the column is new). Hard-delete and stream-scoped replay filtering depend on `events.sessionKey`. The backfill migration parses stored `payloadJson` to extract session keys. Do not enable those features before backfill is confirmed complete.

## Idempotency window is 7 days — cleanup of old keys runs at startup and periodically
`stream_idempotency` records older than 7 days are cleaned up. This affects retry windows: a retry submitted after 7 days will be treated as a new operation. The spec does not guarantee idempotency beyond 7 days.

## Stream deletion is client-initiated ONLY — server never auto-deletes, auto-archives, or expires streams
Streams can only be deleted by explicit client user action. The `409 stream_delete_requires_user_action` error code exists to reject any non-user-action path (e.g., automated API calls without explicit client attribution). There is no TTL, expiry, or background archival in Phase A.

## iOS: `SessionKey.isClawlinePersonalDM` currently hardcodes `parts[1] == "main"`
Until the multi-agent routing migration is complete, iOS only accepts Clawline personal streams for the `main` agent ID. Any stream with a different agent ID in the key will not be recognized as a personal DM. This must be generalized as part of Phase 3 of the multi-agent routing work.
