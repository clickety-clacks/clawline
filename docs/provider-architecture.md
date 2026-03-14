# Clawline Provider Architecture

_Last updated: 2026-03-10_

Source of truth: `/Users/mike/src/openclaw/src/clawline/`

## Runtime entrypoint

`server.ts` exports `createProviderServer(options)` and composes the provider runtime:

- HTTP server (optionally TLS via gateway TLS runtime)
- WebSocket servers for `/ws` and `/ws/terminal`
- allowlist/pending/denylist state files
- SQLite-backed message/event/asset/stream persistence
- reply dispatch integration into OpenClaw auto-reply flow

## Core components

- `server.ts`: protocol handling, auth/pairing, replay, stream APIs, broadcast, agent dispatch, terminal channel
- `routing.ts`: `ClawlineDeliveryTarget` parsing and mapping between delivery labels and session keys
- `session-store.ts`: records active session metadata into OpenClaw session store
- `attachments.ts`, `http-assets.ts`: attachment normalization/materialization, upload/download plumbing
- `surf-ace.ts`: SurfAce manager lifecycle + callback event handling

## Session and stream routing (implemented)

Provider session state tracks per socket:

- default session key (`session.sessionKey`)
- subscribed/provisioned stream keys (`sessionKeys`, `provisionedSessionKeys`)
- personal main/dm/global keys and admin scope

Implemented stream behaviors in `server.ts`:

- stream seeding per user (`main`, `dm`, optional global for admin)
- custom stream creation/deletion with `s_<8 hex>` suffixes
- stream access filtering for non-admin vs admin
- stream subscription sync across active user sessions
- stream mutation idempotency for create/delete operations

Inbound `message` handling resolves and validates `payload.sessionKey` against provisioned keys, persists user events, broadcasts by session key, and dispatches agent reply generation.

## Auth and pairing flow

WebSocket `/ws` message types:

- `pair_request` → validates protocol/device/device info, applies rate limits, checks denylist/allowlist, and manages pending approvals
- `auth` → verifies JWT + deviceId + user mapping, rejects revoked/pending devices, registers session, sends replay + stream/session info
- `message` and `interactive-callback` for authenticated clients

Pairing/admin state is file-backed (`allowlist.json`, `pending.json`, `denylist.json`) with file watchers for runtime refresh.

## Replay, delivery, and persistence

- Replay uses `lastMessageId` anchor when present and normalizes stored routing keys before send.
- Outbound broadcast fanout is keyed by `sessionKey` and only sent to sockets subscribed to that key.
- Event/message persistence uses SQLite statements/transactions initialized in `server.ts`.
- Stream APIs are HTTP-authenticated endpoints under `/api/streams` (GET/POST/PATCH/DELETE).

## Exposed transport endpoints

- HTTP: `/version`, `/upload`, `/download/:assetId`, `/api/streams`, `/alert`, `/surf-ace/events/*`, `/www/*`
- WS: `/ws`
- Terminal WS: `/ws/terminal`

## Terminal sessions

Terminal sessions are represented as document attachments with MIME `application/vnd.clawline.terminal-session+json`. The provider tracks terminal session records, validates ownership on terminal auth, and bridges socket I/O to tmux (local or SSH mode) in `server.ts`.