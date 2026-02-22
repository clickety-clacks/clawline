# Clawline Multi-Stream Spec (Phase A: N-Stream)

Status: Draft (implementation-grade)
Last updated: 2026-02-12
Sources: clickety-clacks/clawline#71, `multi-stream-review.md`, Flynn decisions

## 1. Purpose

Implement Phase A multi-stream support for Clawline across:
- Provider/server (`src/clawline/...`)
- iOS client (`ios/Clawline/...`)

Phase A delivers dynamic N-stream sessions (create, rename, delete, page between streams).

## 2. Scope and Non-Goals

### 2.1 In scope (Phase A)

1. Dynamic stream list per user (not fixed Personal/Admin only).
2. Stream metadata stored server-side and replayed to all clients.
3. Stream manager UI: Add, Rename, Delete.
4. Page dots UI tied to ordered stream list.
5. Session-key-based stream identity end-to-end.
6. Hard delete behavior for stream deletion (session + messages removed).

### 2.2 Out of scope (Phase A)

1. Fork implementation.
2. Merge implementation.
3. Stream reordering UI/API.
4. Feature negotiation for legacy clients.
5. Optimistic concurrency / tree version checks.

Fork/merge are captured only in Appendix A for future phases.

## 3. Binding Decisions (Applied)

1. Phase A only: N-stream. No fork/merge implementation in v1.
2. Concurrency model: first-wins server processing. No `treeVersion`, no optimistic concurrency fields.
3. Feature negotiation: removed. Server always emits stream events.
4. Identity model: session keys are stream IDs. No separate `st_<uuid>` IDs. No mapping table.
5. Ordering: append-only on create. No user-driven reorder feature.
6. Delete semantics: delete stream means delete session and all its messages (hard delete).
7. `agent:main:main` is just another session key in this model.
8. Deletion initiation: stream deletion is client-initiated only (explicit user UI action). Server never auto-deletes, auto-archives, or expires streams.

## 4. Canonical Identity and Ordering Model

### 4.1 Stream identifier

`sessionKey` is the canonical stream identifier everywhere:
- Database metadata row key
- REST path parameter
- WebSocket payload key
- iOS in-memory/UI identity key

No `streamId` abstraction in Phase A.

### 4.2 Session key formats

Built-ins remain unchanged:
- Main: `agent:<agentId>:clawline:<userId>:main`
- DM (if enabled by provider config): `agent:<agentId>:clawline:<userId>:dm`
- Global admin stream: `agent:main:main`

Custom streams use the existing 5-part Clawline pattern:
- `agent:<agentId>:clawline:<userId>:s_<suffix>`

`suffix` generation for new streams:
- 8 lowercase hex chars from a secure random value.
- Regenerate on collision for same user.

### 4.3 Ownership semantics

The metadata key is `(userId, sessionKey)`.

`agent:main:main` can appear as a metadata row for any user that has access to that stream. This does not require special identity handling; it is a normal session key.

### 4.4 Ordering semantics

`orderIndex` is an integer per `(userId, sessionKey)` metadata row.

Rules:
1. Existing built-ins are seeded first.
2. New stream creation appends to end (`max(orderIndex)+1`).
3. No reorder API in Phase A.
4. Gaps are allowed after deletes; do not renumber existing rows in Phase A.

## 5. Provider (Server) Changes

## 5.1 Database schema (exact)

Migration target: `PRAGMA user_version = 2`.

### 5.1.1 New table: `stream_sessions`

```sql
CREATE TABLE IF NOT EXISTS stream_sessions (
  userId TEXT NOT NULL,
  sessionKey TEXT NOT NULL,
  displayName TEXT NOT NULL,
  kind TEXT NOT NULL,             -- main | dm | global_dm | custom
  orderIndex INTEGER NOT NULL,
  isBuiltIn INTEGER NOT NULL,     -- 1 for built-ins, 0 for custom
  createdAt INTEGER NOT NULL,
  updatedAt INTEGER NOT NULL,
  PRIMARY KEY (userId, sessionKey),
  UNIQUE (userId, orderIndex)
);

CREATE INDEX IF NOT EXISTS idx_stream_sessions_user_order
  ON stream_sessions(userId, orderIndex);
```

### 5.1.2 New table: `stream_idempotency`

Used for safe retries on create/delete operations.

