# Clawline Architecture

## Overview

Clawline is a native mobile chat app for communicating with Clawd assistants. It connects to a Clawdbot gateway via a custom WebSocket-based "Clawline provider."

```
┌─────────────────┐     WebSocket      ┌─────────────────────┐
│   Clawline App  │◄──────────────────►│  Clawdbot Gateway   │
│  (iOS/Android)  │                    │  (Clawline Provider)│
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
- iOS / watchOS (Swift, SwiftUI)
- Android (Kotlin, Jetpack Compose)

**Responsibilities:**
- Present chat UI with native animations
- Manage WebSocket connection to provider
- Store authentication token securely (Keychain / Keystore)
- Handle media attachments (images, documents)
- Display typing indicators, read receipts
- Push notification handling

### 2. Clawline Provider (Server)

A custom provider module in the Clawdbot gateway that:
- Listens on a WebSocket port
- Authenticates devices via signed tokens
- Routes messages to/from the Clawd assistant
- Handles session management
- Sends push notifications for new messages

**Connection options:**
- Tailscale (private network, preferred)
- Public internet (with TLS)

## Protocol

### WebSocket Messages

All messages are JSON with a `type` field:

```typescript
// Client → Server
interface ClientMessage {
  type: "auth" | "message" | "typing" | "read";
  // ... type-specific fields
}

// Server → Client  
interface ServerMessage {
  type: "auth_result" | "message" | "typing" | "error";
  // ... type-specific fields
}
```

### Message Types

#### Authentication
```json
// Client sends on connect
{
  "type": "auth",
  "token": "eyJhbGciOiJIUzI1NiIs...",
  "deviceId": "ABC123"
}

// Server responds
{
  "type": "auth_result",
  "success": true,
  "userId": "kaywood",
  "sessionId": "sess_xyz"
}
```

#### Chat Messages
```json
// Client → Server (user message)
{
  "type": "message",
  "id": "msg_client_123",
  "content": "Hello CLU!",
  "attachments": []
}

// Server → Client (assistant response)
{
  "type": "message",
  "id": "msg_server_456",
  "role": "assistant",
  "content": "Hey! What's up?",
  "streaming": false
}

// Streaming variant
{
  "type": "message",
  "id": "msg_server_456",
  "role": "assistant", 
  "delta": "Hey",
  "streaming": true
}
```

#### Typing Indicators
```json
// Client typing
{ "type": "typing", "active": true }

// Server (assistant processing)
{ "type": "typing", "role": "assistant", "active": true }
```

## Security

### Pairing Flow (First Connection)

1. User opens Clawline for first time
2. App generates unique deviceId, connects to provider
3. App sends pairing request with claimed user name:
   ```json
   {
     "type": "pair_request",
     "deviceId": "ABC123",
     "claimedName": "Kaywood",
     "deviceInfo": { "platform": "iOS", "model": "iPhone 15" }
   }
   ```
   
4. Provider generates 4-digit code, notifies admin (Flynn):
   ```
   Pairing request:
   Device: ABC123 - iPhone 15
   Claims to be: Kaywood
   Code: 7742
   Reply 'approve 7742' to allow
   ```
    
5. Admin approves → Provider issues signed JWT token
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
  "sub": "kaywood",
  "deviceId": "ABC123",
  "iat": 1704672000,
  "jti": "tok_unique_id"
}
```

- Signed with provider secret
- No automatic expiry (revocation-based)
- Revocable by admin command ("CLU, revoke Kaywood's access")

### Subsequent Connections

1. App presents stored token on connect
2. Provider validates signature and checks revocation list
3. If valid → session established, user identity known
4. If invalid/revoked → auth error, app clears token, prompts re-pair

## Media Handling

### Attachments (Client → Server)

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

### Large File Upload

1. Client initiates: `{ "type": "upload_start", "size": 5242880, "mimeType": "image/png" }`
2. Server responds: `{ "type": "upload_ready", "uploadId": "up_123" }`
3. Client sends chunks: `{ "type": "upload_chunk", "uploadId": "up_123", "offset": 0, "data": "<base64>" }`
4. Server confirms: `{ "type": "upload_complete", "uploadId": "up_123", "url": "..." }`

## Open Questions

- [ ] Push notification infrastructure (APNs, FCM)
- [ ] Offline message queue behavior
- [ ] End-to-end encryption (stretch goal)
- [ ] Multiple concurrent sessions per user
- [ ] Message history sync on reconnect

---

*Last updated: 2026-01-07*
