# Clawline iOS Architecture

_Last updated: 2026-03-10_

Source of truth: `/Users/mike/src/clawline-dictation/ios/Clawline/Clawline/`

## App composition

`ClawlineApp.swift` composes runtime dependencies at launch:

- auth/session state: `AuthManager`
- pairing/chat transport: `ProviderConnectionService`, `ProviderChatService`
- media transport: `UploadService`
- UI state: `SettingsManager`, root/chat/pairing views

The app is SwiftUI-based with service protocols (`Protocols/*`) and concrete provider implementations (`Services/*`).

## Network/service layer

Implemented provider-facing services:

- `ProviderConnectionService`: pairing socket flow (`pair_request`) and pending approval handling
- `ProviderChatService`: authenticated `/ws` chat connection, auth handshake, message send/retry-until-ack, inbound event decoding
- `StreamAPIClient`: HTTP stream CRUD against `/api/streams`
- `UploadService`: `/upload` and `/download/:assetId` for attachment transfer
- `TerminalSessionService`: separate `/ws/terminal` channel for terminal session auth + bidirectional terminal I/O

## Session/stream model on iOS

Key models:

- `StreamSession`: server stream metadata (`sessionKey`, `kind`, ordering, built-in flags)
- `SessionRegistry`: thread-safe in-memory lookup of stream metadata by session key
- `SessionKey`: canonical helpers for Clawline key forms
- `ProviderWireModels`: wire payload codables for auth/message/stream events

`ProviderChatService` consumes `auth_result`, `session_info`, and stream events (`stream_snapshot`, `stream_created`, `stream_updated`, `stream_deleted`) and emits `ChatServiceEvent`s.

## Chat state and UX orchestration

`ChatViewModel` is the central state machine for chat runtime:

- maintains per-session message stores and read/unread cursors
- tracks stream ordering + active stream selection
- uses split stream-switch state (`uiSelectedSessionKey` vs `engineActiveSessionKey`) to debounce heavy activation work
- gates send behavior on provisioned session availability from provider session events
- handles reconnect/backoff, pending local message replacement, message cache restore/persist, and stream CRUD UI actions

## Routing behavior (implemented)

Outbound sends include `sessionKey` (when available), and inbound messages are keyed by provider-supplied `sessionKey`. The UI stores data per session key and only treats stream names as display metadata.

This matches provider-side routing by canonical session key and supports multiple user streams (`main`, `dm`, custom streams) plus admin/global streams when provisioned.