```sql
CREATE TABLE IF NOT EXISTS stream_idempotency (
  userId TEXT NOT NULL,
  idempotencyKey TEXT NOT NULL,
  operation TEXT NOT NULL,
  responseJson TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  PRIMARY KEY (userId, idempotencyKey)
);

CREATE INDEX IF NOT EXISTS idx_stream_idempotency_created
  ON stream_idempotency(createdAt);
```

Retention policy:
- Cleanup rows older than 7 days at startup and periodically.
- This cleanup applies only to `stream_idempotency` records, not stream/session deletion.

### 5.1.3 Existing `events` table additive fields

```sql
ALTER TABLE events ADD COLUMN eventType TEXT NOT NULL DEFAULT 'message';
ALTER TABLE events ADD COLUMN sessionKey TEXT;

CREATE INDEX IF NOT EXISTS idx_events_user_type_sequence
  ON events(userId, eventType, sequence);

CREATE INDEX IF NOT EXISTS idx_events_user_session_sequence
  ON events(userId, sessionKey, sequence);
```

`eventType` values in Phase A:
- `message`
- `stream_topology`

`sessionKey` usage:
- Set for `message` events.
- Null for topology events.

Legacy row requirement:
- Backfill `events.sessionKey` for historical `message` events before enabling hard-delete and replay filtering logic.

## 5.2 Migration from current single/two-stream model

At provider startup in `src/clawline/server.ts`:

1. Create new tables/indices/additive columns.
2. Discover known users from allowlist and existing event rows.
3. Backfill stream metadata rows for built-ins per user:
- seed all configured built-ins regardless of message history
- assign built-ins in precedence order: `main`, then `dm`, then any other configured built-ins
- assign contiguous initial `orderIndex` values starting at `0` in that precedence order
- default `displayName` by built-in `kind`:
  - `main` => `Personal`
  - `dm` => `DM`
  - `global_dm` => `Admin` (or deployment-specific override)
4. Discover additional historical stream keys by scanning:
- `SELECT DISTINCT sessionKey FROM events WHERE sessionKey IS NOT NULL`
- `SELECT DISTINCT sessionKey FROM messages WHERE sessionKey IS NOT NULL` (if column exists in schema)
5. For discovered non-built-in keys, insert `kind='custom'`, `isBuiltIn=0`, append by `orderIndex`.
6. Backfill `events.sessionKey` where null by parsing stored message event payloads and extracting session key.
7. Do not rewrite existing message payload bodies/content.

Migration is additive and non-destructive except for future explicit delete operations.

## 5.3 Runtime metadata model

Canonical stream metadata payload:

```json
{
  "sessionKey": "agent:main:clawline:flynn:s_8fa12c44",
  "displayName": "Research",
  "kind": "custom",
  "orderIndex": 3,
  "isBuiltIn": false,
  "createdAt": 1762990000000,
  "updatedAt": 1762990000000
}
```

## 5.4 REST API (authoritative mutation plane)

Client-initiated topology mutations are REST. Server then broadcasts WS topology events.
Server may also create streams internally, but must emit the same WS topology events.

Auth: same bearer token/cookie model used by existing provider endpoints.

Common API rules:
1. `sessionKey` path segments must be URL-encoded by the client.
2. All timestamps are Unix epoch milliseconds (UTC).
3. Error envelope for non-2xx:

```json
{
  "error": {
    "code": "stream_not_found",
    "message": "Human-readable summary"
  }
}
```

4. Idempotency behavior:
- If `idempotencyKey` repeats with same `(userId, operation, normalized request)`, return original stored response.
- If `idempotencyKey` repeats with different operation or different request body, return `409 idempotency_key_reused`.

### 5.4.1 `GET /api/streams`

Response `200`:

```json
{
  "streams": [
    {
      "sessionKey": "agent:main:clawline:flynn:main",
      "displayName": "Personal",
      "kind": "main",
      "orderIndex": 0,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    },
    {
      "sessionKey": "agent:main:clawline:flynn:dm",
      "displayName": "DM",
      "kind": "dm",
      "orderIndex": 1,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    },
    {
      "sessionKey": "agent:main:main",
      "displayName": "Admin",
      "kind": "global_dm",
      "orderIndex": 2,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    }
  ]
}
```

Ordering guarantee:
- Sorted ascending by `orderIndex`.

### 5.4.2 `POST /api/streams`

Creates a custom stream and appends it.

Request:

```json
{
  "idempotencyKey": "req_3cf0d2f1",
  "displayName": "Research"
}
```

Response `201`:

