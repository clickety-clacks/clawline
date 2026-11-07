# iOS Session Key Migration Plan (Clawline)

References:
- `docs/architecture.md` (Clawdbot Channel Mapping)
- `docs/ios-provider-connection.md` (Session routing)

## Summary
Move iOS routing to `sessionKey` as the sole routing identifier.
Session keys:
- DM: `agent:main:main`
- Personal: `agent:main:clawline:{userId}:main`

The client should send/receive `sessionKey` and route UI streams by that value.

Notes on spec alignment:
- `docs/architecture.md` uses `USER` in examples (e.g., `sample-owner`), while `docs/ios-provider-connection.md` uses `{userId}`. Confirm with server whether this is the user-facing handle or the auth `userId` UUID before implementing.
- The canonical wire protocol uses `role` (not `sender`) for message attribution.
- Typing events are shaped as `{ "type": "typing", "active": true }` (client) and `{ "type": "typing", "role": "assistant", "active": true }` (provider).

## Current iOS state (high level)
- Messages are routed by `ChatChannelType` (`personal` / `admin`) and UI shows two streams using `activeChannel`.
- `ClientMessagePayload` includes `channelType` (legacy).

## Required code changes

### Wire models
Files:
- `ios/Clawline/Clawline/Models/ProviderWireModels.swift`

Changes:
- Add `sessionKey: String` to `ClientMessagePayload` and `ServerMessagePayload`.
- Encode `sessionKey` on outbound messages.
- Decode `sessionKey` on inbound messages.
- Prefer `sessionKey` if present.

### Message model
File:
- `ios/Clawline/Clawline/Models/Message.swift`

Changes:
- Add `sessionKey: String` to `Message`.
- Remove `channelType` once session-key routing is fully deployed.

### Chat routing / view model
File:
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`

Changes:
- Replace `activeChannel: ChatChannelType` with `activeSessionKey: String` (or map helper).
- Store messages by session key (`[String: [Message]]`) instead of by channel.
- When sending, compute `sessionKey` from:
  - DM: `agent:main:main` (admins only)
  - Personal: `agent:main:clawline:{userId}:main`
- On receive, route by `message.sessionKey`.

### UI / channel switching
Files:
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
- `ios/Clawline/Clawline/Views/Chat/ChannelSwitcherView.swift`
- `ios/Clawline/Clawline/Views/Chat/ChannelToast.swift`

Changes:
- Update TabView binding to session keys (or keep two tabs but mapped to keys).
- Labels remain “DM” / “Personal” but selection uses sessionKey strings.

### Provider chat service
File:
- `ios/Clawline/Clawline/Services/ProviderChatService.swift`

Changes:
- Outbound: include `sessionKey` in `ClientMessagePayload`.
- Inbound: log/propagate `sessionKey` from payload.

### Auth / user id
File:
- `ios/Clawline/Clawline/Services/AuthManager.swift`

Changes:
- Ensure `userId` is available for composing personal session key.
- If missing, block send with a clear error.

### Typing events
Files:
- `ios/Clawline/Clawline/Services/ProviderChatService.swift`
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`

Changes:
- Handle typing events in the canonical shape:
  - Client: `{ "type": "typing", "active": true }` (no role).
  - Provider: `{ "type": "typing", "role": "assistant", "active": true }`.
- Route incoming typing indicators to the active session until typing events carry `sessionKey`.

## Migration approach
1. **Dual-read**: accept `sessionKey` if present; tolerate legacy payloads until server is updated.
2. **Dual-write (temporary)**: send `sessionKey`; keep any legacy fields only as long as the provider requires them.
3. **Cutover**: remove legacy routing fields from client.

## Testing checklist
- Send from DM tab: sessionKey = `agent:main:main`.
- Send from Personal tab: sessionKey = `agent:main:clawline:{userId}:main`.
- Receive mixed DM + Personal streams; verify routing.
- Admin-only gating remains enforced for DM stream.
- Ensure retry / message errors carry correct sessionKey.

## Spec gaps to resolve
- Confirm whether `sessionKey` should be present in all server message payloads or carried via a wrapper envelope.

## Notes
- iOS maintains a single WebSocket; routing is per-message based on `sessionKey`.
- Session key is the sole identifier for stream separation.
