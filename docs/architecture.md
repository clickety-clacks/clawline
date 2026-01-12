# Clawline Architecture

## Overview

Clawline is a native mobile chat app for communicating with clawd assistants. It connects to a clawd process (the local agent runner that executes providers/plugins) running the "Clawline provider" plugin, so there is no gateway dependency.

## Normative scope

This document separates binding architectural/technology choices from guidance.

- **Normative requirements** are binding. They use uppercase MUST/SHOULD and are the committed architecture.
- Lowercase “must/should” call out guidance only.
- Sections explicitly labeled “(Normative)” extend the binding scope; everything else is guidance.

## Normative requirements

- The provider MUST be a clawd.me plugin (not a standalone service) and connect to clients directly without the gateway.
- Transport MUST be a WebSocket control plane plus HTTP media endpoints on the same host/port.
- v1 MUST NOT terminate TLS; operators are responsible for transport security if needed.
- The provider MUST bind to localhost by default; non-localhost bind MUST require `allowInsecurePublic: true`.
- The provider MUST support multiple devices per account: `userId` is the account, while each installation has its own `deviceId`. All devices for the same `userId` observe the same ordered server event stream (assistant output + echoed user messages) and may temporarily diverge while replay catches them up. Ordering is defined by a per-`userId` server-side sequence, not by the lexical order of event IDs.
- Operators MUST run at most one provider process per `statePath` (single-writer locking, no HA clustering in v1).
- Pairing + JWT auth MUST be required; clawd MUST remain the source of truth and clients SHOULD stay thin.
- Inline attachments MUST be small; large media/files MUST use upload + asset references stored on provider disk.
- Server keepalives MUST follow the WebSocket ping every 30s / timeout at 90s rules defined below; clients MUST treat the connection as dead after missing three server pings.
- The provider MUST persist allowlist/denylist/token state under `statePath` and MAY drop in-flight message queues on crash (documented durability trade-off).


### Rate limits (Normative)

The provider MUST enforce the configured rate limits for each category (defaults summarized below; `provider/README.md` is canonical):

- Pairing requests per `deviceId`
- Auth attempts per `deviceId`
- User `message` events per `deviceId`
- `typing` events per `deviceId`

Clients MUST treat `rate_limited` responses as backoff signals and retry later with the same payload.


### Default limits (Normative)

These defaults are summarized for v1 implementations. Operators MAY tune them (see `docs/provider-architecture.md`), but deviations MUST be called out in deployment docs. The canonical default list lives in `provider/README.md`.

| Lever | Default |
| --- | --- |
| Pairing requests per device | 5 per minute |
| Auth attempts per device | 5 per minute |
| User `message` events per device | 5 per second |
| `typing` events per device | 2 per second |
| Pending pairing TTL | 5 minutes |
| `maxReplayMessages` | 500 messages |
| `maxQueuedMessages` | 20 messages |

### Explicitly Not MVP (v1)

These items were considered and explicitly deferred as non‑MVP:
- Automatic pruning/quotas or tombstones.
- Automatic database recovery/migrations beyond fail‑fast on corruption.
- Stream resume across reconnects/restarts.
- Push notifications.
- TLS termination or built‑in reverse proxying.
- Multi‑connection grace windows (new connection replaces old immediately).


### Deployment model

- The provider assumes a single-writer deployment: exactly one provider process per `statePath`. Do not place `statePath` on network filesystems that do not honor POSIX advisory locks.
- Clients discover the provider via out-of-band configuration (operator specifies host/port); there is no automatic discovery in v1.
- Media bytes default to `~/.clawd/clawline-media` (configurable); treat this path as sensitive because it stores user attachments.
- Multiple devices that belong to the same account reuse the same `userId`. Replay cursors are tracked per `userId`, while rate limits and keepalives remain per `deviceId`.

### Multi-device policy (Normative)

