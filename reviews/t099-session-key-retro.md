# T099 Retro: Ansible "Invalid clawline session key" During per-stream-state Connect

## Scope
- Question 1: Did `per-stream-state` change how auth tokens/session keys are constructed, sent, or stored vs `main` (especially WebSocket auth message)?
- Question 2: Could this instead be device/runtime state (stale creds, corrupted auth, prior-state mismatch)?

## 1) Auth Handshake Diff (`origin/main` vs `per-stream-state`)

### What `main` sends in auth message
- `AuthPayload` fields: `type`, `protocolVersion`, `token`, `deviceId`, `lastMessageId`, `clientFeatures`, `client`
- Evidence:
  - `origin/main` `ProviderChatService.swift:90-98` (auth payload shape)
  - `origin/main` `ProviderChatService.swift:845-869` (payload construction and send)

### What `per-stream-state` sends in auth message
- Same core fields, plus `replayCursorsBySessionKey` (currently sent as `nil`)
- Evidence:
  - `per-stream-state` `ios/Clawline/Clawline/Services/ProviderChatService.swift:90-99`
  - `per-stream-state` `ios/Clawline/Clawline/Services/ProviderChatService.swift:565-582` (lifecycle `sendAuth`, includes `replayCursorsBySessionKey: nil`)
  - `per-stream-state` `ios/Clawline/Clawline/Services/ProviderChatService.swift:1159-1175` (legacy/auth-wait path, same `replayCursorsBySessionKey: nil`)

### Session-key construction/sending in auth
- No session key is sent in auth payload on either branch.
- `per-stream-state` still passes token only from auth state through coordinator to service:
  - `ChatViewModel.swift:513-516` sets coordinator token from `auth.token`
  - `ConnectionLifecycleCoordinator.swift:556-580` starts connect with `authToken` and cursor
  - `ChatViewModel.swift:426-428` forwards that token into `startConnectionAttempt(...)`
- `connect(token:activeSessionKey:)` currently ignores `activeSessionKey` in service (`ProviderChatService.swift:296-299`), so no active stream key is injected into auth payload.

### Token/session storage changes
- Auth persistence path is unchanged vs `main`:
  - `AuthManager.swift` unchanged in diff (`git diff --quiet origin/main -- ... => UNCHANGED`)
  - Token load/store locations are unchanged (`AuthManager.swift:38-41`, `55-67`, `83-95`)
- WebSocket URL construction and connector are unchanged:
  - `ProviderBaseURLStore.swift` unchanged
  - `URLSessionWebSocketConnector.swift` unchanged

## 2) Device/Runtime-State Angle

### Important server-side evidence
- The literal error text `Invalid clawline session key` is thrown in provider send-target/session-key parsing, not in WebSocket auth verification:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:5722-5742` (`resolveSessionTargetFromSessionKey`, throws exact message)
- WebSocket auth failures return `auth_result` reasons like `auth_failed`/`token_revoked`, not `Invalid clawline session key`:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:6533-6588`

### Interpretation
- The reported provider log string strongly indicates a session-target/routing parse failure path, not auth-payload schema/token construction differences introduced by `per-stream-state`.
- A pure "bad token format constructed by branch code" explanation is not supported by code diff evidence.
- Device/runtime state is still plausible for authentication trouble (token persists in Keychain/UserDefaults and can be stale), but that would surface as auth failure reasons in the auth handler path, not this exact `Invalid clawline session key` throw site.

## Conclusion
- **Q1 answer:** `per-stream-state` did **not** change auth token/session key construction in a way that introduces a new session-key field in auth. Auth payload change is limited to adding `replayCursorsBySessionKey` and sending it as `nil`; token source/storage path remains unchanged.
- **Q2 answer:** The exact error text points to provider session-key target parsing, not WebSocket auth. If Ansible logs show `Invalid clawline session key` at connect time, the likely issue is a parallel provider routing/session-target path (or stale runtime/session context), not a handshake auth payload construction regression in this branch.
