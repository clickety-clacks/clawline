# iOS Connection Guide: Clawline Provider

## Purpose

Describe how the iOS client (Clawline) connects to the OpenClaw Clawline provider runtime, including pairing, authenticated chat, streaming messages, large media/file transfers, and keeping multiple devices for the same user in sync. This is aligned with `architecture.md` and `ios-architecture.md`.

## Interpretation

This guide is the client-side contract. Statements using MUST/SHOULD are binding; other explanatory text is guidance. Architectural choices live in `architecture.md`.

Replay/cursor behavior is specified with the provider invariants in
`specs/clawline-replay-and-memory-pressure-invariants.md`. The iOS client MUST
send per-stream replay cursors; `lastMessageId` is compatibility-only.

## Client roles (per iOS architecture)

From `ios-architecture.md` and `(external/common reference removed)`:
- `ConnectionServicing`: pairing + admin approvals
- `ChatServicing`: authenticated WebSocket connection + message streaming via `AsyncStream`
- `AuthManaging`: token storage and auth state

## Connection flow

All connections are direct to the provider endpoint. Transport security is handled by the operator (VPN/TLS/firewall) if needed.

### 1) Pairing (first launch)

1. Client generates/stores a stable `deviceId` (UUIDv4 string). Each device has its own ID even when multiple devices belong to the same user account. Persist it in Keychain so reinstalls reuse the same value.
2. `ConnectionServicing` opens a short-lived WebSocket to `/ws` and sends:
   ```json
   { "type": "pair_request", "protocolVersion": 1, "deviceId": "ABC123", "claimedName": "Kaywood", "deviceInfo": { "platform": "iOS", "model": "iPhone 15" } }
   ```
3. Provider returns:
   - `pair_result` success with JWT token and `userId` (shared across every device for the same account), or
   - `pair_result` denied with reason
4. Client stores token via `AuthManaging`, closes the pairing socket, and opens a new authenticated WebSocket using `auth` (below).

UI states should follow `PairingState` in the iOS spec (optional approval code is allowed but not required in v1). `claimedName` comes from the user during pairing (default to the device’s friendly name, allow editing, clamp to <=64 UTF-8 bytes).

Admin approvals (v1):
- The first device to pair becomes an admin automatically.
- Once authenticated, admin devices receive `pair_approval_request` events on the main chat WebSocket (no second socket). `ConnectionServicing` handles bootstrap pairing, then subscribes to the stream surfaced by `ChatServicing` so only one socket stays open per device. `ChatServicing` MUST expose a raw `AsyncStream<ServerMessage>` (or equivalent) of all server events; `ConnectionServicing` filters `pair_approval_request` from that stream and publishes them to the UI. The provider MUST re-emit any still-pending approvals when an admin successfully authenticates, so no approval requests are lost during the pairing→auth handoff.
- `pair_approval_request` schema (from `architecture.md`):
  ```json
  {
    "type": "pair_approval_request",
    "deviceId": "<pendingDeviceId>",
    "claimedName": "Kaywood",
    "deviceInfo": { "platform": "iOS", "model": "iPhone 15" }
  }
  ```
- Admins respond with:
  ```json
  {
    "type": "pair_decision",
    "deviceId": "<pendingDeviceId>",
    "userId": "<existingOrNewUserId>",
    "approve": true
  }
  ```
  `userId` MUST be included when `approve: true` so the provider knows which account to attach the device to (new UUID for new accounts). `approve: false` may omit the field.
  `pair_decision` has no `id` field and does not receive `ack`; retries are done by resending the same payload (idempotency is keyed on `deviceId` + pending state on the server). If multiple admins decide concurrently, the first decision wins; later decisions receive `error` `invalid_message`.
  Admin UIs should treat `invalid_message` responses as “request already resolved” and remove the pending item.

`pair_result` responses follow `architecture.md`: success payload `{ success:true, token, userId }`; failure payload `{ success:false, reason: "pair_rejected" | "pair_denied" | "pair_timeout" }`.

### 2) Authenticated session

On subsequent launches:
1. Client opens WebSocket.
2. Client sends:
   ```json
   {
     "type": "auth",
     "protocolVersion": 1,
     "token": "<jwt>",
     "deviceId": "ABC123",
     "lastMessageId": "s_active_stream_fallback",
     "replayCursorsBySessionKey": {
       "agent:main:clawline:flynn:main": "s_main_last_seen",
       "agent:main:clawline:flynn:dm": "s_dm_last_seen"
     }
   }
   ```
   `replayCursorsBySessionKey` is the authoritative replay input. Each key is a subscribed session key and each value is the most recent finalized/replayable server event ID (`s_*`) fully processed for that exact stream. Streaming partial IDs must not be used as replay cursors. `lastMessageId` is a compatibility fallback only; use the cursor for the actively selected chat stream at auth/reconnect time when known, otherwise omit it or send `null`. Do not compute `lastMessageId` by taking the maximum value across all stream cursors.