- `userId` is the account identifier (a household/family). Each installation generates a stable `deviceId` (persisted in secure storage) so the provider can rate-limit, revoke, or replace specific devices without touching the account.
- Allowlist entries are keyed by `deviceId`. `claimedName` is a user-facing label only and MUST NOT determine identity. During approval an admin MUST explicitly choose which `userId` the device joins (pick an existing account or create a new UUIDv4 `userId`). Tooling SHOULD default to "new account" to avoid accidental merges.
- The provider maintains a per-`userId` monotonic event log. Every replayable event—user message echoes and assistant responses (streaming snapshots + final)—receives a server-generated `s_...` identifier. Ordering is based on the server’s sequence; the event ID is an opaque token that maps to that sequence. Typing is transient and not persisted.
- Clients MUST treat `lastMessageId` as "the most recent server event ID (prefixed `s_`) they have fully processed". On reconnect they include that value so the provider looks up its sequence and replays every later event in order.
- The provider MUST broadcast every server event to all connected devices for that `userId` and queue them for offline devices until they reconnect (bounded by `maxReplayMessages`). Delivery is per-device and therefore eventually consistent: faster devices may see events earlier, but ordering is identical once replay completes.
- Session management (keepalives, local send queue, retries) remains per `deviceId`. The provider MUST de-duplicate client sends using `(deviceId, clientMessageId)` so collisions between devices cannot corrupt the shared history.
- Revocation operates per device. Removing the final device for a `userId` leaves history intact but inaccessible until an operator reassigns a new device to that account.


## Related docs

- `docs/provider-architecture.md`
- `docs/provider-testing.md` (required provider test coverage)
- `docs/ios-architecture.md` (canonical iOS architecture spec)
- `docs/ios-provider-connection.md` (iOS <-> provider contract)

```
┌─────────────────┐     WebSocket      ┌─────────────────────┐
│   Clawline App  │◄──────────────────►│     clawd App       │
│      (iOS)      │                    │ (Clawline Provider) │
└─────────────────┘                    └──────────┬──────────┘
                                                  │
                                                  ▼
                                       ┌─────────────────────┐
                                       │   Claude / LLM API  │
                                       └─────────────────────┘
```

## Components

### 1. Clawline App (Client)

**Platforms:**
- iOS (Swift, SwiftUI)

**Responsibilities:**
- Present chat UI with native animations
- Manage WebSocket connection to provider
- Store authentication token securely (Keychain)
- Handle media attachments (images, documents)
- Display typing indicators

### 2. Clawline Provider (Server)

A provider plugin running inside clawd that:
- Listens on a WebSocket port
- Authenticates devices via signed tokens
- Routes messages to/from the clawd assistant
- Handles session management

**Connection options:**
- Local network / trusted network

Security note:
- The provider does not ship network security by default. Operators are responsible for securing transport (VPN/reverse proxy/firewall).
- Transport is intentionally plaintext (`ws://` + `http://`) in v1 to match clawd behavior. The provider does not terminate TLS.
- WARNING: bearer tokens are sent over the transport; do not expose the provider on untrusted networks without protection.
- By default the provider should bind only to localhost. Binding to non-localhost MUST fail fast unless `allowInsecurePublic: true` is explicitly set; when set, the provider logs a prominent warning on startup.

## Protocol

### WebSocket Messages

(Reminder: Transport is plaintext in v1—see Security note above for operational guidance.)

All messages are JSON with a `type` field:

WebSocket endpoint: `/ws`.
HTTP media endpoints (`/upload`, `/download/:assetId`) run on the same host/port as the WebSocket server.
Keepalive: rely on WebSocket ping/pong frames (not JSON messages). Server sends ping every 30s; client responds with pong. Client considers the connection dead after 90s without receiving a ping (three consecutive missed pings). Client does not send pings. Server closes the connection if no pong is received within 90s.
Clients MUST include `protocolVersion: 1` in `pair_request` and `auth`. Missing or unknown versions are rejected with `invalid_message`, and the server closes the connection.

Version discovery:
- `GET /version` returns protocol metadata (no auth required), e.g.:
  ```json
  {
    "protocolVersion": 1
  }
  ```

