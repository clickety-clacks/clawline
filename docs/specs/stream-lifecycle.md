# Stream Lifecycle Spec (Server-Side)

Status: Draft (implementation-grade, v2)
Last updated: 2026-02-24
Related: clickety-clacks/clawline#116, #115
Depends on: `specs/multi-stream.md`, `provider-architecture.md`, `specs/clawline-invariants.md`

Phase note:
- Phase A = existing multi-stream CRUD baseline in `multi-stream.md`.
- Phase B = fork/merge behavior defined in this spec.

## 1. Goal

Enable CLU to manage stream lifecycle from the server side for a user without requiring the iOS client bearer token, covering:
1. Create/rename/delete stream via provider API.
2. Auth for server-side stream management.
3. Fork stream flow (Phase B): branch a conversation into a new stream with carried context.
4. Merge stream flow (Phase B): converge two streams after a topic resolves.

## 2. Non-Goals

1. Replacing existing client-side `/api/streams` user-auth endpoints.
2. Redesigning session key format (session keys remain canonical IDs).
3. UI specification for iOS fork/merge controls.
4. Full CRDT/three-way semantic merge of message history.
5. Automatic background stream deletion/cleanup.

## 3. Current State Summary

1. `channel-create`, `channel-edit`, and `channel-delete` exist in provider `actions.ts`.
2. Those actions call `callStreamApi()` with bearer auth available only to the iOS app.
3. CLU can read stream rows from SQLite (`stream_sessions`) but cannot mutate streams.

## 4. Invariants (Binding)

1. Session keys remain the only stream routing identifiers.
2. Built-in stream protections from Phase A remain in force.
3. Stream lifecycle mutations are explicit API actions; no autonomous expiry/deletion jobs are introduced.
4. Fork and merge emit explicit stream-topology events, same as create/rename/delete.

## 5. Auth Model (Recommended)

## 5.1 Model

Use a single provider-side secret header for server-side calls:
- Header: `X-CLU-Secret: <secret>`
- Secret config key: `clawline.server.cluSecret`
- Secret source: provider config/runtime env only (never sent to iOS client)

This secret allows CLU to bypass the iOS bearer-token requirement for server lifecycle endpoints.

## 5.2 Secret requirements

1. Minimum entropy: 128 bits.
2. Minimum length: 22 chars base64url (or equivalent entropy string).
3. Secret must not be checked into source control.
4. Rotation: provider supports rotation via restart or config reload.

## 5.3 Validation rules

1. Missing/invalid `X-CLU-Secret` returns `403 clu_secret_invalid`.
2. Valid secret proceeds to normal stream guardrails (built-in protection, last-stream protection, etc.).
3. Every endpoint path includes `:userId`; provider must reject unknown user with `404 user_not_found`.

## 5.4 Transport expectation

1. Default deployment is local/private network per provider architecture.
2. TLS termination remains operator-managed and out of scope for this spec.

## 6. API Surface (Provider)

All endpoints below are provider endpoints and require `X-CLU-Secret`.

## 6.1 Create stream

`POST /api/server/users/:userId/streams`

Request:
```json
{
  "displayName": "Loupe",
  "idempotencyKey": "req_123"
}
```

Response `201`: stream payload matches Phase A stream schema.

Errors:
1. `404 user_not_found`
2. `400 invalid_display_name`
3. `409 stream_limit_reached`

## 6.2 Rename stream

`PATCH /api/server/users/:userId/streams/:sessionKey`

Request:
```json
{
  "displayName": "Deploy Log"
}
```

Response `200`: updated stream payload.

Errors:
1. `404 user_not_found`
2. `404 stream_not_found`
3. `409 built_in_stream_rename_forbidden`

## 6.3 Delete stream

`DELETE /api/server/users/:userId/streams/:sessionKey`

Header:
- `X-Idempotency-Key: req_456`

Response `200`:
```json
{
  "deletedSessionKey": "agent:main:clawline:flynn:s_8fa12c44"
}
```

Errors:
1. `404 user_not_found`
2. `404 stream_not_found`
3. `409 built_in_stream_delete_forbidden`
4. `409 last_stream_delete_forbidden`