```json
{
  "stream": {
    "sessionKey": "agent:main:clawline:flynn:s_8fa12c44",
    "displayName": "Research",
    "kind": "custom",
    "orderIndex": 3,
    "isBuiltIn": false,
    "createdAt": 1762991000000,
    "updatedAt": 1762991000000
  }
}
```

Validation/errors:
- `400 invalid_display_name`
- `409 stream_limit_reached`

Round-trip requirement (normative):
1. Persist the new `stream_sessions` row in DB.
2. Return `201` with created stream payload.
3. Emit `stream_created` to all active authenticated WS connections for the user, including:
- the client that issued `POST /api/streams`
- any other connected client for that same user
4. Clients must not require a manual refresh to see the new stream.

### 5.4.3 `PATCH /api/streams/:sessionKey`

Renames a stream.

Path rules:
- `:sessionKey` must be URL-encoded by client.

Request:

```json
{
  "displayName": "Research v2"
}
```

Response `200`:

```json
{
  "stream": {
    "sessionKey": "agent:main:clawline:flynn:s_8fa12c44",
    "displayName": "Research v2",
    "kind": "custom",
    "orderIndex": 3,
    "isBuiltIn": false,
    "createdAt": 1762991000000,
    "updatedAt": 1762992000000
  }
}
```

Validation/errors:
- `404 stream_not_found`
- `409 built_in_stream_rename_forbidden`

### 5.4.4 `DELETE /api/streams/:sessionKey`

Deletes stream metadata and all messages/events in that session.
Deletion may only be executed as a direct result of a client request from user action.

Path rules:
- `:sessionKey` must be URL-encoded by client.

Request body (optional but recommended for retries):

```json
{
  "idempotencyKey": "req_7a221901"
}
```

Response `200`:

```json
{
  "deletedSessionKey": "agent:main:clawline:flynn:s_8fa12c44"
}
```

Validation/errors:
- `404 stream_not_found`
- `409 built_in_stream_delete_forbidden`
- `409 last_stream_delete_forbidden`
- `409 stream_delete_requires_user_action` (if request is not attributable to explicit client delete action)

Hard delete transaction behavior:
- Preconditions: target stream is not built-in, and deleting it will not remove the user's last remaining stream.
1. Delete `message_assets` rows for messages in `(userId, sessionKey)`.
2. Delete `messages` rows in `(userId, sessionKey)`.
3. Delete `events` rows in `(userId, sessionKey)`.
4. Delete `stream_sessions` row.
5. Optional: delete now-orphaned assets synchronously within the same request transaction.
6. Do not run any background stream/session expiry or archive flow.

No soft-delete flag is introduced in Phase A.

## 5.5 WebSocket protocol (authoritative event plane)

### 5.5.1 New server-to-client message types

#### `stream_snapshot`

Sent after successful auth, before replay messages.

```json
{
  "type": "stream_snapshot",
  "streams": [
    {
      "sessionKey": "agent:main:clawline:flynn:main",
      "displayName": "Personal",
      "kind": "main",
      "orderIndex": 0,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    },
    {
      "sessionKey": "agent:main:clawline:flynn:dm",
      "displayName": "DM",
      "kind": "dm",
      "orderIndex": 1,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    },
    {
      "sessionKey": "agent:main:main",
      "displayName": "Admin",
      "kind": "global_dm",
      "orderIndex": 2,
      "isBuiltIn": true,
      "createdAt": 1762990000000,
      "updatedAt": 1762990000000
    }
  ]
}
```

Cold-start invariant:
- `stream_snapshot` must always include all configured built-in streams, even when they have zero messages and no historical activity.

#### `stream_created`

```json
{
  "type": "stream_created",
  "stream": {
    "sessionKey": "agent:main:clawline:flynn:s_8fa12c44",
    "displayName": "Research",
    "kind": "custom",
    "orderIndex": 3,
    "isBuiltIn": false,
    "createdAt": 1762991000000,
    "updatedAt": 1762991000000
  }
}
```

#### `stream_updated`

```json
{
  "type": "stream_updated",
  "stream": {
    "sessionKey": "agent:main:clawline:flynn:s_8fa12c44",
    "displayName": "Research v2",
    "kind": "custom",
    "orderIndex": 3,
    "isBuiltIn": false,
    "createdAt": 1762991000000,
    "updatedAt": 1762992000000
  }
}
```

#### `stream_deleted`

