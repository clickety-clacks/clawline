# Clawline Provider Architecture (clawd.me plugin)

## Purpose

Define how the Clawline provider runs as a clawd.me plugin to serve mobile clients (Clawline) with authenticated chat, streaming responses, and large media/file transfer.

## Normative scope

This document separates binding architectural/technology choices from guidance.

- **Normative requirements** are binding. They use MUST/SHOULD and are the committed architecture.
- Everything else is guidance unless explicitly marked MUST/SHOULD or referenced by `docs/provider-testing.md`. Normative requirements also appear inline where needed.

## Implementation prerequisites

- This document is not standalone; implementers MUST use `docs/architecture.md` for the protocol schemas and error codes.
- The provider integrates with clawd.me internals; the authoritative API surface is the clawd.me source in this repository. If those APIs change, update this document and the provider together.
- Protocol schema pointers (in `docs/architecture.md`): TypeScript-style `ClientMessage`/`ServerMessage` definitions, attachment schema, error codes, and HTTP endpoint payloads.
- Inline schemas in this document are copied from `docs/architecture.md` for convenience only; implementers MUST rely on `docs/architecture.md` for canonical schemas. If any schema text conflicts between documents, `docs/architecture.md` is authoritative.
- Adapter contract precedence: the clawd core adapter interface is authoritative; the inline TypeScript interface here is a convenience mirror and must be kept in sync.
- Schema sync discipline: any change to wire payloads or error codes MUST update both this document and `docs/architecture.md` in the same commit. Our doc review checklist and `pnpm lint:docs` (runs the schema diff script under `docs/scripts/verify-schemas.mjs`) enforce this—do not merge if either doc would drift.

### Protocol schema summary (see `docs/architecture.md` for canonical definitions)

```ts
type ClientMessage =
  | { type: "pair_request"; protocolVersion: 1; deviceId: string; claimedName?: string; deviceInfo: DeviceInfo }
  | { type: "pair_decision"; deviceId: string; userId?: string; approve: boolean }
  | { type: "auth"; protocolVersion: 1; token: string; deviceId: string; lastMessageId?: string | null }
  | { type: "message"; id: string; content: string; attachments?: Attachment[] }
  | { type: "typing"; active: boolean };

type ServerMessage =
  | { type: "pair_result"; success: boolean; token?: string; userId?: string; reason?: string }
  | { type: "auth_result"; success: boolean; userId?: string; sessionId?: string; replayCount?: number; replayTruncated?: boolean; historyReset?: boolean; reason?: string }
  | { type: "pair_approval_request"; deviceId: string; claimedName?: string; deviceInfo: DeviceInfo }
  | { type: "ack"; id: string }
  | { type: "message"; id: string; role: "user" | "assistant"; content: string; timestamp: number; streaming: boolean; attachments?: Attachment[]; deviceId?: string }
  | { type: "typing"; role?: "assistant"; active: boolean }
  | { type: "error"; code: ErrorCode; message: string; messageId?: string };
```
`docs/architecture.md` is canonical for the exact fields/validation rules; the snippet above is a convenience reminder.

## Normative requirements

- The provider MUST run as a clawd.me plugin (loaded from `.clawd/plugins/*.js`).
- It MUST be a pass-through server for mobile clients, not a TUI feature.
- Transport MUST be WebSocket control + HTTP media on a single server/port.
- v1 MUST NOT terminate TLS; operators are responsible for transport security if needed.
- The provider MUST bind to localhost by default; non-localhost bind MUST require `allowInsecurePublic: true`.
- If `allowInsecurePublic` is false and a non-localhost bind address is requested, startup MUST fail with `server_error` (`bind_not_allowed`) after logging a clear error; do not silently downgrade to localhost.
- Server message envelopes MUST remain presentation-agnostic. Beyond the canonical `ServerMessage` fields (`type: "message"` and `deviceId` on user echoes), providers may only emit `id`, `role`, `timestamp`, `streaming`, UTF-8 `content`, and `attachments[]`. Do not add UI-specific `parts`, styling hints, or size classes; clients derive presentation from these canonical fields.
- Local disk storage MUST be used for large media/files; inline attachments MUST be kept small.
- The provider MUST support multiple `deviceId`s per `userId`. Conversations, uploads, and responses MUST fan out to every online device tied to that account, and replay MUST use shared per-`userId` history.
- v1 supports a single conversation per `userId` (no multi-threading or room semantics).
- The provider MUST maintain a per-`userId` monotonic event log; every replayable event (user message echo, assistant stream snapshot/final) receives a server-generated `s_...` identifier. Typing indicators are transient and not persisted or replayed.
- Streaming partials are delivered only to the originating `deviceId`; other devices for the same `userId` receive only the final assistant message.
- Duplicate detection MUST key on `(deviceId, id)` so simultaneous sends from sibling devices cannot collide.
- The provider MUST broadcast user messages back to every device for the same `userId` (including the sender) before dispatching to the LLM adapter, ensuring all devices share the same ordered event stream.
- The provider MUST serve `GET /version` for protocol discovery (response schema in `docs/architecture.md`).
- v1 assumes a local POSIX filesystem; NFS/shared volumes and Windows are not supported without alternative locking.
- WebSocket keepalives MUST ping every 30s and close after 90s without pong.
- `maxMessageBytes` MUST be capped at 64KB (UTF-8 `content`).

### Reference map (single source of truth)

- Wire protocol schemas, message envelopes, error codes, and HTTP payloads: **`docs/architecture.md` is canonical**. This document only elaborates behavior around those schemas.
- Configuration keys and default JSON structure: **`provider/README.md` is canonical**. This document references key defaults but does not redefine them.
- Behavioral/architectural rules (pairing/auth flows, storage model, adapter contract, operational guidance): **this document is canonical**. If behavior overlaps configuration or schema (e.g., payload limits), defer to the schema for on-wire formats and to this doc for runtime enforcement.
- If a conflict is discovered, update the documents to realign; never guess. When in doubt, prioritize the mapping above in the order listed.

## Explicitly Not MVP (v1)

These items were considered and explicitly deferred as non‑MVP:
- Automatic pruning/quotas or tombstones.
- Automatic database recovery/migrations beyond fail‑fast on corruption.
- Stream resume across reconnects/restarts.
- Push notifications.
- TLS termination or built‑in reverse proxying.
- Multi‑connection grace windows (new connection replaces old immediately).
- v1 runs as a single provider instance (no horizontal scaling). Multi-process coordination is out of scope.
- v1 cannot cancel in-flight adapter calls; if a stream is cancelled due to socket close, the adapter may continue running and consume resources (output is discarded).

This document is aligned with:
- `docs/architecture.md` (protocol + pairing flow)
- `provider/README.md` (provider configuration shape)
- `docs/ios-architecture.md` (iOS client expectations)
- `docs/ios-provider-connection.md` (iOS transport details)
- `docs/provider-testing.md` (required test coverage)

## High-level topology

```
Clawline iOS
  |  WebSocket (control plane) + HTTP (media plane)
  v
Clawd.me process
  |-- Clawline Provider plugin (this doc)
  |   |-- WebSocket server
  |   |-- Auth + pairing
  |   |-- Session + routing
  |   |-- Media transfer
  |   `-- Notification hooks
  `-- LLM adapter (Claude Code by default)
      |
      v
LLM API / CLI
```

## Plugin integration with clawd.me

Clawd loads plugins from `.clawd/plugins/*.js` via `src/plugin-system/loader.js`. A plugin must export a default object with:

- `name: string`
- `hooks: { [hookName]: async (context) => context }`

Key hook points (from clawd.me source):
- `pre:plan`, `post:plan`, `pre:exec`, `post:exec`, `pre:eval`, `post:eval`, `pre:complete`, `post:complete`
- `mcp:started` (receives `{ url, port, protocol }`)

Provider plugin lifecycle (recommended):
1. **Initialize at load**: configure dependencies, but do not bind ports yet.
2. **Start server** immediately after plugin load (post-config). If `mcp:started` exists in the host, you may delay until that hook fires.
3. **Shutdown** on process exit signals (`SIGINT`, `SIGTERM`): stop accepting new connections, close all sockets immediately, and allow in-flight adapter calls to finish (their output is discarded).

Why `mcp:started` is useful:
- It provides a reliable early lifecycle point.
- It can optionally expose MCP server info to provider features (admin tooling, diagnostics), without coupling to the core execution flow.

### Hook context contract (normative)