```typescript
// Client -> Server
type ClientMessage =
  | {
      type: "pair_request";
      protocolVersion: 1;
      deviceId: string;
      claimedName?: string;
      deviceInfo: { platform: string; model: string; osVersion?: string; appVersion?: string };
    }
  | { type: "pair_decision"; deviceId: string; approve: boolean; userId?: string }
  | { type: "auth"; protocolVersion: 1; token: string; deviceId: string; lastMessageId?: string | null }
  | { type: "message"; id: string; content: string; attachments?: Attachment[] }
  | { type: "typing"; active: boolean };

// Server -> Client
type ServerMessage =
  | {
      type: "pair_approval_request";
      deviceId: string;
      claimedName?: string;
      deviceInfo: { platform: string; model: string; osVersion?: string; appVersion?: string };
    }
  | { type: "pair_result"; success: boolean; token?: string; userId?: string; reason?: "pair_rejected" | "pair_denied" | "pair_timeout" }
  | { type: "auth_result"; success: true; userId: string; sessionId: string; replayCount: number; replayTruncated: boolean; historyReset?: boolean }
  | { type: "auth_result"; success: false; reason?: string }
  | { type: "ack"; id: string }
  | { type: "message"; id: string; role: "assistant" | "user"; content: string; timestamp: number; streaming: boolean; attachments?: Attachment[]; deviceId?: string }
  | { type: "typing"; role: "assistant"; active: boolean }
  | { type: "error"; code: string; message: string; messageId?: string };

// ServerMessage is the canonical event envelope; persisted events store the serialized ServerMessage JSON.

type Attachment =
  | { type: "image"; mimeType: string; data: string }
  | { type: "asset"; assetId: string };
```
The TypeScript-style definitions above are the canonical schema; JSON snippets that follow are illustrative examples only.

Pre-auth handling:
- Before `auth` succeeds, only `pair_request`, `pair_decision`, and `auth` are accepted.
- Any `message` or `typing` sent before auth returns `error` `auth_failed` and the server closes the connection.

### Message Types

#### Pairing
```json
// Client sends to request pairing
{
  "type": "pair_request",
  "protocolVersion": 1,
  "deviceId": "ABC123",
  "claimedName": "Kaywood",
  "deviceInfo": { "platform": "iOS", "model": "iPhone 15" }
}

// Server sends to admin devices for approval
{
  "type": "pair_approval_request",
  "deviceId": "ABC123",
  "claimedName": "Kaywood",
  "deviceInfo": { "platform": "iOS", "model": "iPhone 15" }
}

// Admin responds
{
  "type": "pair_decision",
  "deviceId": "ABC123",
  "approve": true,
  "userId": "user_4f1d2c7e-7c52-4f75-9f7a-2f7f9f2d9a3b"
}

// Server responds to requester
{
  "type": "pair_result",
  "success": true,
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "userId": "user_4f1d2c7e-7c52-4f75-9f7a-2f7f9f2d9a3b"
}

// Server responds to requester (denied)
{
  "type": "pair_result",
  "success": false,
  "reason": "pair_denied"
}
```
Pending `pair_request` expires after 5 minutes with `pair_result` `success: false` and `reason: pair_timeout`.
Admin denial uses `reason: pair_denied`; denylisted devices use `reason: pair_rejected`.
`deviceInfo.platform` and `deviceInfo.model` are required; missing fields return `invalid_message`.
`deviceId` MUST be a UUIDv4 string; invalid formats return `invalid_message`.
When `approve: true`, `pair_decision.userId` is required so the provider can attach the device to an existing account or a newly minted UUIDv4. When `approve: false`, `userId` MUST be omitted.
If no admins are connected, requests remain queued until an admin connects or the timeout expires. When an admin connects, the provider should emit `pair_approval_request` events for any pending requests still within TTL.

`pair_request` handling decision order (v1):
1. If `deviceId` is on the denylist → respond `pair_result` `success: false` `reason: pair_rejected`, then close.
2. If an allowlist entry exists for `deviceId`:
   - If `tokenDelivered` is false → treat as reconnect and re-issue `pair_result` success (preserve `isAdmin` flag).
   - Otherwise → respond with `error` `invalid_message`, then close.
3. If no admin devices exist → attempt first-admin bootstrap (atomic); on success, send `pair_result` success.
4. Otherwise → queue the request and send `pair_approval_request` to admins (now or when they connect).