```json
{
  "type": "stream_deleted",
  "sessionKey": "agent:main:clawline:flynn:s_8fa12c44"
}
```

Emission rule:
- Emit only after successful `DELETE /api/streams/:sessionKey`.
- Never emit from autonomous server cleanup/expiration behavior.

Broadcast scope:
- Broadcast to all active authenticated WS connections for the same user.
- This applies regardless of creation origin (REST from one client or provider-internal stream creation).

### 5.5.2 Client-to-server WS messages

No new C2S message types in Phase A.

Existing C2S messages stay unchanged:
- `auth`
- `message`
- `interactive-callback`
- `pair_request`

### 5.5.3 `auth_result` and `message`

No feature negotiation fields added.

`message.sessionKey` remains required and is the stream identifier used by the client.

## 5.6 Replay behavior (Phase A)

On successful auth:
1. Server sends `auth_result`.
2. Server sends `stream_snapshot` (current full stream metadata list).
3. Server replays `message` events.

Rules:
1. `replayCount` remains count of replayed `message` events only.
2. `stream_snapshot` is always current and not replay-window-limited.
3. If replay references unknown `sessionKey` on client:
- Client synthesizes a temporary local stream row (`displayName = sessionKey tail`) until next snapshot.
4. Synthetic local stream rows are read-only in UI (no rename/delete actions) until reconciled by snapshot.
5. No incremental stream history replay is required in Phase A.

## 5.7 Concurrency and conflict policy

No optimistic concurrency fields.

Server behavior:
1. Process requests in arrival order.
2. First committed mutation defines current state.
3. Later requests evaluate against current state and may fail (`404`/`409`) if preconditions no longer hold.
4. Stream create must run in a transaction that guarantees unique `(userId, orderIndex)`; on uniqueness conflict, recompute and retry once.

Examples:
- Delete then rename same stream: delete succeeds, rename returns `404`.
- Two creates: both may succeed (different session keys), append order follows commit order.

## 5.8 Provider file-by-file guidance

Provider repo paths are relative to OpenClaw/clawdbot root.

1. `src/clawline/server.ts`
- Add DB migration (`user_version=2`) creating `stream_sessions`, `stream_idempotency`, and `events` additive columns/indexes.
- Add backfill/seed logic from legacy session keys.
- Backfill legacy `events.sessionKey` by parsing stored message event payloads.
- Add REST handlers for `GET/POST/PATCH/DELETE /api/streams`.
- Add hard-delete transaction logic for stream deletion.
- Emit/broadcast `stream_snapshot`, `stream_created`, `stream_updated`, `stream_deleted`.
- Send `stream_snapshot` after auth and before message replay.

2. `src/clawline/domain.ts`
- Add provider types for `StreamSession`, REST DTOs, and new WS event payloads.

3. `src/clawline/routing.ts`
- Update stream label validation/parsing to accept dynamic `s_<suffix>` labels in addition to built-ins.
- Keep routing invariant: session keys remain canonical routing identifiers.

4. `src/clawline/config.ts`
- Add config defaults:
- `streams.maxStreamsPerUser`
- `streams.maxDisplayNameBytes`

5. `src/config/types.clawline.ts`
- Add typings for new `streams.*` config keys.

6. `src/clawline/service.ts`
- Plumb new config and stream metadata service hooks where needed.

7. `src/clawline/server.test.ts`
- Add tests for migration/backfill, stream CRUD REST API, WS stream broadcasts, replay ordering, and hard delete behavior.

8. `src/clawline/config.test.ts`
- Validate new stream config defaults and overrides.
- Confirm no built-in rename/delete config flags are present in Phase A.

## 6. iOS Client Changes

## 6.1 Data model changes

Replace fixed `ChatStream` enum assumptions with session-key-driven stream metadata.

New model:

```swift
struct StreamSession: Codable, Equatable, Identifiable {
    var id: String { sessionKey }
    let sessionKey: String
    var displayName: String
    let kind: String
    let orderIndex: Int
    let isBuiltIn: Bool
    let createdAt: Date
    let updatedAt: Date
}
```

Message model:
- Keep existing message payload structure.
- Ensure `sessionKey` is preserved as required identity field.
- No fork/merge metadata fields in Phase A.

Local storage:
- Add stream metadata cache file per user.
- Keep existing per-session message caches unchanged.

## 6.2 Service layer changes