Plugin hooks receive a `context` object shaped as:
```ts
type PluginContext = {
  config: any;
  logger: { info(...); warn(...); error(...); };
  adapterLoader: { load(name?: string): Promise<Adapter> };
  adapter?: Adapter; // optional pre-instantiated adapter
};
```
`adapterLoader.load(name)` resolves a clawd adapter by name (default when omitted). If `context.adapter` exists, the provider MUST prefer it over calling `load`. Both surfaces are stable; update this section if clawd core changes the hook contract.

Positioning:
- The Clawline provider should remain a plugin even if it ships with clawd core; this keeps the extension model consistent.
- This is not a TUI feature. It is a pass-through server for iOS/Android clients that bridges WebSocket traffic into the clawd adapter.

## Core components

### 1) WebSocket front door (control plane)
- Listens on configured port (from provider config) and serves WebSocket at `/ws`.
- All client messages are JSON with a `type` field (see `docs/architecture.md`).
- Responsible for:
  - Authentication handshake
  - Session routing
  - Streaming response dispatch
  - Heartbeats / keep-alives (WS ping every 30s, close after 90s without pong)
  - Validate `protocolVersion: 1` in `pair_request` and `auth` (reject missing/unknown with `invalid_message`)
- If `protocolVersion > 1` on `pair_request` or `auth`, return `invalid_message` and close the connection (no downgrade in v1)
  - Reject any `message` or `typing` before auth (`auth_failed`, then close)
  - Serve `GET /version` for protocol discovery (response schema per `docs/architecture.md`, e.g. `{ "protocolVersion": 1 }`)
  - Bind to localhost by default; require `allowInsecurePublic: true` to bind to non-localhost

Implementation note:
- Prefer a single HTTP server that handles both WebSocket upgrades (e.g. `/ws`) and HTTP upload/download endpoints (e.g. `/upload`, `/download/:id`) on the same port. This keeps auth/session context unified and avoids running a second service for v1.
- Network security (TLS/VPN/firewall) is out of scope for the provider. Operators are responsible for securing transport if needed.

### 2) Pairing + Auth manager
Based on `docs/architecture.md`:
- First-time device pairing: `pair_request` -> admin approval -> `pair_result` (JWT + userId)
- Subsequent connections: `auth` with stored JWT
- JWT includes `sub`, `deviceId`, `isAdmin`, `iat`, `exp` (`sub` MUST equal the `userId`)
- Revocation is list-based (no expiry in v1)
- Provider secret (`jwtSigningKey`) should be generated on first run if not provided, stored in the provider state directory (default `~/.clawd/clawline/`), and reused on restart (rotation is manual in v1).
- Rotating the signing key invalidates all existing JWTs; devices must re-pair. On rotation, the provider MUST terminate all active sessions immediately.
- Denylist is persisted in the provider state directory as JSON and checked on every `auth`.
- Watch the denylist for changes (file watch or 5s poll) and close any active sessions for revoked `deviceId`s.
- Allowlist entries are keyed by `deviceId`. `claimedName` is a label only and may be omitted; when provided it MUST be <=64 UTF-8 bytes and stored verbatim. The provider MUST sanitize `claimedName` (e.g., strip control characters) before logging **and** before persisting to `allowlist.json`, and client/admin UIs MUST sanitize before display. During approval the admin MUST explicitly choose an existing `userId` or create a new UUIDv4 `userId` for the device to join. Approved allowlist entries are persisted; pending requests are in-memory only.
- `deviceInfo.platform`, `.model`, `.osVersion`, and `.appVersion` MUST each be <=64 UTF-8 bytes; reject requests exceeding the limit with `invalid_message`.
- JSON/SQLite split note: allowlist/denylist live in JSON; messages/events live in SQLite. If a crash occurs after allowlist update but before any SQLite writes, the device can still authenticate and will see an empty history. This is acceptable in v1; no special recovery is required. Conversely, if SQLite commits but the allowlist write fails, the device history is preserved but the device cannot reconnect until an operator reapplies the allowlist. v2 may unify these stores, but for v1 the split is a conscious trade-off to keep pairing edits human-editable.

Responsibilities:
- Validate tokens and device identity
- Manage active sessions per user/device
- If a new session opens for the same device (normal takeover), validate its `auth`. On success, the new session becomes primary immediately; send `error` `session_replaced` to the old socket and close it. If the new `auth` fails, the old session remains active.
- Session takeover semantics:
  - After `session_replaced` is sent, the old socket MUST NOT accept new `message`s. "Accepted" means the message+event transaction committed (i.e., an entry exists in `messages`); anything still in flight but not committed must be rejected on the old socket.
- Concurrent auths for the same `deviceId` MUST be serialized. Implement this with a per-`deviceId` auth mutex: queue verifications, allow only the head of the queue to run JWT validation, and release the queue when that verifier resolves. Pseudocode:
  1. Push `{socket, resolve}` into the per-device queue.
  2. If entry is not at position 0, await until all earlier entries finish (success or failure) without running validation.
  3. Head entry runs validation + replay. On success it becomes the *current candidate*.
  4. After sending `auth_result`, mark this socket as the current owner (it may start processing client traffic). When the next queue entry succeeds, it will send `session_replaced` to this socket.
  5. Pop the head and wake the next entry.
Ownership is strictly by queue order: whichever entry reaches successful validation most recently (after the entries ahead of it complete) wins. Because validation is sequential, a “newer” entry cannot finish before earlier ones—it simply wins because it ran last. Earlier successes always notify the client (`auth_result`) before they learn they were superseded. There is never a wait for the “tail” of the queue—each connection only observes whether a later auth succeeded, not *which* later auth it was.
- Persist allowlist entries on approval and expire pending requests with a TTL (`pairing.pendingTtlSeconds`, default 5 minutes). Expired requests return `pair_result` with `reason: pair_timeout`.
- Pending requests are in-memory only and include `{ deviceId, claimedName?, deviceInfo, createdAt, socketRef }` for delivery of `pair_result` and admin approval routing.
- If a new `pair_request` arrives for a `deviceId` with an existing pending request, treat it as a reconnect: keep the original pending entry and TTL (do not reset), but update `socketRef` to the latest connection so the eventual `pair_result` is delivered to the active socket.
- If no admin is online, pending requests remain queued until an admin connects or the TTL expires. When an admin successfully authenticates (after replay), the provider MUST immediately emit every still-valid pending request to that socket before delivering normal chat traffic so approvals are never missed because of a disconnect.
- Rate limit `pair_request` (5/min per deviceId) and cap pending requests (`maxPendingRequests`, default 100).
- While a request is pending, any attempt to `auth` MUST return `auth_result { success:false, reason:\"device_not_approved\" }` and close the socket; the client should resume pairing UI.
- Store admin status on allowlist entries and include `isAdmin` in JWT claims. Only admins can send `pair_decision`.
- Non-admin `pair_decision` attempts return `error` `invalid_message` without closing the connection.
- Bind tokens to `deviceId`: the provider MUST reject `auth` if the presented JWT’s `deviceId` claim differs from the `deviceId` sent in the payload.
- Auth validation order: verify JWT signature and expiry before checking `deviceId` binding to avoid leaking valid device identifiers.
- Admin promotion is out-of-band in v1 (edit allowlist / CLI wrapper); only the first-admin bootstrap device is admin by default.
- Maintain a denylist for revoked `deviceId`s; pair requests from denylisted devices return `pair_rejected`.
- Rate limit auth attempts to 5 per minute per `deviceId` (config: `auth.maxAttemptsPerMinute`).
- WebSocket auth validation order (v1): 1) verify JWT signature and `exp`, 2) ensure payload `deviceId` matches JWT `deviceId`, 3) ensure the device is not denylisted, 4) proceed to session takeover logic (queue/mutex described below). All failures return `auth_result` `success: false` with the relevant `reason`.