Allowlist entry timing:
- When a request is approved, the provider creates the allowlist entry immediately with `tokenDelivered: false`. It flips to `true` only after `pair_result` is sent successfully.
- Allowlist entry schema (persisted under `statePath`):
  ```json
  {
    "deviceId": "d2f1c0d1-9a4b-4a92-9c6d-2c4e4c9f7b2a",
    "userId": "user_4f1d2c7e-7c52-4f75-9f7a-2f7f9f2d9a3b",
    "isAdmin": true,
    "tokenDelivered": false,
    "claimedName": "Kaywood",
    "deviceInfo": {
      "platform": "iOS",
      "model": "iPhone 15",
      "osVersion": "18.0",
      "appVersion": "1.0"
    }
  }
  ```
- Denylist entries reuse the same shape but live in a separate file/table and omit `tokenDelivered`.

Admin decision races:
- First `pair_decision` wins. Once a request is resolved, subsequent `pair_decision` messages for that `deviceId` return `error` `invalid_message` without closing the admin connection.
- The provider drops the pending request immediately after resolution; admins should remove the request from UI after sending a decision (no extra broadcast is required in v1).
- `pair_decision` for an unknown `deviceId` returns `error` `invalid_message` without closing the admin connection.

Pairing rate limits:
- Rate limit `pair_request` according to the configured per-device limit (optionally also per IP). Excess requests return `rate_limited` and the connection is closed.
- Cap pending pairing requests at the configured `maxPendingRequests` limit. If the queue is full, reject new `pair_request` with `rate_limited`.

On `pair_result` failure, the server closes the WebSocket; the client should open a new connection to retry.

Re-pairing policy:
- Re-pairing a device with an existing allowlist entry is blocked by design. If a token is lost, an operator MUST remove the allowlist entry (or revoke the device) to permit re-pairing.

Bootstrap behavior (v1):
- If no admin devices exist, the first `pair_request` is auto-approved and becomes an admin device.
- The provider MUST perform an atomic check-and-set so only one device can claim the first-admin slot.
- Implementation guidance: acquire an exclusive lock on the allowlist store (5s timeout per attempt), check for existing admins, then write the new admin entry in a single critical section. If the lock cannot be acquired, keep the request pending and retry lock acquisition every 500ms until TTL; if TTL expires, return `pair_timeout`.
- Deployment model: single provider instance per state directory. Do not run multiple providers against the same `statePath` (file locking assumes a local filesystem).
- Concurrent pair requests that lose the first-admin race are treated as normal pending requests (non-admin) and require admin approval.
- The first-admin device is identified by the `deviceId` written to the allowlist with `isAdmin: true`. A subsequent `pair_request` with that same `deviceId` is treated as a reconnect; any other `deviceId` is treated as a race loser.
- Operators should only start the provider when ready to pair the first device.
- If all admin devices are lost, operators can reset by deleting the provider state directory; this invalidates all tokens and re-enables first-admin bootstrap.
- As a less destructive alternative, operators may promote an existing allowlisted device by setting `isAdmin: true` in the allowlist (or via a future CLI), preserving message history.
- Admin status is stored in the allowlist (`isAdmin: true`) and included as a JWT claim for quick checks.
- Only admin devices may send `pair_decision`. Device revocation is an operator action outside the WebSocket protocol in v1 (no in-app revoke). Operators should preserve at least one admin device; when possible, the provider should reject revoking the last remaining admin.
- Admin promotion is not supported in v1. Only the first-admin bootstrap device is admin by default; operators may manually set `isAdmin: true` in the allowlist if additional admins are required.
- If a device's connection drops before receiving `pair_result`, the device may resend `pair_request` and the server should issue a new token (fresh JWT, preserving `isAdmin`).
- The provider should record `tokenDelivered` for the first-admin entry. A token is considered issued only after `pair_result` is successfully sent over the WebSocket.
- `tokenDelivered` defaults to `false`. If the server restarts and finds an admin entry with `tokenDelivered: false`, it MUST allow re-issuing the token to the same `deviceId`.