## 6.4 Idempotency contract

Applies to create/delete/fork/merge.

1. Scope key by `(userId, endpoint, idempotencyKey)`.
2. First successful request stores canonical response JSON.
3. Exact replay returns stored response with original status.
4. Same key with different normalized request body returns `409 idempotency_key_reused`.
5. Retention: 7 days (reuse existing `stream_idempotency` table and cleanup policy).

## 7. Fork (Phase B)

## 7.1 Endpoint

`POST /api/server/users/:userId/streams/:sessionKey/fork`

Request:
```json
{
  "displayName": "Parser Refactor",
  "seed": {
    "summary": "This branch tracks parser refactor decisions and follow-up tasks.",
    "sourceMessageIds": ["s_101", "s_102", "s_109"],
    "quotedSnippets": [
      {
        "messageId": "s_102",
        "text": "This conversation deserves its own stream."
      }
    ]
  },
  "idempotencyKey": "req_789"
}
```

Response `201`:
```json
{
  "forkedFrom": "agent:main:clawline:flynn:main",
  "stream": {
    "sessionKey": "agent:main:clawline:flynn:s_a1b2c3d4",
    "displayName": "Parser Refactor",
    "kind": "custom",
    "orderIndex": 5,
    "isBuiltIn": false,
    "createdAt": 1771905600000,
    "updatedAt": 1771905600000
  },
  "seedMessageId": "s_5001"
}
```

Errors:
1. `404 user_not_found`
2. `404 stream_not_found`
3. `422 fork_source_message_not_found`
4. `422 fork_quote_message_mismatch`

## 7.2 Fork semantics

1. Provider creates child stream and appends at end (`orderIndex = max + 1`).
2. Provider validates every `sourceMessageId` exists in parent stream.
3. Provider validates every `quotedSnippets[].messageId` is present in `sourceMessageIds`.
4. Provider writes one seed message to child stream containing summary and references.
5. Provider writes one parent note: `Forked to <displayName>` with child `sessionKey`.
6. No historical message copy.
7. Provider emits:
- `stream_created`
- `stream_forked` with `{ parentSessionKey, childSessionKey, seedMessageId }`

## 8. Merge (Phase B)

## 8.1 Endpoint

`POST /api/server/users/:userId/streams/merge`

Request:
```json
{
  "sourceSessionKey": "agent:main:clawline:flynn:s_a1b2c3d4",
  "targetSessionKey": "agent:main:clawline:flynn:main",
  "summary": "Parser refactor complete. Decision: keep incremental tokenizer path.",
  "closeSource": true,
  "idempotencyKey": "req_999"
}
```

Response `200`:
```json
{
  "merged": true,
  "mergeMessageId": "s_6001",
  "sourceSessionKey": "agent:main:clawline:flynn:s_a1b2c3d4",
  "targetSessionKey": "agent:main:clawline:flynn:main",
  "sourceClosed": true
}
```

Errors:
1. `404 user_not_found`
2. `404 stream_not_found`
3. `422 merge_source_target_same`
4. `409 built_in_stream_close_forbidden`

## 8.2 Merge semantics

1. Provider writes one merge summary message into target stream.
2. Provider always writes one source-stream note that references target stream.
3. If `closeSource=true`, provider marks source stream `status=closed` (read-only); merge does not hard-delete source.
4. Built-in streams may be merge targets.
5. Built-in streams may not be closed by merge (`closeSource=true` forbidden when source is built-in).
6. Provider emits:
- `stream_merged` with `{ sourceSessionKey, targetSessionKey, mergeMessageId, sourceClosed }`
- `stream_updated` if source stream status changes.

## 9. Data Model Additions (Provider DB)

## 9.1 `stream_sessions` additive fields

1. `createdBy TEXT NOT NULL DEFAULT 'user'` (`user | clu`)
2. `status TEXT NOT NULL DEFAULT 'active'` (`active | closed`)

Migration note:
- Existing rows remain `createdBy='user'` by default (historical iOS-created/custom streams).

`closed` semantics:
1. Closed streams remain visible in `GET /api/streams` and WS snapshots.
2. Closed streams are read-only for new message sends.
3. Closed streams are still deletable through explicit delete endpoint (unless built-in protections apply).