`ChatServicing` additions:
- `fetchStreams()`
- `createStream(displayName:idempotencyKey:)`
- `renameStream(sessionKey:displayName:)`
- `deleteStream(sessionKey:idempotencyKey:)`

`ChatServiceEvent` additions:
- `.streamSnapshot([StreamSession])`
- `.streamCreated(StreamSession)`
- `.streamUpdated(StreamSession)`
- `.streamDeleted(sessionKey: String)`

`ProviderChatService` updates:
- Decode new `stream_*` WS events.
- Call `/api/streams` REST endpoints.
- Maintain existing send path using `message.sessionKey`.

## 6.3 ChatViewModel integration

State changes:
1. Replace `activeStream: ChatStream` with `activeSessionKey: String`.
2. Add `streamsBySessionKey: [String: StreamSession]`.
3. Add `orderedSessionKeys: [String]` sorted by `orderIndex`.
4. Keep `messagesBySessionKey` storage and retrieval.

Behavior:
1. On `.streamSnapshot`, replace local stream metadata atomically.
2. On `.streamCreated/.streamUpdated/.streamDeleted`, mutate metadata incrementally.
3. If active stream is deleted, switch to main stream key if available; else first stream.
4. Message routing/display always keyed by `message.sessionKey`.
5. On stream creation, update list immediately from `POST /api/streams` response and/or `stream_created`, deduping by `sessionKey`.

## 6.4 UI changes

### 6.4.1 Paging and dots

Replace fixed 2-page assumptions with dynamic pages:
- Page count = `orderedSessionKeys.count`.
- Active page = `activeSessionKey`.
- Dot tap opens stream manager sheet.

### 6.4.2 Stream manager sheet

Actions in Phase A:
- Add stream
- Rename stream
- Delete stream

No fork/merge controls in Phase A.

Built-in rows:
- Built-in streams are visible but rename/delete affordances are disabled.

### 6.4.3 Collection view/chat history behavior

No fork history UI in Phase A.

Collection view requirements:
1. Render messages filtered by current `activeSessionKey`.
2. Preserve scroll anchors per session key.
3. On stream deletion event for active stream, transition to fallback stream and clear visible items from deleted session.

## 6.5 iOS file-by-file guidance

Paths relative to `ios/Clawline/Clawline`.

1. `Models/Message.swift`
- Remove hard dependency on fixed `ChatStream` enum for routing decisions.
- Ensure message `sessionKey` remains first-class and persisted.

2. `Models/ProviderWireModels.swift`
- Add Codable payloads for `stream_snapshot`, `stream_created`, `stream_updated`, `stream_deleted`.

3. `Models/SessionRegistry.swift`
- Refactor to dynamic session-key registry instead of fixed two-stream assumptions.

4. `Protocols/ChatServicing.swift`
- Add stream CRUD API methods and stream event cases.

5. `Services/ProviderChatService.swift`
- Decode new WS stream events.
- Add REST calls for stream CRUD.
- Maintain replay ordering expectations (`auth_result` then `stream_snapshot` then replay).

6. `ViewModels/ChatViewModel.swift`
- Track stream metadata keyed by session key.
- Drive paging and active stream using `activeSessionKey`.
- Handle stream deletion fallback behavior.

7. `Views/Chat/ChatView.swift`
- Replace fixed `TabView` stream assumptions with dynamic pages.
- Add dots + stream manager sheet hooks.

8. `Views/Chat/ChatLayoutCoordinator.swift`
- Change keys from enum-based stream identity to session key.

9. `Views/Chat/MessageFlowCollectionView.swift`
- Consume `activeSessionKey` and preserve per-session layout/scroll state.

10. `Views/Chat/ChannelSwitcherView.swift`
- Replace/deprecate fixed two-stream switcher in favor of dynamic page/dots model.

11. New files to add
- `Models/StreamSession.swift`
- `Services/StreamAPIClient.swift`
- `Views/Chat/StreamPageDotsView.swift`
- `Views/Chat/StreamManagerSheet.swift`

12. Tests to update/add
- `ClawlineTests/ProviderServiceTests.swift`: decode and dispatch `stream_*` events.
- `ClawlineTests/ChatViewModelTests.swift`: snapshot replacement, incremental updates, delete fallback.
- `ClawlineTests/ChatLayoutCoordinatorTests.swift`: per-session-key UI state.
- `ClawlineUITests`: dynamic page dots + stream manager CRUD flows.

## 7. Wire Protocol Catalog (Phase A)

## 7.1 New S2C WS messages