#### Authentication
```json
// Client sends on connect
{
  "type": "auth",
  "protocolVersion": 1,
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "deviceId": "ABC123",
  "lastMessageId": "s_abc123"
}

// Server responds
{
  "type": "auth_result",
  "success": true,
  "userId": "kaywood",
  "sessionId": "sess_xyz",
  "replayCount": 42,
  "replayTruncated": false
}

// Server responds (failure)
{
  "type": "auth_result",
  "success": false,
  "reason": "auth_failed"
}
```
Auth failure reasons use the same error code list (e.g., `auth_failed`, `token_revoked`).
`sessionId` is a per-connection identifier for diagnostics; clients may ignore it.
On auth failure, the server closes the WebSocket after sending `auth_result`. The client should open a new connection to retry after backoff.
On first connect after pairing, omit `lastMessageId` or set it to `null`; the server sends the most recent `maxReplayMessages`.
Reconnection backoff: exponential with jitter (start 1s, double each attempt, max 30s, add 0–1s random jitter). There is no max attempt limit; clients retry until the user cancels.
Rate limit auth attempts according to the configured per-device limit; excess attempts return `error` `rate_limited` and the server closes the connection.

After `auth_result` success, the server replays any missed messages after `lastMessageId` as normal `message` events, ordered oldest-to-newest:

- Message history is persisted to disk and survives provider restarts. v1 explicitly chooses no automatic pruning or quotas.
- If `lastMessageId` is unknown, replay sends the most recent `maxReplayMessages` overall (entire history, ordered oldest-to-newest).
- If `lastMessageId` points to an unfinished stream, replay starts from the next finalized message. If an unfinished stream appears with no final message, replay stops before that stream (partials are never replayed).
- The server drops duplicate message IDs during replay. Assets are deleted only when no remaining messages reference them.
- Replay is capped at the configured `maxReplayMessages`: if more than the cap are available after `lastMessageId`, replay the newest `maxReplayMessages` in that missing range and set `replayTruncated: true`. Messages beyond the cap are not replayed; this is a recent-only history window in v1.
`auth_result` includes `replayCount` (number of replay messages the server will send before live messages) and `replayTruncated` so clients can indicate history truncation. When the server cannot honor the provided `lastMessageId` and falls back to the most recent window, it MUST set `replayTruncated: true` and `historyReset: true` so clients know to discard any local conversation state beyond the replay window.
Replay phase begins immediately after `auth_result`; the provider sends replay messages first and does not interleave new live messages until replay completes. Queued user messages are processed only after replay completes. Clients can consider replay complete after receiving `replayCount` messages.
If `replayCount` is 0, replay ends immediately. If the connection drops before `replayCount` messages are received, the client reconnects with the last received message ID; the provider resumes replay from that point.
Configuration defaults and limits (e.g., `maxReplayMessages`) are summarized in the Default limits table above; `docs/provider-architecture.md` describes how to tune them. `provider/README.md` is illustrative.
#### Session takeover (normative)

- If the same `deviceId` authenticates again, the new connection wins. The server sends `error` `session_replaced` to the old connection and closes it immediately.
- The server MUST send `auth_result` on the new connection before terminating the old connection. If the new connection fails before auth completes, keep the old connection alive.
- If two connections authenticate concurrently for the same `deviceId` when there is no established session yet, the first `auth` message received by the server wins; the other connection receives `session_replaced` after its `auth_result`.
- Assistant responses (including active streams) after the new connection authenticates MUST route only to the new connection; the old connection stops receiving assistant output.
- Any messages from the old connection after `session_replaced` are ignored. Unacked messages from the old connection are treated as not received; the server does not replay them and the client MUST resend after reconnect.