3. Provider responds with:
   ```json
  {
    "type": "auth_result",
    "success": true,
    "userId": "user_...",
    "sessionId": "sess_...",
    "isAdmin": true,
    "replayCount": 12,
    "replayTruncated": false,
    "historyReset": false
  }
   ```
   `sessionId` is diagnostic only and not reused by the client.
4. On failure, client clears token and returns to pairing. Example failure payload:
   ```json
   { "type": "auth_result", "success": false, "reason": "auth_failed" }
   ```
5. On success, provider replays missed events (if any) independently per subscribed stream using `replayCursorsBySessionKey`, falling back to `lastMessageId` only for the stream that owns that legacy event. Every device tied to the same `userId` eventually observes the same ordered history, although individual sockets may lag until replay completes.
  - Admin detection: read `auth_result.isAdmin` to decide whether to expose admin-only UI (e.g., pending approvals). The JWT no longer carries this flag; rely on the runtime value from the provider and expect it to change if the allowlist is edited.
6. Use `auth_result.replayCount`, `auth_result.replayTruncated`, and `auth_result.historyReset` to show a "history truncated/reset" notice when needed. When `historyReset` is true, drop any local conversation state beyond what replay delivered.
   `historyReset` is a conservative global reset signal for the authenticated connection. Because v1 does not include per-stream reset metadata, clients must treat it as applying to all subscribed local stream caches for that connection.
Clients must include `protocolVersion: 1` in `pair_request` and `auth` or the provider will reject the request with `error` `invalid_message` and close the socket.
The client may call `GET /version` (no auth) to verify `protocolVersion: 1` before attempting a connection. If the server responds with a different version, fail fast and show an update-required UI. Response schema:
```json
{ "protocolVersion": 1 }
```

### 3) Reconnect

- On socket loss, attempt reconnect with exponential backoff (start 1s, double each attempt, max 30s, add 0–1s random jitter).
- Use a short initial connection timeout (e.g., 10 seconds) before entering backoff.
- Re-auth with stored token (per device).
- Include `replayCursorsBySessionKey` in the auth payload so the server can replay missed messages for each stream while also keeping other devices for the user in sync.
- Include `lastMessageId` only as a compatibility fallback for older providers. It must be the cursor for the actively selected chat stream at auth/reconnect time when known; otherwise omit it or send `null`.
- Client should deduplicate replayed finalized events by `id`. A prior streaming partial with the same `id` does not make the final message a duplicate; the final must replace/commit the partial.
- Keepalive: server sends WebSocket ping control frames every 30s; client responds with pong. If no ping is received for 90s, treat the connection as dead and reconnect.

## Chat message flow

### Send (client -> provider)
```json
{
  "type": "message",
  "id": "c_123",
  "sessionKey": "agent:main:clawline:flynn:main",
  "content": "Hello",
  "attachments": []
}
```
Client message IDs must start with `c_`; server-assigned events use `s_<uuid>`. The server uses a per-`userId` sequence internally for ordering; clients treat `s_*` as opaque cursors.
`sessionKey` selects the target stream. It may be omitted only for legacy/default-Main sends; Clawline multi-stream UI paths must include it.
Max `content` length is 64KB UTF-8; longer payloads return `payload_too_large`.
Invalid message ID prefixes are rejected with `invalid_message`.
Duplicate client message IDs are treated as idempotent retries per device. Client message IDs are scoped to a single `deviceId`; two devices may use the same `c_*` values without conflict. Replay dedup uses server event IDs (`s_*`), not client IDs. Clients must reuse the same `id` for network/ack retries (before `ack`) and never change the `content` for an existing `id` (if content differs, the server returns `invalid_message`). If a stream fails or completes without a final assistant message after `ack`, retry with a new `id`.
After the provider accepts a user message, it echoes a server event (new `s_<uuid>` id with `role: "user"`) back to every device on the account—including the sender—so all devices append the same representation to their local timeline. The server includes the originating `deviceId` for attribution and `clientMessageId` so the sender can replace the correct optimistic local message.
Echoed user message schema (server -> client):
```json
{
  "type": "message",
  "id": "s_789",
  "role": "user",
  "content": "Hello",
  "timestamp": 1704672000000,
  "sessionKey": "agent:main:clawline:flynn:main",
  "streaming": false,
  "deviceId": "ABC123",
  "clientMessageId": "c_123",
  "attachments": []
}
```