Pairing decision (v1):
- Admin approval happens in-app (no Telegram/Slack integration).
- Admin UX and request handling are described in `docs/ios-provider-connection.md` (pending approvals view, userId creation flow).
- Bootstrap: if there are no admins yet (no allowlist entries with `isAdmin: true`), the first `pair_request` is auto-approved and marked as an admin device.
- "Admin exists" means an allowlist entry with `isAdmin: true` regardless of `tokenDelivered`/`lastSeenAt`. Even if the admin has not received its token yet, subsequent devices must await explicit approval.
- During bootstrap, the provider MUST mint a new UUIDv4 `userId` for the first-admin device (no admin selection is possible).
- Provider must enforce an atomic first-admin claim so only one device can win. `userId` values use the canonical `user_<UUIDv4>` format (e.g., `user_4f1d...`); mint new IDs in that shape.
- When `approve: true`, `pair_decision` MUST include the chosen `userId` (existing or newly minted) so the provider can bind the device to the correct account.
- When `approve: false`, `userId` MUST be omitted.
- If `approve` is missing or not a boolean, respond with `error` `invalid_message` and keep the request pending until it expires or a valid decision arrives.
- Admin clients are responsible for minting a new UUIDv4 `userId` when creating a new account.
- If `approve: true` is missing `userId`, respond with `error` `invalid_message` and keep the request pending until it expires or a valid decision arrives. The error `message` MUST include the `deviceId` so admins can identify the failed request.
- If multiple admins send `pair_decision` for the same pending request, the first decision wins; subsequent decisions return `error` `invalid_message` without closing the admin connection.
- Implementation guidance: use an in-process mutex per allowlist mutation and also open `${statePath}/allowlist.lock` with `O_CREAT` + exclusive `flock` (so the lock auto-releases on process death) before reading or writing `allowlist.json` (for any allowlist mutation, not only bootstrap). This prevents concurrent mutations in the same Node.js process and protects against multi-process access. Use non-blocking lock attempts every 500ms for up to 10 seconds; if the lock cannot be acquired, return `server_error` and keep the request pending until its TTL expires. If TTL expires first, return `pair_timeout`.
- Concurrent requests that lose the first-admin race become normal pending requests (non-admin).
- After bootstrap, all new `pair_approval_request` events are pushed to active admin devices over the WebSocket for approve/deny. Immediately after the first-admin device is established, the provider MUST emit `pair_approval_request` for any pending requests still within TTL so that bootstrap losers can be approved without waiting for a retry.
- Keep pending requests with a TTL and persist allowlist entries on approval.
- Record `tokenDelivered` for the first-admin entry; flip it to true only after the `pair_result` WebSocket write succeeds (write callback resolves, buffer accepted) while the socket remains open. No client ack is required. If the provider restarts and finds `tokenDelivered: false`, it MUST allow a one-time `pair_request` from that same `deviceId` to re-issue the token (same `userId`/`isAdmin`). This is the only permitted re-pairing without operator intervention.
- If the provider successfully sends `pair_result` but the client never receives it (e.g., connection drops after send), the device may be locked out once `tokenDelivered: true` is persisted. Recovery is manual in v1 unless the re-issue rule below applies. The automatic re-issue path only applies when `tokenDelivered: false` or when `lastSeenAt` is still null.
- If a restart occurs after `pair_result` is sent but before `tokenDelivered` is persisted, the provider may re-issue a fresh JWT for the same `deviceId`. Multiple valid tokens for the same device are acceptable in v1; the provider accepts any valid token until revoked.
- Re-issue rules (authoritative): see truth table below.
- On successful re-issue delivery, set `tokenDelivered=true`. If the send fails, leave `tokenDelivered=false` so the device can retry (bounded by `pair_request` rate limits).
- On any successful `auth`, immediately set `tokenDelivered=true` and `lastSeenAt=now` in the allowlist. This prevents further automatic re-issue for that device.
- Re-issue truth table (v1). The `tokenDelivered=true` + `lastSeenAt=null` row is a crash-only state (pair_result delivered, provider restarted before first auth); it is the only time re-issue is allowed after `tokenDelivered=true`, and only for `auth.reissueGraceSeconds` (default 600) after `createdAt` (same limit the tests enforce):
  | tokenDelivered | lastSeenAt | Allow re-issue |
  | --- | --- | --- |
  | false | any | YES |
| true | null | YES (only if `now - createdAt <= auth.reissueGraceSeconds`) |
  | true | non-null | NO |
- Manual recovery should preserve the account: remove the allowlist entry for the device and approve it again with the same `userId` to keep history intact.
- Re-pairing a device with an existing allowlist entry is otherwise blocked; operators must remove the allowlist entry (or revoke) to allow re-pairing.
- Admin devices receive `pair_approval_request` events on their primary authenticated WebSocket (no secondary socket).
- `pair_approval_request` and `pair_decision` schemas are defined in `docs/architecture.md`. Admin denial results in `pair_result` with `reason: pair_denied`.

Auth decision (v1):
- Tokens expire automatically after `tokenTtlSeconds` (default 31,536,000 seconds / 1 year). Operators may set `tokenTtlSeconds: null` to disable expiry; in that case omit the `exp` claim. Revocation remains manual.

### 3) Session + routing layer
- Maintains in-memory map: `sessionId -> { userId, deviceId, socket, state }` (per device)
- Maintains `userSessions: Map<userId, Set<sessionId>>` for fan-out.
- Tracks conversation state per device:
  - last processed server event id (`lastMessageId`, always an `s_...` assigned by the provider)
  - streaming state
  - active upload/download ids
  - fan-out backlog for sibling devices that share the same `userId` (ephemeral; replay handles missed events after restart)
- Queues additional user messages FIFO while a stream is active for that `userId`; the queue is in-memory only and capped by `maxQueuedMessages` (default 20) per user. If full, reject with `rate_limited` for that device.
- Adapter dispatch is serialized per `userId` (single conversation). Messages from any device are enqueued until the active stream completes.
- Routes:
  - inbound messages to LLM adapter
  - outbound server events (user echoes + assistant output) to each client socket
- Persists a per-user event log so reconnects can replay missed messages (server is source of truth) across every device tied to that `userId`. Each log entry stores `{eventId (s_*), sequence, type, payload, createdAt}` where `sequence` is a per-`userId` monotonic integer used for ordering. If the reconnecting device’s `lastMessageId` is unknown—meaning the ID does not resolve to `(userId, sequence)` either because it never existed, belongs to another `userId`, or was purged during manual repair—replay the most recent `maxReplayMessages` overall (ordered oldest-to-newest), set `auth_result.replayTruncated=true`, and set `historyReset=true` (field defined in `docs/architecture.md`). `replayTruncated` indicates only a suffix was available; `historyReset` specifically tells clients to drop any local state beyond what was replayed and treat that replay window as canonical history. After replay, set the session’s `lastDeliveredEventId` to the last replayed event even when truncated; this becomes the new cursor.
- On receiving a user `message`, the provider reserves the next per-`userId` sequence using a dedicated sequence table, generates a server event id (`s_<uuid>`), inserts the `events` row with that sequence, and only then inserts the `(deviceId, clientId)` row in `messages` referencing the event id (storing `contentHash`, `attachmentsHash`, attachments metadata, ack flag, `userId`, and the reserved sequence in `serverSequence`). The reservation + event insert + message insert + `message_assets` inserts MUST occur inside the same `BEGIN IMMEDIATE` transaction so any FK failure (missing asset, duplicate key, etc.) rolls back the entire batch—no stray `events` rows should survive. Attachment metadata MUST be stored atomically with the content hash. If the message insert hits a unique constraint, treat it as a duplicate and run idempotency checks (do not REPLACE/UPDATE the row). For each `asset` attachment, INSERT a row into `message_assets` to track references; if the FK insert fails because the asset was concurrently deleted/expired, translate it to `asset_not_found` and roll back the transaction. Section “Media + file transfer service” plus `docs/provider-testing.md` repeat this rule; keep all three synchronized. After commit, the event is broadcast to every device; LLM dispatch proceeds regardless of per-socket broadcast success. Message record creation MUST complete before adapter dispatch.
- Message record creation and event-log append MUST be atomic (single SQLite transaction). Atomicity applies to the database writes only; network broadcast occurs after commit. SQLite MUST run in WAL mode. The single-writer queue is the primary in-process guard; `BEGIN IMMEDIATE` is used to acquire the SQLite write lock and detect external contention (unexpected in v1). Sequence allocation uses the `user_sequences` table (see schema). The column name `nextSequence` means “next value to hand out”: the very first insert yields `1`, every successful update returns the post-incremented integer, so the sequence emitted to clients is 1,2,3… with no gaps unless the DB is manually edited. If the transaction fails, no partial writes are committed.
- Startup ordering (single-writer queue is not yet processing, but we still run the same infrastructure code path for consistency):
  1. Acquire `${statePath}/clawline.lock` via `flock` (exclusive advisory lock). Keep it held until startup either succeeds or exits.
  2. Open SQLite (`clawline.sqlite`) and enable WAL/foreign key pragmas.
  3. Run schema recovery (orphan scans, cleanup, migrations) via the single-writer queue to reuse shared code paths.
  4. Run media orphan scan (`${media.storagePath}`) still under the lock.
  5. Release the lock and begin listening.