#### Chat Messages
```json
// Client -> Server (user message)
{
  "type": "message",
  "id": "c_123",
  "content": "Hello CLU!",
  "attachments": []
}

// Server -> Client (ack of receipt)
{
  "type": "ack",
  "id": "c_123"
}

// Server -> Client (assistant response)
{
  "type": "message",
  "id": "s_456",
  "role": "assistant",
  "content": "Hey! What's up?",
  "timestamp": 1704672000000,
  "streaming": false
}

// Streaming variant (same message id, full content so far)
{
  "type": "message",
  "id": "s_456",
  "role": "assistant",
  "content": "Hey",
  "timestamp": 1704672000000,
  "streaming": true
}
```
Note: client messages have implicit role "user".
Server rate limits inbound `message` events to the configured per-device throughput; excess messages are rejected with `rate_limited`.
Server assigns `timestamp` (Unix epoch ms) on all server-sent `message` events.
Max `content` length is 64KB UTF-8; exceeding this returns `payload_too_large`.
Clients should merge streaming messages by `id` and treat the final message with `streaming: false` as authoritative.
Delta encoding is not supported in v1; streaming updates always send full content so far to keep client logic simple (blind overwrite, no diff merge).
Server sends `ack` immediately upon accepting a user message. If no `ack` is received within 5 seconds, the client may retry by resending the same message `id`.
Clients MUST track pending message IDs awaiting `ack` and resend them after reconnect if no `ack` was received.
For crash safety, clients should persist pending message IDs to disk before sending, so they can be resent after a process restart.
The provider MUST record message receipt (id + content hash) before sending `ack`, and MUST treat any later duplicate with the same `id` as an idempotent retry (no double generation), even if the original `ack` was lost.
##### Message queue and durability (normative)

- There MUST be at most one assistant stream active per `deviceId`; additional user messages are queued FIFO (shared across any concurrent connections for that device) and processed sequentially after the current stream finishes.
- The queue is in-memory (not persisted), bounded by the configured `maxQueuedMessages`. If the queue is full, the provider MUST reject new messages with `rate_limited`; clients SHOULD back off and retry with the same message `id`.
- Queued messages persist across session replacement but are dropped when no active connection remains (or on provider crash); clients MUST resend all unacked messages after reconnect. This is an intentional v1 durability trade-off (simplicity over guaranteed delivery).
- Message loss across simultaneous client/provider crashes is acceptable in v1; clients SHOULD persist outgoing messages and retry.
##### Streaming semantics

- If the connection drops mid-stream, the client keeps the partial content but marks it incomplete. The provider never replays partials and never resumes streams across reconnects/restarts. Clients MUST discard any incomplete streaming message and retry with a new `id`.
- Provider does not persist partial streams across restarts. If the server crashes mid-stream, the client SHOULD resend the original message with a new `id` to retry generation (fresh generation, no resume).
- Stream finalized while disconnected: replay the final message (no resume needed).
If the LLM fails mid-stream, the provider sends `error` with `code: server_error` and includes `messageId` for the failed stream; no final `message` is sent.
Client message IDs MUST start with `c_`. Server-assigned message IDs MUST start with `s_`. Any other prefix should be rejected as `invalid_message`. If a client `message` is missing an `id`, reject with `invalid_message` (no auto-assign). Duplicate handling rules:

- The server persists a content hash per `id` (SHA-256 of UTF-8 `content`, hex-encoded). If a duplicate `id` arrives with different `content` while a record exists, reject with `invalid_message`.
- If a record exists with matching content, treat the retry as idempotent: resend `ack`, do not double-generate. If the record is marked failed, return `invalid_message` and require a new `id`.
- If no record exists, treat the retry as a fresh generation.

Client message IDs are scoped per `deviceId`; the server namespaces lookups by `deviceId`. Clients SHOULD generate UUIDv4 IDs with the `c_` prefix to avoid collisions and MUST never intentionally reuse an `id`. Server-assigned `s_` IDs are globally unique (UUIDv4 with `s_` prefix). Pairing/auth messages do not have `id` fields. Client `message` payloads have implicit `role: user`.
Cancellation: v1 does not support canceling assistant responses. If a client sends a cancel request, the server returns `invalid_message`.

#### Typing Indicators
```json
// Client typing
{ "type": "typing", "active": true }

// Server (assistant processing)
{ "type": "typing", "role": "assistant", "active": true }
```
Server auto-clears `typing: true` after 10 seconds of inactivity (no new typing or message events).
Client typing implies `role: user`.
Typing events are rate limited according to the configured per-device typing limit; excess events return `rate_limited`.