### Ack (provider -> client)
```json
{ "type": "ack", "id": "c_123" }
```
Client should keep messages in a "sending" state until `ack` arrives. If no `ack` is received within 5 seconds, resend the message with the same `id`. Track pending acks and resend after reconnect if they never received `ack`. Persist pending IDs to disk before sending so they can be retried after app relaunch.

### Receive (provider -> client)
Non-streaming (timestamps are Unix epoch milliseconds):
```json
{
  "type": "message",
  "id": "s_456",
  "role": "assistant",
  "content": "Hi",
  "timestamp": 1704672000000,
  "sessionKey": "agent:main:clawline:flynn:main",
  "replyToMessageId": "s_789",
  "replyToClientMessageId": "c_123",
  "streaming": false
}
```

Streaming (partial messages):
```json
{
  "type": "message",
  "id": "s_456",
  "role": "assistant",
  "content": "Hi there",
  "timestamp": 1704672000000,
  "sessionKey": "agent:main:clawline:flynn:main",
  "replyToMessageId": "s_789",
  "replyToClientMessageId": "c_123",
  "streaming": true
}
```

Assistant messages may include `attachments`. Inline attachments (`type: "image"`) contain base64 data; URL attachments (`type: "url"`) reference files under the provider web root and are fetched directly by URL.

After reconnect replay and any immediately queued gap-fill live messages drain, the provider sends:
```json
{ "type": "sync_complete" }
```
Treat this as the earliest point where reconnect missing-final detection may run.

Client behavior:
- Optimistically append user messages but track them by outgoing `c_*` id (e.g., `pendingMessages[c_id]`). When the server echoes the message with `role: "user"`, `deviceId` matching the local device, and matching `clientMessageId`, replace that optimistic entry with the echoed one (remove it from `pendingMessages`). Echoes from other devices are appended normally.
- `ChatServicing` yields streaming messages as received (same `id`, `streaming: true`).
- ViewModel merges assistant messages by `id` and toggles `isStreaming` to false when the final message arrives.
- Reconnect outcomes (per device):
  - Stream still active when disconnect happens: live streaming does not resume unless there is an overlapping session takeover. The provider may continue generation in the background; if it finalizes, replay delivers the final message on reconnect.
  - Stream finalized while disconnected: provider replays the final message (all devices see the same final response).
  - Stream inactive with no final message (no updates for 5 minutes): treat it as failed and retry with a new `id`. The server does not replay partials, so failure is detected by missing-final logic on reconnect.
  - Missing-final detection (client requirement): after reconnect `sync_complete`, if a user echo's server `id` has no assistant final with matching `replyToMessageId` and no active stream, treat it as failed and surface a retry affordance. Do not use `replyToClientMessageId` alone for this check because `c_*` ids are device-scoped.

### Typing indicators
Client may emit typing events (no `role` field):
```json
{ "type": "typing", "active": true }
```

Provider may emit typing events (assistant only in v1; user typing is not relayed to other devices):
```json
{ "type": "typing", "role": "assistant", "active": true }
```

`ChatServicing` should expose these as `incomingTyping` events for the UI to consume.

Typing events are rate-limited to 2 per second per device; excess events receive `rate_limited`.

## Session routing

Messages carry a `sessionKey` field that identifies which conversation stream they belong to. See `architecture.md` for the full session key architecture.

### Session key format

- **DM stream**: `agent:main:clawline:{userId}:dm` — per-user Clawline DM stream (admins only)
- **Personal stream**: `agent:main:clawline:{userId}:main` — per-user isolated session
- **Global OpenClaw session**: `agent:main:main` is not a Clawline stream key. It may still be targeted, adopted, or fallback-routed as an OpenClaw session key, but clients must not treat it as a Clawline-owned stream cursor namespace.

### Message structure

```json
{
  "type": "message",
  "id": "s_abc123",
  "role": "assistant",
  "content": "Hello",
  "timestamp": 1735600000000,
  "sessionKey": "agent:main:clawline:flynn:main",
  "streaming": false
}
```

- `sessionKey`: Which session this message belongs to (used for routing)
- `role`: `"user"` or `"assistant"`
- `streaming`: Whether this is an in-progress assistant update

### Client routing

- Single WebSocket connection per user
- Filter incoming messages by `sessionKey` to route to correct UI stream
- `agent:main:clawline:{userId}:dm` → DM stream (admins only)
- `agent:main:clawline:{userId}:main` → Personal stream