If the DB is corrupt, the lock cannot be acquired, or `media.storagePath` is not readable/writable, fail startup and require operator intervention (delete/repair DB or fix permissions). On failure, log a single error including the reason (`db_corrupt`, `lock_unavailable`, or `media_unavailable`) and exit with a non-zero code.
- Allowlist and denylist files (`allowlist.json`, `denylist.json`) MUST parse as JSON arrays. If either file is missing, treat it as an empty array. If parsing fails, log `allowlist_parse_error`/`denylist_parse_error`, fail startup with `server_error`, and require operator intervention (fix or delete the file). Bootstrap logic MUST never attempt to continue with a partially parsed file.
- Broadcast is best-effort per socket and performed asynchronously: if a write fails or the socket's outbound buffer exceeds a small bound (e.g., 1MB), close that socket and rely on replay when it reconnects. Offline devices receive events via replay only; no durable per-device outbound queue is required beyond the shared event log.
- Active stream state is in-memory only and scoped to the originating `deviceId`. v1 does not resume streams across reconnects/restarts. If the originating socket closes while streaming **and no replacement socket has already authenticated**, mark the message record failed (`streaming: 2`) and the client must retry with a new `id`. If a replacement socket authenticates before the original closes (session takeover), move the active stream to the new socket (see §4) and close the old socket with `session_replaced`.
- Database writes must be serialized through a single-writer queue (one DB write at a time). Implement as an in-process async FIFO queue that wraps all `BEGIN IMMEDIATE` write transactions; the queue is the primary serialization mechanism. The queue length is bounded by `sessions.maxWriteQueueDepth` (default 1000); if it is full when a client message arrives, reject that message with `rate_limited` and log a warning (include queue depth) so operators can investigate. Message inserts run sequentially to avoid deadlocks. Network broadcasts occur outside the DB lock.
- With single-writer serialization and `user_sequences`, sequence allocation is deterministic. If sequence updates fail, treat as `server_error` (implementation bug). v1 does not retry with a new sequence.
- Table responsibilities:
  - `messages`: client-originated messages only (role `user` in v1), used for idempotency, ack, and attachment tracking.
  - `events`: canonical replay stream for both user echoes and assistant/system events.
  - Every accepted client message creates both a `messages` row and an `events` row (user echo). Assistant output is stored only in `events`.

### 4) LLM adapter integration
The provider requires a clawd adapter instance that satisfies the interface below. If the host exposes a different API, add a thin shim.

Recommended usage patterns:
- **Non-streaming**: `adapter.execute(prompt)`
- **Streaming (if supported by adapter)**: use `adapter.executeWithTUI(prompt, tui)` with a lightweight TUI shim that writes chunks to the WebSocket. Reiterate the normative rule: only the originating socket receives these chunk updates; sibling devices under the same `userId` must wait for the final assistant message.

Notes:
- The adapter contract is defined in clawd core at `src/adapters/index.ts`. The interface below mirrors that source for convenience; always treat the clawd repo as authoritative and keep this mirror in sync. Any adapter supplied to the provider MUST implement at least these members.
- This keeps provider compatible with clawd.me adapters (Claude Code or custom).
- The provider MUST enforce a wall-clock timeout for non-streaming `execute` calls (config: `sessions.adapterExecuteTimeoutSeconds`, default 300). On timeout, emit `error` `server_error` with the client `messageId`, mark the message record failed (`streaming: 2`), and require a new `id` for retry.
- If the adapter does not expose a streaming API, the provider must fall back to non-streaming (`execute`) and send a single `message` response.
  - Streaming detection: use streaming only when `adapter.capabilities?.streaming === true` **and** `typeof adapter.executeWithTUI === "function"`. Otherwise fall back to non-streaming `execute`.
  - Adapter acquisition: on plugin startup, resolve the adapter via the same clawd adapter loader used by core. If the plugin hook context already exposes an adapter instance, reuse it; otherwise load by name from `clawline.adapter` (or the clawd default adapter when unset). Resolve once and reuse for all requests.
  - Adapter selection must follow clawd.me configuration. If `clawline.adapter` is provided, pass it to the clawd adapter loader; otherwise use the clawd default adapter.
  - `execute` is required. If it is missing, treat this as a provider startup misconfiguration and fail fast (`server_error` on startup).
- Assistant event creation: every assistant chunk/final response consumes the same per-`userId` sequence allocator used for user messages and MUST run via the single-writer queue. However, to avoid turning long streams into hundreds of discrete SQLite commits, chunks MUST be coalesced: buffer adapter output and enqueue at most one write per `deviceId` every `streams.chunkPersistIntervalMs` (default 100ms) or when the provider needs to send a final snapshot. The coalescing buffer MUST be capped (default `streams.chunkBufferBytes` = 1MB per stream); if the cap is exceeded, flush immediately and log a warning. Each flush—whether chunk or final—runs through the single-writer queue and wraps the `UPDATE` in its own `BEGIN IMMEDIATE` transaction, so durability for failure recovery happens in bounded intervals instead of every token. The inactivity timer remains the safety net—losing the last <100ms of partial text is acceptable.
  1. When the adapter begins responding (first chunk or single-shot), reserve the next sequence and pre-generate an `s_<uuid>`.
  2. Insert an `events` row with that sequence (`originatingDeviceId = NULL`, `streaming = 1`, `payloadJson` containing the chunk snapshot, `payloadBytes = byteLength(payloadJson)`).
  3. Broadcast the chunk to the originating socket only.
  4. For subsequent chunks, run `UPDATE events SET payloadJson=?, payloadBytes=?, timestamp=?, streaming=1 WHERE id=?` (same `s_*` id). Broadcast the updated chunk.
  5. When the adapter completes successfully, run a final `UPDATE ... SET payloadJson=?, payloadBytes=?, timestamp=?, streaming=0` and broadcast to every device for that `userId`.
  6. On adapter failure or timeout, flush any buffered chunk to SQLite (so `events.payloadJson` reflects the last emitted text), then update the row with `streaming=2` and omit the final message; clients detect failure via missing-final detection. If the adapter fails before emitting any chunk, no assistant `events` row is created; the message record simply transitions to `streaming=2`.
  7. No `messages` row is created for assistant turns in v1; replay relies solely on the `events` table (user echoes + assistant entries ordered by sequence). Startup recovery never needs to mutate assistant rows because missing finals are surfaced through replay + client-side missing-final detection.
- If `execute` or `executeWithTUI` throws/rejects, emit `error` `server_error` with the client `messageId` and mark the message record failed (`streaming: 2`).
- Adapter failures do not block the per-user dispatch queue: mark the message failed and continue to the next queued message. v1 has no circuit breaker or backoff beyond normal retry semantics, but implementations MUST log a warning (with adapter name and elapsed time) after 5 consecutive failures so operators can intervene.
- Operator mitigation: because v1 cannot cancel in-flight adapter calls, operators SHOULD configure adapter/LLM timeouts and rate limits to bound resource usage during disconnect storms.
  - The `prompt` shape is defined by the clawd adapter contract in your version; the provider should pass exactly what clawd core would pass (typically a single string prompt), and not invent a new format.

Minimum adapter interface required by this provider:
```ts
type Adapter = {
  capabilities?: { streaming?: boolean };
  execute: (prompt: string) => Promise<{ exitCode: number; output: string }>;
  executeWithTUI?: (prompt: string, tui: { writeOutput: (chunk: string | Buffer) => void | Promise<void> }) => Promise<{ exitCode: number; output: string }>;
};
```
If an adapter returns a bare string, treat it as `{ exitCode: 0, output: <string> }`.
Adapter interface ownership: this provider mirrors the clawd core adapter contract. The authoritative interface lives in the clawd core repo (see its adapter types/loader source, e.g., `src/adapters/*.ts` in your clawd version). If clawd changes the adapter signature, update this document and the provider together.

Prompt construction (v1):
- Build a plain-text transcript from the last `maxPromptMessages` server events (user/assistant messages only), ordered oldest-to-newest.
- Format each turn as `User: <content>` or `Assistant: <content>` and append the new user message as the final `User:` line.
- Attachments are not inlined into the prompt. v1 adapter interface has no attachment parameter; providers MUST ignore attachments for prompt construction (text-only) and still persist/serve them for clients. Future versions may add a multimodal adapter interface.
- Attachment envelopes MUST follow the canonical `Attachment` union from `docs/architecture.md`: each entry declares `type` (`image` for inline base64 data or `asset` for uploaded files) and supplies either inline bytes (`data` + `mimeType`) or a fetch reference (`assetId`, which maps to `/download/:assetId`, or a known absolute URL surfaced via `metadata.url`). Providers MAY include a `metadata` object when that information already exists (filename, `mimeType`, `size`, `width`/`height`, link-preview text), but MUST omit speculative UI hints or derived “size classes.” Clients derive rendering strictly from `content` + `attachments`.
- Prompt truncation is intentional in v1: only the most recent `maxPromptMessages` are included and earlier context is dropped without an explicit marker.