#### Errors
```json
{
  "type": "error",
  "code": "auth_failed",
  "message": "Token revoked",
  "messageId": "s_456"
}
```
Errors do not close the connection unless explicitly stated. The following errors close the connection: `auth_failed`, `token_revoked`, `session_replaced`, and `invalid_message` in the protocolVersion/allowlist-violation cases described above.
Malformed JSON (parse failure) closes the connection. Structurally valid JSON with invalid fields returns `error` `invalid_message` without closing.
`messageId` is optional and is included for message-specific failures (e.g., stream errors).
Error codes (v1):
- `auth_failed`
- `token_revoked`
- `invalid_message`
- `payload_too_large`
- `asset_not_found`
- `rate_limited`
- `session_replaced`
- `upload_failed_retryable`
- `server_error`

`pair_result` reasons:

| Reason | Meaning |
| --- | --- |
| `pair_rejected` | Device is on the denylist |
| `pair_denied` | Admin explicitly declined the request |
| `pair_timeout` | Pending request exceeded the 5-minute TTL |

Error/HTTP mapping:

| Code | HTTP status (if over HTTP) | Connection closed? | Client action |
| --- | --- | --- | --- |
| `auth_failed` | 401 | Yes | Re-authenticate / re-pair |
| `token_revoked` | 403 | Yes | Re-pair |
| `invalid_message` | 400 | Sometimes (see text) | Fix payload and retry |
| `payload_too_large` | 413 | No | Reduce payload size |
| `asset_not_found` | 404 | No | Re-upload/re-attach |
| `rate_limited` | 429 | No | Back off and retry |
| `session_replaced` | n/a | Yes (immediately) | Drop old connection |
| `upload_failed_retryable` | 503 | No | Retry upload |
| `server_error` | 500 | No | Retry / surface error |

## Security

### Pairing Flow (First Connection)

1. User opens Clawline for first time
2. App generates unique deviceId (UUIDv4 string, stable across app launches; persist in Keychain when possible to survive reinstalls), connects to provider. If the deviceId changes (e.g., Keychain wiped), the app MUST re-pair; the previous deviceId remains valid until revoked.
3. App sends pairing request with claimed user name:
   ```json
   {
     "type": "pair_request",
     "protocolVersion": 1,
     "deviceId": "ABC123",
     "claimedName": "Kaywood",
     "deviceInfo": { "platform": "iOS", "model": "iPhone 15" }
   }
   ```
  - If no admin devices exist yet, this first request is auto-approved and marked as admin (provider MUST enforce an atomic first-admin claim).
4. Provider sends `pair_approval_request` to all connected admin devices (and delivers any pending requests to an admin on connect).
5. Admin approves in-app -> Provider issues signed JWT token
6. App receives and stores token:
   ```json
   {
     "type": "pair_result",
     "success": true,
     "token": "eyJhbGciOiJIUzI1NiIs...",
     "userId": "kaywood"
   }
   ```

### Token Format (JWT)

```json
{
  "sub": "user_4f1d2c7e-7c52-4f75-9f7a-2f7f9f2d9a3b",
  "deviceId": "d2f1c0d1-9a4b-4a92-9c6d-2c4e4c9f7b2a",
  "isAdmin": false,
  "iat": 1704672000,
  "exp": 1736208000
}
```

