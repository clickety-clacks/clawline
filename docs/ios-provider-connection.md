# iOS Connection Guide: Clawline Provider

## Purpose

Describe how the iOS client (Clawline) connects to the clawd.me provider plugin, including pairing, authenticated chat, streaming messages, large media/file transfers, and keeping multiple devices for the same user in sync. This is aligned with `docs/architecture.md` and `docs/ios-architecture.md`.

## Interpretation

This guide is the client-side contract. Statements using MUST/SHOULD are binding; other explanatory text is guidance. Architectural choices live in `docs/architecture.md`.

## Client roles (per iOS architecture)

From `docs/ios-architecture.md` and `COMMON.md`:
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
- `pair_approval_request` schema (from `docs/architecture.md`):
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

`pair_result` responses follow `docs/architecture.md`: success payload `{ success:true, token, userId }`; failure payload `{ success:false, reason: "pair_rejected" | "pair_denied" | "pair_timeout" }`.

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
     "lastMessageId": "s_789"
   }
   ```
   Use the most recent server event ID (`s_*`) processed on this device; omit the field or send `null` on first auth after pairing (or if no server events have ever been processed on this device).
3. Provider responds with:
   ```json
   {
     "type": "auth_result",
     "success": true,
     "userId": "user_...",
     "sessionId": "sess_...",
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
5. On success, provider replays missed events (if any) after `lastMessageId`. `lastMessageId` MUST be the most recent server event ID (`s_*`) that this device fully processed (assistant output, echoed user message, typing, etc.). Every device tied to the same `userId` eventually observes the same ordered history, although individual sockets may lag until replay completes.
   - Admin detection: `AuthManaging` must expose the decoded JWT claims so the UI can read the `isAdmin` boolean (present in the token per `docs/architecture.md`). Only admins subscribe to and display `pair_approval_request`s.
6. Use `auth_result.replayCount`, `auth_result.replayTruncated`, and `auth_result.historyReset` to show a "history truncated/reset" notice when needed. When `historyReset` is true, drop any local conversation state beyond what replay delivered.
Clients must include `protocolVersion: 1` in `pair_request` and `auth` or the provider will reject the request with `error` `invalid_message` and close the socket.
The client may call `GET /version` (no auth) to verify `protocolVersion: 1` before attempting a connection. If the server responds with a different version, fail fast and show an update-required UI. Response schema:
```json
{ "protocolVersion": 1 }
```

### 3) Reconnect

- On socket loss, attempt reconnect with exponential backoff (start 1s, double each attempt, max 30s, add 0–1s random jitter).
- Use a short initial connection timeout (e.g., 10 seconds) before entering backoff.
- Re-auth with stored token (per device).
- Include `lastMessageId` (server `s_*` id) in the auth payload so the server can replay missed messages for that device while also keeping other devices for the user in sync.
- Client should deduplicate replayed events by `id`. Any event with an `id` the device already processed MUST be ignored (idempotent apply).
- Keepalive: server sends WebSocket ping control frames every 30s; client responds with pong. If no ping is received for 90s, treat the connection as dead and reconnect.

## Chat message flow

### Send (client -> provider)
```json
{
  "type": "message",
  "id": "c_123",
  "content": "Hello",
  "attachments": []
}
```
Client message IDs must start with `c_`; server-assigned events use `s_<uuid>`. The server uses a per-`userId` sequence internally for ordering; clients treat `s_*` as opaque cursors.
Max `content` length is 64KB UTF-8; longer payloads return `payload_too_large`.
Invalid message ID prefixes are rejected with `invalid_message`.
Duplicate client message IDs are treated as idempotent retries per device. Client message IDs are scoped to a single `deviceId`; two devices may use the same `c_*` values without conflict. Replay dedup uses server event IDs (`s_*`), not client IDs. Clients must reuse the same `id` for network/ack retries (before `ack`) and never change the `content` for an existing `id` (if content differs, the server returns `invalid_message`). If a stream fails or completes without a final assistant message after `ack`, retry with a new `id`.
After the provider accepts a user message, it echoes a server event (new `s_<uuid>` id with `role: "user"`) back to every device on the account—including the sender—so all devices append the same representation to their local timeline. The server includes the originating `deviceId` in the echoed payload for attribution.
Echoed user message schema (server -> client):
```json
{
  "type": "message",
  "id": "s_789",
  "role": "user",
  "content": "Hello",
  "timestamp": 1704672000000,
  "streaming": false,
  "deviceId": "ABC123",
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
{ "type": "message", "id": "s_456", "role": "assistant", "content": "Hi", "timestamp": 1704672000000, "streaming": false }
```

Streaming (partial messages):
```json
{ "type": "message", "id": "s_456", "role": "assistant", "content": "Hi there", "timestamp": 1704672000000, "streaming": true }
```

Assistant messages may include `attachments`. Inline attachments (`type: "image"`) contain base64 data; asset attachments (`type: "asset"`) require a follow-up `GET /download/:assetId`.

Client behavior:
- Optimistically append user messages but track them by outgoing `c_*` id (e.g., `pendingMessages[c_id]`). When the server echoes the message with `role: "user"` and `deviceId` matching the local device, replace the optimistic entry with the echoed one (remove it from `pendingMessages`). Echoes from other devices are appended normally.
- `ChatServicing` yields streaming messages as received (same `id`, `streaming: true`).
- ViewModel merges assistant messages by `id` and toggles `isStreaming` to false when the final message arrives.
- Reconnect outcomes (per device):
  - Stream still active when disconnect happens: v1 cancels the stream when the originating socket closes; no resume occurs. The originating device surfaces a retry affordance, and sibling devices will observe a missing assistant message (same missing-final detection flow).
  - Stream finalized while disconnected: provider replays the final message (all devices see the same final response).
  - Stream inactive with no final message (no updates for 5 minutes): treat it as failed and retry with a new `id`. The server does not replay partials, so failure is detected by missing-final logic on reconnect.
  - Missing-final detection (client requirement): after replay, if a user echo has no corresponding assistant final message and no active stream, treat it as failed and surface a retry affordance. Example heuristic: if the latest user echo `s_*` has no subsequent assistant `s_*` and there is no streaming message for its `id`, mark it failed.

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

## Errors & status codes

- WebSocket `error.code` values come from `docs/architecture.md` (`auth_failed`, `token_revoked`, `invalid_message`, `payload_too_large`, `asset_not_found`, `rate_limited`, `session_replaced`, `upload_failed_retryable`, `server_error`). Display them or map to user-friendly text.
- `auth_result.reason` values include `auth_failed`, `token_revoked`, `device_not_approved`, and `token_expired`. Treat `token_expired`/`auth_failed` as “clear token and restart pairing.”
- For `device_not_approved`, keep the device on the “Awaiting approval” screen, retry pairing automatically every ~30s, and notify the user that an admin must approve.
- HTTP uploads/downloads return JSON errors with HTTP statuses: 400 (`invalid_message`), 401 (`auth_failed`), 403 (`token_revoked`), 404 (`asset_not_found`), 413 (`payload_too_large`), 429 (`rate_limited`), 503 (`upload_failed_retryable`), 500 (`server_error`). Treat 401/403 as token failures (clear token).
- `session_replaced` is terminal: the old socket closes immediately when another connection authenticates. UI should show “connected elsewhere” and prompt the user to continue on the new device; do not auto-reconnect until the user explicitly chooses to, to avoid kicking the new session.
- Provider URL configuration: v1 requires users to enter the provider’s base URL or IP manually in Settings. There is no discovery protocol; the app stores this value securely (Keychain/UserDefaults) and reuses it until the user edits it.

### Rate limits (client behavior)

| Action | Limit | Client response |
| --- | --- | --- |
| `pair_request` | 5/min per `deviceId` | Show “Too many attempts” toast, retry with exponential backoff |
| `auth` | 5/min per `deviceId` | Clear token on repeated failure, return to pairing |
| `message` send | 5/sec per `deviceId` | Queue locally, retry after 200–500 ms |
| `typing` send | 2/sec per `deviceId` | Drop extra typing updates; rely on auto-expire |
| Oversize payloads | 3 violations within 60s closes socket | Warn user and throttle UI |

## Media and file transfer

Two tiers: inline for small attachments (<= 256KB raw bytes; base64 adds ~33% overhead—expect ~341KB JSON payloads), out-of-band for large files.
HTTP upload/download uses the same host/port as the WebSocket endpoint. The provider enforces the raw byte limit before encoding, so clients should reject larger files locally. Max upload size is 100MB in v1.

### Inline attachments (small)
```json
{
  "type": "message",
  "content": "Check this",
  "attachments": [
    { "type": "image", "mimeType": "image/jpeg", "data": "<base64>" }
  ]
}
```

### Large file upload (v1)

1) Upload via HTTP `POST /upload` (auth required, multipart, field name `file`). Use `Authorization: Bearer <token>`. Response is `application/json`.