## 9.2 New table `stream_lineage`

```sql
CREATE TABLE IF NOT EXISTS stream_lineage (
  userId TEXT NOT NULL,
  relationId TEXT NOT NULL,
  relationType TEXT NOT NULL,    -- fork | merge
  sourceSessionKey TEXT NOT NULL,
  targetSessionKey TEXT NOT NULL,
  contextJson TEXT,
  createdAt INTEGER NOT NULL,
  PRIMARY KEY (userId, relationId)
);
```

Persistence rule:
- Lineage writes are idempotent with request idempotency (same replay must not duplicate row or fail).

Purpose:
1. Track fork/merge lineage.
2. Support future parent/child and merge navigation.

## 10. WebSocket Event Additions

New S2C events:
1. `stream_forked`
2. `stream_merged`

Payloads:

```json
{
  "type": "stream_forked",
  "parentSessionKey": "agent:main:clawline:flynn:main",
  "childSessionKey": "agent:main:clawline:flynn:s_a1b2c3d4",
  "seedMessageId": "s_5001"
}
```

```json
{
  "type": "stream_merged",
  "sourceSessionKey": "agent:main:clawline:flynn:s_a1b2c3d4",
  "targetSessionKey": "agent:main:clawline:flynn:main",
  "mergeMessageId": "s_6001",
  "sourceClosed": true
}
```

Delivery rule:
1. Broadcast to all active authenticated sockets for that `userId`.
2. Offline clients reconcile via normal reconnect snapshot/replay path.

## 11. OpenClaw Core vs Clawline Provider Boundary

## 11.1 Decision

This is **100% Clawline provider work** for #116.

No OpenClaw core changes are required.

## 11.2 Why no core change is needed

1. Stream lifecycle behavior is Clawline-domain logic already implemented in provider stream actions.
2. `X-CLU-Secret` validation is provider-specific endpoint policy, not shared core protocol behavior.
3. Fork/merge semantics are Clawline stream-topology features within provider storage/events.

## 11.3 What would force a core change later

Core change is only needed if one of these becomes a requirement:
1. A provider-agnostic server-auth mechanism shared by multiple plugins/providers.
2. Core-level authorization middleware that must own secret validation.
3. Core protocol additions that all clients/providers must understand.

None of these are required for this issue.

## 12. Security and Guardrails

1. `X-CLU-Secret` must be configured out-of-band and not exposed to clients.
2. Provider logs all server-side lifecycle mutations with `actor=clu`.
3. Rate limits (keyed by `userId` path parameter):
- create: 20/min/user
- rename: 30/min/user
- delete: 10/min/user
- fork: 10/min/user
- merge: 10/min/user
4. All mutating endpoints require idempotency keys.

## 13. Acceptance Checks

1. CLU can create, rename, delete custom streams via provider server-side API using `X-CLU-Secret` only.
2. Invalid/missing secret is rejected with `403 clu_secret_invalid`.
3. Unknown `userId` is rejected with `404 user_not_found`.
4. Built-in and last-stream protections still apply to server-side calls.
5. Fork validates source references, creates child stream, writes child seed context, and parent reference note.
6. Merge validates source/target constraints, writes target summary, writes source note, and optionally closes source.
7. WS broadcasts lifecycle changes to all authenticated user clients and reconnect path reconciles state.
8. Idempotency replay returns original result for create/delete/fork/merge.
9. Implementation lands fully in Clawline provider; no OpenClaw core changes.

## 14. Implementation Handoff

1. Add provider endpoints near existing `/api/streams` handlers and route through shared stream mutation code paths.
2. Add provider config key `clawline.server.cluSecret` with validation on startup.
3. Add tests for secret validation (`403`), unknown user (`404`), idempotency replay, fork/merge validation, and closed-stream behavior.
4. Keep `sessionKey` as canonical key in all payloads, routes, and DB records.

## 15. Open Questions

1. Should source stream close state after merge be reversible (`reopen`) in Phase B, or deferred?
2. Should fork seed payload enforce a strict max quote count/size beyond existing message limits?