Admin users receive messages from both streams. Non-admin users receive only their personal stream.

## Errors & status codes

- WebSocket `error.code` values come from `architecture.md` (`auth_failed`, `token_revoked`, `invalid_message`, `payload_too_large`, `not_found`, `rate_limited`, `session_replaced`, `upload_failed_retryable`, `server_error`). Display them or map to user-friendly text.
- `auth_result.reason` values include `auth_failed`, `token_revoked`, and `device_not_approved`. Treat `auth_failed` as “clear token and restart pairing”; expired tokens are reported as `auth_failed` in v1.
- For `device_not_approved`, keep the device on the “Awaiting approval” screen, retry pairing automatically every ~30s, and notify the user that an admin must approve.
- HTTP uploads return JSON errors with HTTP statuses: 400 (`invalid_message`), 401 (`auth_failed`), 403 (`token_revoked`), 404 (`not_found`), 413 (`payload_too_large`), 429 (`rate_limited`), 503 (`upload_failed_retryable`), 500 (`server_error`). Treat 401/403 as token failures (clear token).
- `session_replaced` is terminal: the old socket closes immediately when another connection authenticates. UI should show “connected elsewhere” and prompt the user to continue on the new device; do not auto-reconnect until the user explicitly chooses to, to avoid kicking the new session.
- Provider URL configuration: v1 requires users to enter the provider’s base URL or IP manually in Settings. There is no discovery protocol; the app stores this value securely (Keychain/UserDefaults) and reuses it until the user edits it.

### Rate limits (client behavior)

| Action | Limit | Client response |
| --- | --- | --- |
| `pair_request` | 5/min per `deviceId` | Show “Too many attempts” toast, retry with exponential backoff |
| `auth` | 5/min per `deviceId` | Clear token on repeated failure, return to pairing |
| `message` send | 5/sec per `deviceId` | Queue locally, retry after 200–500 ms |
| `typing` send | 2/sec per `deviceId` | Drop extra typing updates; rely on auto-expire |
| Oversize payloads | `payload_too_large` error; socket stays open unless another close condition applies | Warn user and throttle UI |

## Media and file transfer (client integration spec)

Two tiers: inline images for small attachments (<= 256KB raw bytes; base64 adds ~33% overhead—expect ~341KB JSON payloads), and out-of-band uploads for larger files. HTTP upload uses the same host/port as the WebSocket endpoint. The provider serves files from a `/www` web root; any file under that root is GETtable by URL. The `/www` tree is an unmanaged dumping-ground for user-hosted files and is distinct from any tracked/managed media storage. The provider enforces limits on decoded bytes before base64, so clients should preflight and reject oversize payloads locally.

### Attachment schema (bidirectional)

Attachments appear on both **client → server** messages and **server → client** echoes/assistant responses.

```json
[
  { "type": "image", "mimeType": "image/jpeg", "data": "<base64>" },
  { "type": "url", "url": "http://host:port/media/m_123" }
]
```

- Inline attachments are **image-only**. Non-image files MUST use `/upload` + `type: "url"`.
- Clients MUST accept `attachments[]` on user echoes and assistant messages. These are **not** UI hints; they are canonical payloads.
- Providers may include a `metadata` object on attachments (e.g., `filename`, `mimeType`, `size`, `width`, `height`). Clients should ignore unknown metadata fields and never require them.

### Size and count limits (v1)