- Signed with provider secret
- JWT signing algorithm: HS256 (HMAC-SHA256) with the provider secret.
- HS256 keeps the signing implementation simple for an in-process plugin; if future components outside the provider need to validate tokens, migrate to RS256/ES256 to avoid sharing the secret.
- `sub` (`userId`) is server-assigned (UUIDv4). Clients MUST treat `userId` as opaque. In v1 there is no admin rename flow.
- `deviceId` claim MUST be a UUIDv4 string and MUST match the `auth.deviceId` value.
- `isAdmin` in the JWT is informational; the provider MUST verify admin status against the allowlist on privileged actions.
- Tokens expire after `tokenTtlSeconds` (default 1 year). V1 has no refresh flow; expired tokens require re-pairing. Operators may set `tokenTtlSeconds: null` to disable expiry (omit the `exp` claim).
- Operators should periodically rotate the provider secret (e.g., every 90 days) to limit token lifetime; rotation invalidates all tokens.
- Because transport is plaintext in v1, operators MUST deploy the provider only on trusted networks (VPN, localhost, or reverse proxy) or accept the risk of bearer token interception.
- Revocable by operator action (CLI or config edit)
- Revocation list is persisted in the provider state directory as a JSON file and checked on every `auth`.
- The provider MUST detect revocation changes for active sessions (file watch or 5s polling) and close any session whose `deviceId` is revoked.
- Provider state directory default: `~/.clawd/clawline/` (configurable; see `docs/provider-architecture.md`).
- If a token is revoked while a session is active, the provider closes that session immediately.
- Any in-flight stream for a revoked session is aborted and no final message is emitted.
- Any queued messages for the revoked device are dropped.
- If the provider secret is compromised or the revocation list is lost, operators should delete the provider state directory to rotate the secret and invalidate all tokens.
- Revocation targets `deviceId` entries. The `jti` claim is reserved for future use.
- Revoked `deviceId`s are stored in a denylist. Operators may remove entries to allow re-pairing.
- Revocation is an operator action outside the WebSocket protocol in v1 (e.g., CLI or config file change). There is no in-app revocation UI in v1; operators should provide a simple out-of-band revoke mechanism (edit denylist JSON or CLI wrapper).

### Subsequent Connections

1. App presents stored token on connect
2. Provider validates signature and checks revocation list
3. If valid -> session established, user identity known
4. If invalid/revoked -> auth error, app clears token, prompts re-pair

## Media Handling

### Attachments (Client -> Server)

```json
{
  "type": "message",
  "content": "Check out this photo",
  "attachments": [
    {
      "type": "image",
      "mimeType": "image/jpeg",
      "data": "<base64>"
    }
  ]
}
```
Inline attachments MUST be <= 256KB raw bytes. Base64 adds ~33% overhead. Larger files MUST use /upload (otherwise `payload_too_large`).
Max inline attachments per message: 4. Total inline attachment bytes per message MUST be <= 256KB. Total message payload (content bytes + inline attachment bytes) MUST be <= 320KB. Allowed inline image types: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`.
Inline attachments are only for image payloads; non-image files MUST be uploaded via `/upload` and referenced as `asset`. Allowed inline `mimeType` values: `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`.
Assistant responses may include `attachments` as either inline images or `asset` references; clients MUST handle downloading `asset` attachments.


### Large File Upload (v1)

1. Client uploads via HTTP `POST /upload` (auth required, multipart). Use `Authorization: Bearer <token>`. Max upload size is 100MB. Multipart field name: `file`.
2. Server responds with asset metadata:
   ```json
   { "assetId": "asset_123", "mimeType": "image/png", "size": 5242880 }
   ```
3. Client sends a chat message that references the asset:
   ```json
   {
     "type": "message",
     "content": "Here is the file",
     "attachments": [{ "type": "asset", "assetId": "asset_123" }]
   }
   ```
4. Client downloads via HTTP `GET /download/:assetId` (auth required). Use `Authorization: Bearer <token>`.
Asset IDs are unguessable; any authenticated device may download any asset in v1 (no per-device ACLs).
Security note: because asset download auth is device-scoped (not per-message), operators MUST deploy in environments where all authenticated devices are trusted (e.g., a single household).

Unreferenced uploads (assets that are never attached to a message) are deleted after 1 hour.
Assets referenced by partial/in-progress messages are treated as referenced until the stream finalizes or fails; if no streaming `message` updates occur for 5 minutes, the stream is considered failed and the asset becomes unreferenced (1-hour TTL applies).
Unreferenced uploads remain attachable by the same device while within the TTL.

HTTP error responses return JSON matching the `error` schema:
- Missing or malformed `Authorization` header, or invalid token signature → `401` `auth_failed`.
- Revoked token → `403` `token_revoked`.
- `400` → `invalid_message`
- `401` → `auth_failed`
- `403` → `token_revoked`
- `404` → `asset_not_found`
- `413` → `payload_too_large`
- `429` → `rate_limited`
- `503` → `upload_failed_retryable`
- `500` → `server_error`

## Open Questions

- [ ] Push notification infrastructure (APNs, FCM)
- [ ] End-to-end encryption (stretch goal)

---

*Last updated: 2026-01-07*