Minimal TUI shim interface expected by adapters:
```
{
  writeOutput: (chunk: string | Buffer) => void | Promise<void>
}
```
`executeWithTUI` returns a Promise of `{ exitCode, output }`. Provider should send a final `message` with `streaming: false` when the Promise resolves, and emit `error` if `exitCode` is non-zero. If `writeOutput` throws or rejects, emit `error` `server_error` with `messageId` and mark the stream record failed. When at least one chunk arrived via `writeOutput`, the provider MUST ignore the `output` field (the accumulated chunks are authoritative). Only when **zero** chunks were received should the provider treat `output` as the full content (non-streaming fallback).

### 5) Media + file transfer service
Two-tier approach (small inline, large out-of-band):

**Inline (small attachments):**
- Small images encoded as base64 in `attachments[]` on a message.
- Size limits enforced by provider configuration (v1 default: `maxInlineBytes` = 256KB total decoded inline bytes per message). Per-attachment inline bytes must also be <= 256KB per `docs/architecture.md`.
- Inline attachments are image-only (accepted MIME types: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic` per `docs/architecture.md`). Non-image files MUST use `/upload` and `asset` references. Violations return `invalid_message`.

**Large transfers (v1):**
- Direct HTTP upload to the provider's built-in `/upload` endpoint on the same port as the WebSocket server.
- Client uploads the file with auth (`Authorization: Bearer <token>`); server returns `asset` metadata (assetId, mimeType, size).
  - Upload response schema (v1):
    ```json
    { "assetId": "a_123", "mimeType": "image/jpeg", "size": 12345 }
    ```
- Client then references the `assetId` in a chat message attachment.
- v1 does not rate-limit HTTP endpoints beyond size/auth checks.
- Upload request format: `POST /upload` with `multipart/form-data`, single file part named `file`. The part’s `Content-Type` is used as `mimeType`; if missing, set `application/octet-stream`. If auth fails or size limits are exceeded, return the corresponding `error` response without processing further bytes.
- Asset uploads accept any MIME type; no whitelist is enforced in v1 (inline attachments remain image-only per `docs/architecture.md`).
- The provider generates opaque asset identifiers shaped `a_<uuidv4>` (e.g., `a_4f1d2c7e-...`). Clients MUST treat them as opaque and the server MUST reject any download/upload reference whose `assetId` does not match this pattern (`invalid_message`) to avoid filesystem traversal.

**Downloads:**
- For large assets, client downloads from `/download/:assetId` (auth required, `Authorization: Bearer <token>`).
- For small assets, data may be inlined (base64) in the message.
- HTTP responses MUST set `Content-Type` to the stored `mimeType` (fallback `application/octet-stream` if missing) and include `Content-Length`. HTTP errors should return JSON bodies matching the `error` schema with status codes as defined in `docs/architecture.md`.
  - Minimum mapping: 401 (`auth_failed`), 403 (`token_revoked`), 404 (`asset_not_found`), 413 (`payload_too_large`), 429 (`rate_limited`), 500 (`server_error`), 503 (`upload_failed_retryable`).
HTTP auth rules (v1):
- Use the same JWT as WebSocket `auth` (Authorization: Bearer <token>).
- Validation order: 1) signature + expiry, 2) denylist. No additional payload is sent; the JWT’s embedded `deviceId` claim is the binding, so HTTP endpoints rely exclusively on the token itself.

Storage expectations:
- Local disk for bytes (v1)
- Metadata store: SQLite file in provider state dir (v1 default, `~/.clawd/clawline/`)
- Asset bytes store: `media.storagePath` (default `~/.clawd/clawline-media`), separate from `statePath`
- Asset bytes are stored at `${media.storagePath}/assets/<assetId>` (no extension); the file path is derived from `assetId`.
- Storage retention decision (v1): retain all messages and referenced assets indefinitely. This was an explicit product choice, not a missing feature. There are no automatic quotas or pruning in v1. The only automatic deletion is unreferenced uploads after `unreferencedUploadTtlSeconds`.
- **Storage cost note**: Attachments are stored twice (in `messages.attachmentsJson` and in each persisted `events` payload) so small inline data is available to both duplicate detection and replay. That means a 256KB inline image consumes roughly 700KB on disk; operators should size disks accordingly and monitor growth (`du -sh ~/.clawd/clawline*`). This is acceptable for family-scale deployments but should be documented so larger installs plan for it.
- On startup, the provider MUST scan `${media.storagePath}/assets` for orphaned files (no DB row) and delete them only if they are older than `unreferencedUploadTtlSeconds` (grace period). Process the scan in batches (e.g., 10,000 files at a time) and log a warning if the scan exceeds 30 seconds so operators can investigate unusually large media directories. The scan is best-effort—startup continues even if it takes longer, but the warning signals operators to trim disk usage. Temporary upload files live under `${media.storagePath}/tmp` and MUST be deleted on startup if older than `unreferencedUploadTtlSeconds`. Conversely, rows in `assets` that point to missing files are cleaned up by replaying uploads (if a crash occurred between DB insert and file rename).
- Downloads MUST check the `assets` table first; if no row exists, return `asset_not_found` even if a file is present.
  - Download implementation: open the asset file before sending headers; if open fails, return `asset_not_found`.
- Orphan scans apply only to files with no `assets` row. Unreferenced uploads are cleaned up separately via a single atomic statement so races with concurrent inserts are avoided (this cleanup runs via the same single-writer queue that serializes message inserts):
  ```sql
  DELETE FROM assets
  WHERE createdAt < ?
    AND NOT EXISTS (
      SELECT 1 FROM message_assets WHERE message_assets.assetId = assets.assetId
    );
  ```
  Run this inside the single-writer queue with the same cutoff value used for the filesystem scan (`now - unreferencedUploadTtlSeconds`). Because all write operations (message insert, message_assets insert, asset cleanup) flow through the same queue, there is never a concurrent insert that can sneak in between the `NOT EXISTS` check and the `DELETE`; without that serialization the FK would fire. Uploads should write to a temp file and atomically rename to `assetId` on completion so the cleanup never sees an in-progress file as eligible for deletion.
- v1 does not provide upload idempotency; if an upload is retried after a disconnect, the client receives a new `assetId` and should use that one. Unreferenced uploads are deleted after `media.unreferencedUploadTtlSeconds`. Referencing an expired asset returns `asset_not_found`; the client must re-upload.

### 6) Observability
- Use clawd.me core logger for structured logs (`clawd.log`).
- Log session lifecycle, auth events, upload status, and LLM errors.

## Protocol responsibilities (summary)

The provider implements the protocol described in `docs/architecture.md` and should add the following clarifications:

- **Streaming**: no separate `partial` type. Use `message` with `streaming: true` and the full text `content` accumulated so far; streaming updates MUST only change `content` (text) and keep `attachments[]` constant. Keep `streaming: true` until the response completes, then emit a final `message` with `streaming: false` that contains the full `content` snapshot to broadcast to every device. If the originating socket disconnects before another socket authenticates (session takeover), partial text is lost—there is no replay of `streaming: true` events.
- **Stream inactivity**: if no streaming `message` updates occur for `streamInactivitySeconds` (default 300), mark the stream failed; emit `error` `server_error` with `messageId` and do not replay partials. Timer starts at message record creation (even if `ack` send fails) and resets when a streaming `message` write completes on the originating device’s socket (the only socket that receives partials). There is no separate wall-clock timeout for streaming beyond this inactivity timer in v1; if the adapter continues running after failure, its output is ignored. The timer continues even if the client retries with a new id; the original record will fail on timeout. Update `messages.timestamp` on each streaming chunk so the restart timeout check is meaningful. Use the client message id (`c_*`) in `error.messageId` and mark the message record failed (`streaming: 2`) with no final server event; retrying the same `id` returns `invalid_message`. Client may retry with a new `id` per `docs/architecture.md`.
- Implementation hint: each active stream schedules a per-message timer (setTimeout) for `streamInactivitySeconds`. Reset/cancel it whenever a streaming chunk writes successfully. On timeout, mark the record failed, emit `error server_error`, and cancel adapter output.
- Startup recovery (before accepting connections; all steps run via the single-writer queue in this order):
  1. Scan `messages.streaming=1` (user messages awaiting assistant output). If `now - timestamp >= streamInactivitySeconds`, set to `2`. Newer rows remain so the client can retry.
  2. Scan `events.streaming=1` (assistant streams mid-flight). Use the same inactivity timer (`now - events.timestamp >= streamInactivitySeconds`) to transition them to `2`—`events.timestamp` already tracks the last chunk timestamp, so this is the same rule the live stream uses.
  3. Delete rows with `serverEventId IS NULL` (and their `message_assets` rows).
  4. Run the storage/orphan scans described below.
- Startup must also delete any rows with `serverEventId IS NULL` (crash between message insert and event insert). Delete associated `message_assets` rows in the same transaction so idempotency remains correct; clients will resend with the same `id`.
- Because event insert and message insert share a single transaction, user-echo `events` rows cannot survive without matching `messages` rows. Startup therefore does not need a separate user-echo cleanup pass.
- **Missing final detection**: if, after replay, a client has a user message with no corresponding assistant final message and no active stream, the client MUST treat the interaction as failed and allow retry with a new `id`. The provider does not emit a separate signal; the absence of a finalized assistant `s_*` event (replay never surfaces `streaming: true` entries) is the canonical indicator.
- **Replay of failed streams**: replay always includes the user echo (`role: "user"`) for every accepted message, even if the stream later failed. No additional failure event is persisted; clients detect failure by the absence of a finalized assistant message after the echo.
- **Streaming state transitions**: set `messages.streaming=1` on message insert; transition to `0` when the final assistant message is persisted; transition to `2` on adapter error or stream inactivity timeout. `ack` timing does not change the state transitions.
  - State machine summary:
    - insert → `1` (active)
    - adapter success/final message → `0` (finalized)
    - adapter error / inactivity timeout / socket-close cancellation → `2` (failed)
- Stream inactivity applies to streaming responses; for non-streaming `execute`, no inactivity timeout is enforced.
- **Oversize payloads**: if a message exceeds limits (content > 64KB or total payload > 320KB), return `error` `payload_too_large` and keep the connection open.
- **Malformed JSON**: parse failures close the connection (per `docs/architecture.md`).
- **WebSocket frame limits**: configure the WS library max payload (e.g., 384KB) and also track accumulated frame size while buffering; if the buffer exceeds limits, return `payload_too_large` and close the connection.
- **Empty content**: empty-string `content` is rejected with `invalid_message`.

## Implementation roadmap (phased delivery)

To keep the system testable and shippable at each milestone, implement in the following phases. Each phase re-runs the relevant portions of `docs/provider-testing.md`.

1. **Phase 1 – Core transport + text chat**
   - Plugin scaffolding, WebSocket `/ws`, pairing/auth flows, per-user event log, duplicate detection, session takeover, retry logic.
   - Only text messages (no attachments). Validate with the pairing/auth + streaming/messaging suites.
2. **Phase 2 – Media plane**
   - HTTP `/upload` + `/download/:assetId`, inline attachment enforcement, asset storage/cleanup, local disk management.
   - Re-run Phase 1 tests plus the media-specific scenarios (inline limits, asset TTL, multi-device protection).
3. **Phase 3 – Multi-device/admin UX polish**
   - Admin approval broadcast/replay, diagnostic endpoints, optional tooling (pending approvals replayed on admin login, etc.).
   - Re-run all suites, focusing on admin workflows and crash-only reissue behavior.

Each phase produces a working provider that can be exercised end-to-end before layering in the next capability.

Connection close behavior (v1):
- `1008` (Policy Violation) for `invalid_message`, `auth_failed`, `token_revoked`, and `rate_limited` for pairing/auth
- `1011` (Server Error) for `server_error`
- `1000` (Normal Closure) for `session_replaced` (close immediately after sending) and `pair_result` failures
- `1002` (Protocol Error) for malformed JSON
Rate limits for messages/typing return `rate_limited` but keep the connection open.

`invalid_message` close rules (v1):
- Missing/unknown/invalid-type `protocolVersion` on `pair_request` or `auth` → close
- `pair_request` from allowlisted device with `tokenDelivered: true` → close
- All other `invalid_message` cases → keep open
- **Ack**: send `ack` with the client message `id` immediately after the message+event transaction commits.
- After the WebSocket write callback resolves, enqueue a lightweight single-writer task to `UPDATE messages SET ackSent=1 WHERE deviceId=? AND clientId=?`. If the process crashes between the send and the update, the retry path will resend the `ack`; this is intentional and idempotent.
- If the `ack` write fails because the socket closes, leave `ackSent=0` and do not attempt to resend until the client retries with the same `id` (idempotency applies). The client is responsible for retrying on reconnect.
- **Typing**: provider emits assistant typing status during inference. Client-sent typing exceeding `maxTypingPerSecond` returns `error` `rate_limited`. Server-emitted assistant typing MUST also respect the same per-device cap (max 2 updates/s) to avoid flooding clients. Server auto-clears typing after `typingAutoExpireSeconds` of inactivity.
- **Error**: `error` messages include code + human-readable description (see `docs/architecture.md` for codes).
- **Error context**: include `messageId` for message-specific failures.
- **Message IDs**: reject client messages whose `id` does not start with `c_` (`invalid_message`).
- **Client ID mapping**: client `message.id` is stored as `messages.clientId`.
- **Idempotency**: treat duplicate client message IDs as retries scoped to `(deviceId, id)`; do not dispatch duplicates.
- **Idempotency ack**: if a retry matches an existing record and `ackSent=1`, re-send `ack` and do not re-dispatch to the LLM.
- **Idempotency ack (no prior ack)**: if a retry matches an existing record and `ackSent=0`, send `ack`, set `ackSent=1`, and do not re-dispatch to the LLM.
- **Retries during streaming**: if `messages.streaming=1`, retries simply re-send `ack`; they do not transfer partial delivery to a new socket. Only the originating connection ever receives streaming chunks. If that socket is gone, the client waits for the final assistant message via replay (or missing-final detection) and then retries with a new `id` if needed.
- **Duplicate lookup order**: check `messages` first for `(deviceId, id)`; if no record exists, treat it as a new message.
- **Content hash**: persist SHA-256 of UTF-8 `content` (hex-encoded) per client `id` and reject mismatched retries (`invalid_message`). This applies to client messages only; assistant messages may store a null/empty hash until finalized. Store the hash with the message record and use it for duplicate detection alongside attachments.
  - Example: `SHA-256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824`
- **Attachments in idempotency**: duplicate detection compares `contentHash` and attachment equality (order-sensitive). Attachment equality requires same length and order; for `image`, `mimeType` and decoded `data` bytes must match; for `asset`, `assetId` must match. A retry with different attachments MUST be rejected. Compute and store an `attachmentsHash` on message insert; compare hashes first to avoid repeated base64 decode. `attachmentsHash` is SHA-256 of a canonical UTF-8 JSON serialization of the attachments array (asset attachments hash by `assetId`):
  - If `attachments` is omitted or `[]`, treat it as the empty array and use `SHA-256("[]")`.
  - Normalize each attachment to an object with keys in this order only:
    - `image`: `{ "type": "image", "mimeType": "<mimeType>", "data": "<base64>" }`
    - `asset`: `{ "type": "asset", "assetId": "<assetId>" }`
  - Serialize the array with no whitespace and keys in the exact order above. Use a deterministic serializer (e.g., manual string building) rather than default `JSON.stringify`.
  - Example string: `[{"type":"image","mimeType":"image/png","data":"AAEC"}]`
  - Test vector: `SHA-256("[" + "{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"AAEC\"}" + "]") = 6859679dcdde814cc1d14a029b4141d596c4759c061e6099d6802caf5be5dc4b`
  - Asset test vector: `SHA-256("[{\"type\":\"asset\",\"assetId\":\"a_11111111-1111-1111-1111-111111111111\"}]") = 4a8fc9251d37cd4c7e5fa3eb49c8a1b7b9a0f147ae3379b7a946442d0c195c94`
  - Empty array vector: `SHA-256("[]") = 9019c64dc58d11bdfeab80b156d098788efc0f8609acb1df2b63184f04d34e5c`
  - Mixed attachments vector: `SHA-256("[{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"AAEC\"},{\"type\":\"asset\",\"assetId\":\"a_22222222-2222-2222-2222-222222222222\"}]") = 97cb0f4b51d4655f6a4b0d9a7f30229ed0c3e859ac24d136c5f9fe345b2df8c2`
- **Retry validation order**: if a message with the same `(deviceId, id)` exists, perform idempotency checks first; only validate schema/attachments if it is not a retry match.
- **Retry vs missing assets**: if a retry matches an existing record, treat it as idempotent even if the referenced asset was later deleted. For new messages, validate asset existence inside the same serialized insert transaction; if missing, return `asset_not_found`.
- **Total payload limit**: total payload size = UTF-8 `content` bytes + decoded inline attachment bytes; if > 320KB return `payload_too_large`. Check after base64 decode. Not configurable in v1.
- **Attachment count**: cap `attachments[]` length at 4 in v1 (protocol requirement from `docs/architecture.md`); reject with `invalid_message` if exceeded (applies to both inline and asset attachments).
- **Repeated oversize**: if a device sends `payload_too_large` more than 3 times within 60 seconds, close the connection with `1008` (Policy Violation).
- **Rate limiting**: enforce `maxMessagesPerSecond` (default 5); emit `rate_limited` for excess.
- **Session takeover**: send `error` with `session_replaced` before closing an old socket when a new connection for the same `deviceId` authenticates.
- **Server IDs**: generate opaque `s_<uuid>` IDs. Ordering is defined by the per-`userId` event sequence stored server-side; clients MUST use `s_*` ids as `lastMessageId` during `auth` so the server can map them to a sequence and replay later events.
- **First connection**: on first auth, clients MUST omit `lastMessageId` or send `null`.
- **User echoes**: upon accepting a `message`, emit a server `message` event with a new `s_<uuid>` id (role `user`) so other devices can display the content and dedupe. Include `deviceId` of origin in the payload for UI attribution.
- **Assistant messages**: server `message` events for role `assistant` omit `deviceId`.
- **User echo schema** (canonical envelope): `{ type: "message", id: "s_<uuid>", role: "user", content: string, timestamp: number, streaming: false, attachments?: Attachment[], deviceId: string }` (`streaming` is always `false` for user echoes).
- **Assistant message schema** (canonical envelope): `{ type: "message", id: "s_<uuid>", role: "assistant", content: string, timestamp: number, streaming: boolean, attachments?: Attachment[] }`.
- `events.originatingDeviceId` MUST match the `deviceId` field in the serialized user echo payload (both represent the originating device).

**Error code summary (v1 — authoritative set)**:

| Code | When emitted | Client expectation |
| --- | --- | --- |
| `auth_failed` | Bad/missing token, JWT mismatch, expired token | Clear token, return to pairing/auth |
| `token_revoked` | Device revoked via denylist | Surface “access revoked”, require operator intervention |
| `invalid_message` | Schema violations, duplicate-id mismatch, unsupported `protocolVersion` | Highlight validation error, allow retry |
| `payload_too_large` | Message or upload exceeds limits | Prompt user to shrink content |
| `asset_not_found` | Download/upload references unknown asset | Re-upload or refresh attachment |
| `rate_limited` | Pair/auth/message/typing throttles | Back off using exponential retry (start 1s, double until 30s, add ±1s jitter) |
| `pair_rejected` | DeviceId is denylisted | Show “access denied”, require operator intervention |
| `pair_denied` | Admin explicitly denied pending request | Show “request denied”, allow user to retry later |
| `pair_timeout` | Pending request exceeded TTL | Show “pairing timed out”, auto-retry pairing |
| `device_not_approved` | Device attempts `auth` before approval | Keep device on “awaiting approval” screen |
| `session_replaced` | Another socket for same device authenticated | UI shows “session moved”, stop sending |
| `upload_failed_retryable` | Temporary disk/IO error during HTTP upload | Retry upload after short delay |
| `server_error` | Unexpected failures (DB, adapter, internal) or `bind_not_allowed` startup failure | Show generic retry affordance |

Rate-limit counters are in-memory per provider process, so a restart clears the windows; operators relying on strict quotas must front the provider with an external limiter in v1.
- **Auth result fields**: on success, `auth_result` MUST include `replayCount` and `replayTruncated` (use `replayCount: 0, replayTruncated: false` when there is no history). On failure they may be omitted (see `docs/architecture.md`). `replayCount` includes only finalized replay messages.

## Configuration

`provider/README.md` suggests:

```json
{
  "clawline": {
    "enabled": true,
    "port": 18800,
    "pairing": {}
  }
}
```

`provider/README.md` is authoritative for full configuration; this section summarizes defaults used by the provider and must stay in sync. If they diverge, follow `provider/README.md`.

Authoritative defaults (provider uses defaults if omitted):
- `statePath` (default `~/.clawd/clawline/`) for allowlist/denylist/metadata
- `network` block: `bindAddress` (default `127.0.0.1`), `allowInsecurePublic` (default `false`)
- `port` (default `18800`) is a top-level `clawline` config key (not inside `network`)
- `adapter` (optional string; if set, selects the clawd adapter by name, otherwise use clawd default)
- `auth` block: `jwtSigningKey` (optional; HS256 key auto-generated on first run if omitted), `tokenTtlSeconds` (default 31,536,000 seconds / 1 year; set `null` to disable expiry; expired tokens must return `auth_failed`), `maxAttemptsPerMinute` (default 5), `reissueGraceSeconds` (default 600; crash-only reissue window described above)
- `pairing` block: `maxPendingRequests` (default 100), `maxRequestsPerMinute` (default 5), `pendingTtlSeconds` (default 300)
- `media` block: `maxInlineBytes` (default 256KB), `maxUploadBytes` (default 100MB), `storagePath`, `unreferencedUploadTtlSeconds` (default 3600)
  - `media.storagePath` default: `~/.clawd/clawline-media`
- `sessions` block: `maxMessageBytes` (default 64KB), `maxReplayMessages` (default 500), `maxPromptMessages` (default 200), `maxMessagesPerSecond` (default 5), `maxTypingPerSecond` (default 2), `typingAutoExpireSeconds` (default 10), `maxQueuedMessages` (default 20), `maxWriteQueueDepth` (default 1000), `adapterExecuteTimeoutSeconds` (default 300), `streamInactivitySeconds` (default 300)
  - `maxMessageBytes` applies to UTF-8 `content` only; total payload size limits (content + inline attachments) are 320KB as defined in `docs/architecture.md`. Providers MUST clamp any configured value above 64KB down to 64KB and SHOULD log a warning when clamping occurs so operators know their config was ignored.
  - `streamInactivitySeconds` is a tunable default; operators may raise it for long tool-use flows.
- `streams` block: `chunkPersistIntervalMs` (default 100) and `chunkBufferBytes` (default 1_048_576). These control the coalescing behavior described in §4 and ensure all chunk writes stay on the single-writer queue.

## State file schemas

Allowlist (`${statePath}/allowlist.json`):
```json
  {
    "version": 1,
    "entries": [
      {
        "deviceId": "d2f1c0d1-9a4b-4a92-9c6d-2c4e4c9f7b2a",
        "claimedName": "Kaywood",
        "deviceInfo": { "platform": "iOS", "model": "iPhone 15", "osVersion": "17.2", "appVersion": "1.0.0" },
        "userId": "user_4f1d2c7e-7c52-4f75-9f7a-2f7f9f2d9a3b",
        "isAdmin": true,
        "tokenDelivered": true,
        "createdAt": 1704672000000,
        "lastSeenAt": 1704672000000
      }
    ]
  }
```

Denylist (`${statePath}/denylist.json`):
```json
[
  { "deviceId": "ABC123", "revokedAt": 1704672000000 }
]
```

Notes:
- `createdAt`, `lastSeenAt`, and `revokedAt` are Unix epoch milliseconds.
- `lastSeenAt` MUST be persisted synchronously on every successful `auth` before sending `auth_result`. “Persisted” here means “write the updated allowlist JSON to disk (including fsync if the platform requires it) as part of the same tick” so a crash immediately after `auth_result` still has the timestamp. During active sessions, it is acceptable to update only the in-memory copy whenever either (a) the server receives a WebSocket pong keepalive or (b) the device sends/receives any chat payload; flush that memory value to disk at least once every 60 seconds (or immediately on disconnect). It may be `null` only before the device has ever authenticated. Re-issue logic relies on this field; legacy entries missing `lastSeenAt` should be treated as `null`.
- Pending pair requests live only in memory (intentionally not persisted per `docs/provider-testing.md`); on restart they are dropped and devices must re-request pairing.
- Lock file: `${statePath}/allowlist.lock` (advisory lock used during first-admin bootstrap).

## Metadata schema (SQLite)

SQLite DB path: `${statePath}/clawline.sqlite`.

Minimal schema (v1):
```sql
-- Provider MUST execute on DB open:
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE messages (
  deviceId TEXT NOT NULL,
  userId TEXT NOT NULL,
  clientId TEXT NOT NULL,
  serverEventId TEXT,
  serverSequence INTEGER NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  contentHash TEXT,
  attachmentsHash TEXT,
  byteSize INTEGER NOT NULL,
  timestamp INTEGER NOT NULL, -- Unix epoch milliseconds
  streaming INTEGER NOT NULL CHECK (streaming IN (0, 1, 2)),
  attachmentsJson TEXT,
  ackSent INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (deviceId, clientId),
  FOREIGN KEY (serverEventId) REFERENCES events(id)
);
CREATE INDEX idx_messages_userId ON messages(userId);
CREATE INDEX idx_messages_userId_timestamp ON messages(userId, timestamp);
CREATE INDEX idx_messages_streaming_timestamp ON messages(streaming, timestamp);
CREATE UNIQUE INDEX idx_messages_userId_serverSequence ON messages(userId, serverSequence);
CREATE INDEX idx_messages_serverEventId ON messages(serverEventId);

CREATE TABLE user_sequences (
  userId TEXT PRIMARY KEY,
  nextSequence INTEGER NOT NULL
);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  userId TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  originatingDeviceId TEXT,
  type TEXT NOT NULL,
  streaming INTEGER NOT NULL CHECK (streaming IN (0, 1, 2)),
  payloadJson TEXT NOT NULL,
  payloadBytes INTEGER NOT NULL,
  timestamp INTEGER NOT NULL -- Unix epoch milliseconds
);
CREATE UNIQUE INDEX idx_events_userId_sequence ON events(userId, sequence);
CREATE INDEX idx_events_streaming ON events(streaming) WHERE streaming = 1;
CREATE INDEX idx_events_streaming_timestamp ON events(streaming, timestamp) WHERE streaming = 1;
CREATE INDEX idx_events_userId_timestamp ON events(userId, timestamp);
CREATE INDEX idx_events_originatingDeviceId ON events(originatingDeviceId);
CREATE INDEX idx_events_timestamp_userId_sequence ON events(timestamp, userId, sequence);

