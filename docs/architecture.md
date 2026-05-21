# Clawline Architecture

_Last updated: 2026-03-10_

This architecture summary is based on current code in:

- Provider/runtime: `/Users/mike/src/openclaw/src/clawline/`
- iOS client: `/Users/mike/src/clawline-dictation/ios/Clawline/Clawline/`

## System shape

Clawline is a provider + native iOS client:

- The **provider** (`server.ts` + supporting modules) runs HTTP and WebSocket endpoints, handles pairing/auth, persists events/assets/stream metadata, and dispatches agent replies.
- The **iOS app** (SwiftUI + service layer) handles pairing UX, authenticated chat sessions, stream management, attachments, and terminal bubble sessions.

## Routing and session model (implemented)

The runtime routes messages by **session key**, not by UI tab names.

- Canonical stream key format used by provider/iOS: `agent:<agentId>:clawline:<userId>:<streamSuffix>`
- Implemented stream suffixes in provider routing: `main`, `dm`, `global`, and custom `s_<8 hex>` (`routing.ts`, `server.ts`).
- A delivery-target helper also exists for compact user routing labels (`{userId}:{sessionLabel}`) (`routing.ts`).

On auth, provider sends stream/session provisioning (`auth_result` fields, `stream_snapshot`, and `session_info`). The iOS client stores stream metadata, tracks ordered stream keys, and gates sending against provisioned session keys (`ProviderChatService`, `ChatViewModel`).

## Primary runtime flow

1. **Pairing** over `/ws`: iOS sends `pair_request`; provider validates/rate-limits and resolves allowlist/pending/denylist (`ProviderConnectionService`, `server.ts`).
2. **Auth** over `/ws`: iOS sends JWT `auth`; provider verifies token + device + allowlist, registers session, then replays history (`ProviderChatService`, `server.ts`).
3. **Chat messaging**: iOS sends `message` with optional attachments and `sessionKey`; provider validates stream access, persists, broadcasts, and runs reply dispatch (`ChatViewModel`, `ProviderChatService`, `server.ts`).
4. **Stream mutation** via HTTP (`/api/streams`): iOS can list/create/rename/delete streams (`StreamAPIClient`, `server.ts`).
5. **Terminal bubbles** over `/ws/terminal`: separate auth/control channel for terminal session descriptors (`TerminalSessionService`, `server.ts`).

## Persistence and transport surfaces

Implemented provider surfaces include:

- WS: `/ws`, `/ws/terminal`
- HTTP: `/version`, `/upload`, `/download/:assetId`, `/api/streams`, `/api/session-status`, `/api/session-control`, `/alert`, `/surf-ace/events/*`, `/www/*`
- Local state: allowlist/pending/denylist JSON + SQLite event/message/asset/stream tables (`server.ts`)

## Session status and control API

The provider exposes a typed control-plane foundation for client-visible session mode/status and future controls:

- `GET /api/session-status?sessionKey=...` returns best-effort status such as busy/queued/running state, queue depth, model/provider/thinking metadata when available, and capability flags.
- `POST /api/session-control` accepts typed control actions. Unsupported mutations return structured unsupported responses; clients should not send slash-command text such as `/stop` or `/model` as normal chat messages.

See `specs/clawline-session-status-control-api.md` for requirements, capability model, safety constraints, and client integration guidance.

## Detailed docs

- `provider-architecture.md` — provider internals and request flow
- `ios-architecture.md` — iOS app/service/view model architecture
- `architecture/cross-chat-notification-overlay-design.html` — T307 notification overlay design for bubbles, docking, visible buttons, replies, hotkeys, and stack behavior
- `specs/clawline-session-status-control-api.md` — session status/control API requirements, capability model, safety constraints, and client integration guidance