- `stream_snapshot`
- `stream_created`
- `stream_updated`
- `stream_deleted`

## 7.2 New C2S WS messages

None.

## 7.3 New REST endpoints

- `GET /api/streams`
- `POST /api/streams`
- `PATCH /api/streams/:sessionKey`
- `DELETE /api/streams/:sessionKey`

## 7.4 JSON schema snippets

### `StreamSession`

```json
{
  "type": "object",
  "required": [
    "sessionKey",
    "displayName",
    "kind",
    "orderIndex",
    "isBuiltIn",
    "createdAt",
    "updatedAt"
  ],
  "properties": {
    "sessionKey": { "type": "string", "minLength": 1 },
    "displayName": { "type": "string", "minLength": 1, "maxLength": 120 },
    "kind": { "enum": ["main", "dm", "global_dm", "custom"] },
    "orderIndex": { "type": "integer", "minimum": 0 },
    "isBuiltIn": { "type": "boolean" },
    "createdAt": { "type": "integer" },
    "updatedAt": { "type": "integer" }
  },
  "additionalProperties": false
}
```

### `stream_snapshot`

```json
{
  "type": "object",
  "required": ["type", "streams"],
  "properties": {
    "type": { "const": "stream_snapshot" },
    "streams": {
      "type": "array",
      "items": { "$ref": "#/definitions/StreamSession" }
    }
  },
  "additionalProperties": false
}
```

### `stream_created` / `stream_updated`

```json
{
  "type": "object",
  "required": ["type", "stream"],
  "properties": {
    "type": { "enum": ["stream_created", "stream_updated"] },
    "stream": { "$ref": "#/definitions/StreamSession" }
  },
  "additionalProperties": false
}
```

### `stream_deleted`

```json
{
  "type": "object",
  "required": ["type", "sessionKey"],
  "properties": {
    "type": { "const": "stream_deleted" },
    "sessionKey": { "type": "string", "minLength": 1 }
  },
  "additionalProperties": false
}
```

## 8. Edge Cases (Phase A)

1. Unknown stream on replay:
- Client synthesizes temporary local stream entry from `sessionKey` and reconciles on next snapshot.

2. Concurrent delete/rename:
- First committed operation applies; later operation fails by current-state validation.

3. Delete active stream:
- Client moves to main stream immediately after `stream_deleted` event.

4. Built-in stream delete/rename attempts:
- Reject with `409` in Phase A.

5. Stream limit reached:
- `POST /api/streams` returns `409 stream_limit_reached`.

6. Duplicate display names:
- Allowed in Phase A; uniqueness is by session key, not name.

7. Disconnected client catch-up:
- On reconnect, snapshot sent first; then message replay.

8. Automatic deletion/expiration:
- Not allowed in Phase A. Stream deletion only occurs from explicit client delete action.

9. Pending outbound message to deleted stream:
- Provider rejects send with `404 stream_not_found` (or equivalent existing message-send error envelope).
- Client surfaces failure and does not auto-recreate the deleted stream.

10. User action attribution on delete:
- Server must only accept delete from authenticated client REST request path.
- Internal timers/jobs must not call delete handlers.

11. Last stream deletion request:
- Reject with `409 last_stream_delete_forbidden`.
- Provider guarantees at least one stream remains addressable for the user.

## 9. Acceptance Checklist (Phase A)

1. Provider persists stream metadata keyed by session key.
2. Provider serves stream CRUD via REST and broadcasts corresponding WS events.
3. Replay order is `auth_result -> stream_snapshot -> message replay`.
4. iOS shows dynamic stream pages and dots.
5. iOS stream manager supports add/rename/delete.
6. Deleting a stream removes metadata and all messages for that session.
7. No fork/merge implementation exists in Phase A code paths.
8. No server-initiated stream deletion paths exist (no cleanup, no auto-archive, no expiration).
9. Built-in streams are immutable in Phase A (no rename/delete).

## Appendix A: Future Phases (Non-Normative)

Not in Phase A implementation.

1. Fork behavior (future):
- Fork starts with a single origin bubble containing summary of parent conversation.
- Tapping origin bubble navigates to fork point in parent stream.
- No message copying.
- No virtual inherited message display.

2. Merge behavior (future):
- To be specified in a later phase after fork UX ships.

3. Schema foresight:
- Future migrations may add fork/merge relation tables or metadata columns.
- Those structures are intentionally not specified for Phase A implementation.