CREATE TABLE assets (
  assetId TEXT PRIMARY KEY,
  userId TEXT NOT NULL,
  uploaderDeviceId TEXT NOT NULL,
  mimeType TEXT NOT NULL,
  size INTEGER NOT NULL,
  createdAt INTEGER NOT NULL -- Unix epoch milliseconds
);
CREATE INDEX idx_assets_userId ON assets(userId);
CREATE INDEX idx_assets_createdAt ON assets(createdAt);

CREATE TABLE message_assets (
  deviceId TEXT NOT NULL,
  clientId TEXT NOT NULL,
  assetId TEXT NOT NULL,
  PRIMARY KEY (deviceId, clientId, assetId),
  FOREIGN KEY (deviceId, clientId) REFERENCES messages(deviceId, clientId) ON DELETE CASCADE,
  FOREIGN KEY (assetId) REFERENCES assets(assetId) ON DELETE RESTRICT
);
CREATE INDEX idx_message_assets_assetId ON message_assets(assetId);

CREATE TABLE schema_version (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL
);
INSERT OR IGNORE INTO schema_version(id, version) VALUES (1, 1);
```

If `PRAGMA journal_mode=WAL` fails to switch the database (e.g., another process already opened it in DELETE mode), treat startup as failed with `db_locked`; v1 does not attempt to continue in fallback modes. The provider requires SQLite ≥ 3.35.0 because the `user_sequences` allocation uses `RETURNING`; fail startup with `db_corrupt` if an older library is detected.

Schema notes:
- On startup, run `SELECT version FROM schema_version WHERE id = 1`. If no row exists or `version != 1`, fail startup with `server_error` and require operator intervention (manual migration or delete/recreate the DB).
- Foreign keys are enforced via `PRAGMA foreign_keys=ON` and should remain enabled for the lifetime of the process.
- `messages.serverEventId` is expected to be non-null for valid rows; it is nullable only to support crash/legacy recovery and should not be null during normal operation. SQLite permits NULL FKs, so the transient state does not violate constraints; the startup cleanup above removes such rows.
- The `serverEventId` FK fires immediately because the event is inserted before the message; no deferred constraint is required.
- `events.originatingDeviceId` is set for user message echoes and is null for assistant/system events.
- Implementations MUST set `originatingDeviceId` for user-role message echoes via application-level validation (do not rely on SQLite CHECK constraints for JSON fields). If missing, fail the insert with `server_error` (implementation bug).
- `events.streaming` mirrors the last-known streaming flag for assistant events only (`0 = finalized`, `1 = streaming`, `2 = failed`). User echoes always persist with `streaming=0`. Only one of (`messages.streaming`, `events.streaming`) changes for a given logical message: user messages update the `messages` row, assistant responses update the `events` row.
- `events.payloadJson` stores the full serialized server event envelope as sent over the WebSocket (including `type` and all fields; see `docs/architecture.md` `ServerMessage` for the canonical envelope schema).
- `events.payloadBytes` is the UTF-8 byte length of `payloadJson` and is used for observability/approximate storage accounting.
- `idx_events_originatingDeviceId` powers admin tooling that shows which device produced a historical message; do not remove it unless that tooling changes.
- `idx_events_timestamp_userId_sequence` supports chronological export tooling and keeps replay lookups efficient when walking “latest N events.” Remove only if replay/export strategy changes.
- v1 does not define a migration system; future schema changes must document an explicit migration or require a fresh database.
- `assets` has no file path column; implementations derive the on-disk path from `media.storagePath` and `assetId` (see storage expectations).
- `idx_message_assets_assetId` supports the unreferenced-upload cleanup query described above; do not remove it unless the cleanup strategy changes.
- Unreferenced cleanup runs in its own transaction. Because `message_assets` uses `ON DELETE RESTRICT`, the deletion query must re-check references inside the same transaction before deleting each asset row to avoid races with concurrent message inserts.
- `idx_messages_streaming_timestamp` exists so startup recovery and inactivity scans can locate `streaming=1` rows efficiently.
- `events.sequence` is per-`userId` monotonic; uniqueness is enforced by the `(userId, sequence)` index.
- `events.sequence` is the authoritative per-`userId` ordering. `messages.serverSequence` is a denormalized copy for join-free lookups and must match the user echo event sequence in the same transaction.
- `user_sequences` drives allocation: in the same transaction as the message/event insert, run `INSERT INTO user_sequences(userId, nextSequence) VALUES (?, 1) ON CONFLICT(userId) DO UPDATE SET nextSequence = nextSequence + 1 RETURNING nextSequence AS reservedSequence`. Sequences are 1-based (first value = 1). Use `reservedSequence` as the event/message sequence. Sequence gaps may appear only after manual database repair (rows removed) and are acceptable; replay logic relies on monotonic ordering (`sequence > lastSequence`) and does not require contiguous integers.
- `docs/architecture.md` is complete for v1 schemas; do not implement new payload shapes without updating it first.
- `messages.role` is future-proofing; v1 only writes `user` (assistant/system messages are never stored in `messages`).
- Valid `events.type` values in v1: `message` (all persisted events are message envelopes; typing/error are not persisted). Implementations SHOULD enforce `type='message'` on insert; other values are reserved for future versions.
- Admin-only `pair_approval_request` events are transient and not stored in `events`.
  - `messages.streaming` state: `0=finalized`, `1=active`, `2=failed`. This is internal DB state; protocol mapping: `0 -> streaming: false`, `1 -> streaming: true`, `2 -> no final message emitted`.
- `messages.serverEventId` and `messages.serverSequence` are populated atomically in the insert transaction; `serverEventId` is only null if a crash interrupts persistence before the event row is written.
- `messages.attachmentsJson` stores the original attachment objects (including base64 `data` for inline images); this is intentionally redundant but bounded by `maxInlineBytes`/payload caps. `messages.byteSize` = UTF-8 byte length of `content` + sum of decoded inline attachment bytes. It exists for accounting/metrics only; the SQLite row will be larger due to base64 overhead. Duplicate checks use `attachmentsHash` and only decode on mismatch.

## Failure handling

- **Auth failure**: emit `auth_result` with `success: false`, reason code, and close the socket.
- **LLM failure**: emit `error` and stop streaming; session remains open.
- On LLM failure or stream timeout, mark the message record failed (`streaming: 2`), do not send a final `message`, and require retry with a new `id` (reusing the old `id` returns `invalid_message`).
- **Upload failure**: emit `error` with `upload_failed_retryable` when possible.
- **Disconnects**: re-auth on reconnect; support replay via `lastMessageId`.

## Test requirements

Implementation must satisfy the required scenarios in `docs/provider-testing.md`.

## Open questions

- See `docs/architecture.md` for shared open questions (push notifications, E2E encryption, multi-session policy).
