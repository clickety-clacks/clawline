# Siri Intent: Voice Send Message

Status: Draft  
Owner: Clawline iOS  
Last updated: 2026-01-30

## Overview

Add a Siri/App Intents entry point that lets users send a message to Clawline by voice. The intent is a lightweight, self-contained flow that creates its own connection lifecycle (connect → auth → send → teardown) and does **not** rely on `ChatViewModel` or any singleton state.

## Goals

- Provide a voice-triggered "send message" path via **App Intents** (not legacy SiriKit).
- Support two parameters:
  - Bot name (string, default "CLU", configurable by the user).
  - Message (string, required).
- Route messages to the correct Clawdbot session:
  - Admin users → `agent:main:main`
  - Regular users → `agent:main:clawline:{userId}:main`
- Use the app's existing stored session/user info (pairing/auth data) to determine routing.
- Register phrases via `AppShortcutsProvider`.
- Handle errors clearly: not paired, empty message, connection timeout.

## Non-goals

- No UI changes in the chat screen.
- No SiriKit / Intents.framework legacy integrations.
- No background conversation streaming or follow-up replies via Siri.

## User Experience

### Example invocations
- "Hey Siri, tell Clawline: what's the build status?"
- "Send a message to CLU: deploy staging."
- "Ask Clawline bot Ranger to summarize logs."

### Parameter handling
- **Message** is required; Siri should ask for it if missing.
- **Bot name** is optional; defaults to "CLU" when not specified.
 - Users can set a bot name in the Shortcut itself (Siri remembers the parameter for that shortcut).

### Voice response (high-level)
- Success: confirm the message was sent (no transcript of content required).
- Failure: short, actionable error (e.g., "Clawline isn’t paired yet. Open the app to pair.").

## Intent Design (App Intents)

### Intent summary

**Name:** `SendMessageIntent` (working name)  
**Framework:** AppIntents  
**Execution context:** In-app execution (intent code lives in the main app target) so it can read the same stored auth/session data as the app. If an Intent Extension is introduced later, it must use an App Group-backed storage scheme to share auth/session state.
**Launch:** No UI surface required.

### Parameters

1. **botName**  
   - Type: String  
   - Default: `"CLU"` (override from stored user preference if available)  
   - User-facing title: "Bot"
   - Optional

2. **message**  
   - Type: String  
   - User-facing title: "Message"
   - Required (empty / whitespace = error)

## Routing Rules

Use existing stored session info from the app (pairing/auth persistence) to determine:

- `isAdmin` (or equivalent role flag)
- `userId` (or equivalent stable identifier)

Derive session key:

- If admin: `agent:main:main`
- Else: `agent:main:clawline:{userId}:main`

If the app has no pairing/auth data or `userId` is unavailable, treat as **not paired** (error).

## Storage & Configuration

- Reuse the app's existing auth/session storage (currently `UserDefaults.standard` via `AuthManager`).
  - Auth keys today: `auth.token`, `auth.userId`, `auth.isAdmin`.
- Add a lightweight preference for the default bot name (e.g., `siri.botName`) to allow user configuration.
- Default bot name source of truth: explicit Siri parameter > stored preference > "CLU".
- Configuration surfaces:
  - Shortcuts parameter (no app UI required for initial rollout).
  - Optional in-app setting later to edit the stored default.
- If a future extension target is required, migrate auth + bot preference to an App Group suite before enabling the extension.

## Message Send Contract

- Use the existing chat send path (no new wire schema).
- Payload is the same as an in-app user message:
  - `content`: the message string (see bot name formatting below)
  - `sessionKey`: derived from routing rules above (see `architecture.md`)
- No attachments or rich content are supported by this intent.
- Treat the send as successful only after the underlying chat service receives the server `ack` (handled by `ChatServicing`).
- Bot name formatting:
  - If `botName` is the default ("CLU"), send `content = message`.
  - If `botName` is non-default, prefix the content as `@{botName} {message}` to allow backend routing without changing the wire schema.

## Connection Lifecycle

The intent is self-contained and must not depend on any shared UI state:

1. **Connect** using a fresh `ChatServicing` instance (per `ios-architecture.md`).
2. **Authenticate** using existing stored credentials (token) via `ChatServicing.connect(...)`.
   - Use `lastMessageId = nil` to avoid replay and minimize latency for a one-shot send.
3. **Send** the message payload with the chosen `sessionKey` and `content` (content may include the bot name prefix per the contract above).
4. **Teardown** the connection regardless of success/failure.

Notes:
- No singleton dependencies.
- Any services used should be created specifically for the intent invocation.
- The provider allows one active connection per device; this short-lived connection may temporarily replace the in-app session. The app should reconnect when foregrounded (current behavior).

## Error Handling

### Not paired
Condition: No stored auth/pairing data or user id.  
Response: "Clawline isn’t paired yet. Open the app to pair."

### Empty message
Condition: Message missing or only whitespace.  
Response: "What do you want to say?"

### Connection timeout
Condition: Connect/auth/send exceeds timeout budget.  
Response: "Clawline didn’t respond in time. Try again."

### Auth revoked / expired
Condition: Stored token is invalid or revoked.  
Response: "Clawline needs you to sign in again. Open the app."

### Offline / unreachable
Condition: No network or server unreachable.  
Response: "Clawline can’t reach the server right now. Try again soon."

## Timeout Budget

App Intents have tight runtime limits; target a total budget that fits within Siri’s execution window.

- Initial target: 8–10 seconds total (including intent launch).
- Phase budgets should be tuned using real latency measurements (Wi‑Fi vs cellular).

Fail fast if the budget is exceeded and report the timeout error.

## Privacy & Lock State

- Require device unlock via App Intent authentication policy (intent should not execute while locked).
- When invoked from the lock screen, Siri should prompt for unlock and only then run the intent.
- The "not paired" error is reserved for missing auth/session data, not lock-state.
- Do not speak back the message content by default; only a generic confirmation.

## OS Support

- Requires iOS 17+ (App Intents).
- No SiriKit fallback for older OS versions.

## App Shortcuts

Register phrases via `AppShortcutsProvider` (examples, not exhaustive):

- "Tell Clawline to \(.message)"
- "Send \(.message) to \(.botName)"
- "Ask \(.botName) \(.message)"

## Security & Privacy

- Use only existing stored credentials already used by the app (currently stored in `UserDefaults.standard` via `AuthManager`).
- Note: longer-term, consider migrating auth tokens to Keychain or a protected App Group if an extension target is introduced.
- Do not log message contents in analytics.
- Localize user-facing responses for Siri (success + errors).

## Acceptance Criteria

- A Siri/App Intents shortcut can send a message without opening the UI.
- The intent does **not** reference `ChatViewModel` or a singleton.
- Routing uses admin vs regular session keys as specified.
- Missing pairing, empty message, and timeout return clear spoken errors.
- App Shortcuts phrases are registered and discoverable in Shortcuts.
- Users can configure the bot name via the Shortcut parameter (and it persists for that Shortcut).