- Inline attachment bytes (decoded) per attachment: **<= 256KB**.
- Total inline bytes per message: **<= 256KB**.
- Attachment count per message: at most **4 total attachments** across inline and URL attachments.
- Total payload size per message: **<= 320KB** (UTF-8 `content` bytes + decoded inline bytes).
- Allowed inline `mimeType` values: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`.
- Max upload size: **100MB** (raw bytes).

### Client → server flow

**Inline image (small)**
```json
{
  "type": "message",
  "id": "c_124",
  "sessionKey": "agent:main:clawline:flynn:main",
  "content": "Check this",
  "attachments": [
    { "type": "image", "mimeType": "image/jpeg", "data": "<base64>" }
  ]
}
```

**HTTP upload + URL reference (large files)**

1) Upload via HTTP `POST /upload` (auth required, multipart, field name `file`). Use `Authorization: Bearer <token>`. The part’s `Content-Type` is used as the stored `mimeType` (if missing, the server stores `application/octet-stream`).

2) Provider responds with URL metadata (JSON):
```json
{
  "id": "m_123",
  "url": "http://host:port/media/m_123",
  "mimeType": "image/png",
  "size": 5242880
}
```
   v1 does not include filename, checksum, or expiry in the response. Clients SHOULD treat the URL as opaque and avoid validating the path beyond basic non-empty safety checks.

3) Send a message referencing the URL:
```json
{
  "type": "message",
  "id": "c_125",
  "sessionKey": "agent:main:clawline:flynn:main",
  "content": "Here is the file",
  "attachments": [{ "type": "url", "url": "http://host:port/media/m_123" }]
}
```

If the referenced URL is missing, the server returns `not_found`.

### Server → client flow

Assistant messages (and user echoes) may include:

- Inline images (`type: "image"` + base64) — decode and render directly.
- URL references (`type: "url"` + `url`) — fetch bytes directly by URL from the provider web root.

### HTTP endpoints, auth, TTLs, and storage

- **Auth:** `/upload` requires `Authorization: Bearer <token>`.
- **Endpoints:** same host/port as the WebSocket server; transport is plaintext in v1.
- **Errors:** JSON error schema + HTTP status (`400` invalid_message, `401` auth_failed, `403` token_revoked, `404` not_found, `413` payload_too_large, `429` rate_limited, `503` upload_failed_retryable, `500` server_error).
- **Retention:** files are retained indefinitely in v1 unless an operator removes them from the web root.
- **Storage:** server writes bytes under `<webroot>/media/<id>`; `/www` is served from a configurable filesystem root (default `workspace/www`) and any file under it is GETtable by URL.

## Error handling

Error schema (from `architecture.md`):
```json
{ "type": "error", "code": "invalid_message", "message": "Details", "messageId": "c_123" }
```
`messageId` is optional and only present for message-specific failures (e.g., stream errors).

- `auth_result` failure: clear token and return to pairing.
- `error` messages: display inline banner and keep connection alive.
- Upload errors: show retry action.
- `upload_failed_retryable` means the client should retry the upload.
- HTTP status codes for upload follow `architecture.md`.
- `pair_result` failure reasons include `pair_rejected`, `pair_denied`, or `pair_timeout`.
- `pair_result` failure closes the WebSocket; client should retry by opening a new connection.
- `session_replaced` means another connection took over the same deviceId. The server closes the old socket immediately after sending `session_replaced` and does not replay unacked messages from the old connection; the client must resend any pending messages after reconnect. Other devices that share the same `userId` stay active.
- `error` may include `messageId` for stream-specific failures.
- Rate limits: 5 messages/sec per device, 2 typing events/sec per device, 5 auth attempts/min per device, 5 pair requests/min per device. Pending pairing queue is capped; if full, `pair_request` returns `rate_limited`. On `rate_limited`, back off and show a subtle error.
- Canonical error codes (v1): `auth_failed`, `token_revoked`, `invalid_message`, `payload_too_large`, `not_found`, `rate_limited`, `session_replaced`, `upload_failed_retryable`, `server_error`.

## Mapping to iOS services

- `ConnectionServicing.requestPairing(...)` sends `pair_request` and awaits `pair_result`.
- `ConnectionServicing.incomingPairingRequests` delivers admin approval requests (admin devices only). After the device authenticates, this stream is driven by `ChatServicing`’s WebSocket.
- `ConnectionServicing.approvePairing(deviceId:userId:)` sends `pair_decision` with `approve: true` and explicit `userId`.
- `ConnectionServicing.denyPairing(deviceId:)` sends `pair_decision` with `approve: false` (no `reason` field in v1).
- `ChatServicing.connect(...)` opens WebSocket and sends `auth` with an auth replay context: `replayCursorsBySessionKey` plus compatibility `lastMessageId`.
- `ProviderChatService` owns per-stream replay cursor storage. Every fully processed finalized/replayable server event with an `s_*` ID and known session key MUST advance the cursor for that session key. Streaming partials update transient UI state but MUST NOT advance the persistent replay cursor.
- Lifecycle replay paths that apply finalized/replayable server events MUST advance `ProviderChatService`'s per-stream cursor map after apply; updating only a singular lifecycle/coordinator cursor is not sufficient.
- Cache restore may seed missing cursor keys only. It MUST NOT overwrite a cursor advanced by processed live/replay events in the current connection epoch.
- `streamReadStates` remains read/unread metadata and MUST NOT be used as replay cursor input.
- `ChatServicing.incomingMessages` yields `Message` objects as received (including streaming partials).
- `ChatServicing.incomingTyping` yields typing indicators for UI.
- `ChatServicing.send(content:sessionKey:attachments:)` sends `message` to the selected stream and performs upload if attachments include local files.