2) Provider responds with asset metadata:
```json
{
  "assetId": "asset_1",
  "mimeType": "image/png",
  "size": 5242880
}
```
   v1 does not include filename, checksum, or expiry in the response.

3) Send a message referencing the asset:
```json
{
  "type": "message",
  "content": "Here is the file",
  "attachments": [{ "type": "asset", "assetId": "asset_1" }]
}
```

### Download
- Client downloads via HTTP `GET /download/:assetId` (auth required). Use `Authorization: Bearer <token>`. Response content-type is the stored `mimeType` and body is raw bytes.

## Error handling

Error schema (from `docs/architecture.md`):
```json
{ "type": "error", "code": "invalid_message", "message": "Details", "messageId": "c_123" }
```
`messageId` is optional and only present for message-specific failures (e.g., stream errors).

- `auth_result` failure: clear token and return to pairing.
- `error` messages: display inline banner and keep connection alive.
- Upload errors: show retry action.
- `upload_failed_retryable` means the client should retry the upload.
- HTTP status codes for upload/download follow `docs/architecture.md`.
- `pair_result` failure reasons include `pair_rejected`, `pair_denied`, or `pair_timeout`.
- `pair_result` failure closes the WebSocket; client should retry by opening a new connection.
- `session_replaced` means another connection took over the same deviceId. The server closes the old socket immediately after sending `session_replaced` and does not replay unacked messages from the old connection; the client must resend any pending messages after reconnect. Other devices that share the same `userId` stay active.
- `error` may include `messageId` for stream-specific failures.
- Rate limits: 5 messages/sec per device, 2 typing events/sec per device, 5 auth attempts/min per device, 5 pair requests/min per device. Pending pairing queue is capped; if full, `pair_request` returns `rate_limited`. On `rate_limited`, back off and show a subtle error.
- Canonical error codes (v1): `auth_failed`, `token_revoked`, `invalid_message`, `payload_too_large`, `asset_not_found`, `rate_limited`, `session_replaced`, `upload_failed_retryable`, `server_error`.

## Mapping to iOS services

- `ConnectionServicing.requestPairing(...)` sends `pair_request` and awaits `pair_result`.
- `ConnectionServicing.incomingPairingRequests` delivers admin approval requests (admin devices only). After the device authenticates, this stream is driven by `ChatServicing`’s WebSocket.
- `ConnectionServicing.approvePairing(deviceId:userId:)` sends `pair_decision` with `approve: true` and explicit `userId`.
- `ConnectionServicing.denyPairing(deviceId:)` sends `pair_decision` with `approve: false` (no `reason` field in v1).
- `ChatServicing.connect(token:lastMessageId:)` opens WebSocket and sends `auth`.
- `ChatServicing.incomingMessages` yields `Message` objects as received (including streaming partials).
- `ChatServicing.incomingTyping` yields typing indicators for UI.
- `ChatServicing.send(content:attachments:)` sends `message` and performs upload if attachments include local files.
