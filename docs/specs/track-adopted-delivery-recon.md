# Track Adopted Delivery Recon

## Goal

Capture the current provider/core behavior around sending messages to adopted non-Clawline sessions, identify the exact blockers, and define the architectural questions that must be resolved before implementation.

## Non-Goals

- Do not specify the final product UX for adopted-session history or untrack flows.
- Do not implement adopted-session delivery in this document.
- Do not broaden native Clawline stream semantics to treat adopted sessions as SQLite-backed streams.
- Do not silently add new security rules beyond what is needed to explain the current risk surface.

## Current Failure

The current Clawline provider rejects sends to adopted non-Clawline session keys with `stream_not_found`.

Primary causes:

1. WebSocket auth populates `session.provisionedSessionKeys` from the native Clawline SQLite stream manifest only.
2. Inbound message handling requires the target session key to be present in that allowlist.
3. Non-built-in session keys are reparsed with `parseClawlineUserSessionKey`, which only accepts native Clawline key shape (`agent:<agentId>:clawline:<userId>:<streamSuffix>`).
4. The inbound context builder always constructs a Clawline route/origin, even when the adopted session key belongs to another provider/channel.

## Full Message Path

### WebSocket auth

- `extensions/clawline/src/runtime/server.ts`
- `wss.on("connection")` accepts the socket and dispatches `auth` payloads into `handleAuth`.
- `handleAuth` verifies protocol version, JWT, device approval, and allowlist membership.
- `applySessionInfo()` builds the session allowlist and subscriptions from SQLite stream rows via `buildSessionInfo()`.
- `session.provisionedSessionKeys` and `session.sessionKeys` are therefore native-stream-only today.

### WebSocket inbound message

- `handleAuthedMessage()` passes the payload to `processClientMessage()`.
- `processClientMessage()`:
  - validates payload shape
  - normalizes attachments
  - resolves `payload.sessionKey`
  - validates that key via `normalizeStreamMutationSessionKeyForUser()`
  - checks that the resolved key is in `session.provisionedSessionKeys`
  - derives Clawline `streamSuffix` from `parseClawlineUserSessionKey()`
  - persists the user message
  - broadcasts the event to subscribed sockets
  - builds an inbound context and calls `dispatchReplyFromConfig()`

### Agent dispatch

- The provider does not proxy this inbound message through a separate gateway RPC.
- It constructs `ctxPayload` locally and calls `dispatchReplyFromConfig()` directly.
- Core OpenClaw resolves the active agent from `ctx.SessionKey` via `resolveSessionAgentId()`.
- This means arbitrary `agent:*` session keys are already understood by core for agent selection.

### Reply delivery

- Core reply routing depends on the finalized inbound context, especially:
  - `SessionKey`
  - `Provider`
  - `Surface`
  - `OriginatingChannel`
  - `OriginatingTo`
- `dispatchReplyFromConfig()` will route replies to another provider when `OriginatingChannel`/`OriginatingTo` differ from the current surface and are routable.

## Current Assumptions That Break Adopted Sessions

### 1. Session allowlist is stream-manifest-only

Auth-time subscriptions are built from `stream_sessions` rows, not from client-adopted keys or the gateway session store.

Consequence:

- Any adopted key not provisioned as a native Clawline stream is rejected before dispatch.

### 2. Non-native keys are forced through Clawline parsing

`parseClawlineUserSessionKey()` is intentionally strict and only recognizes native Clawline stream keys.

Consequence:

- Keys such as `agent:main:discord:channel:123`
- `agent:main:subagent:uuid`
- `agent:other:main`

cannot pass the current inbound path.

### 3. Inbound routing metadata is hardcoded to Clawline

The provider currently builds:

- `channelLabel = "clawline"`
- `route.channel = "clawline"`
- `OriginatingChannel = "clawline"`
- `OriginatingTo = <ClawlineDeliveryTarget>`

Consequence:

- Even if the adopted key were allowed through, the resulting reply-routing metadata would describe a Clawline-originated turn, not the adopted session's original provider context.

### 4. Clawline stream semantics are mixed into adopted-path persistence

The SQLite `events` table can already store arbitrary `sessionKey` values.

However:

- user-message persistence preserves the raw session key
- assistant-message persistence goes through `appendEvent()` / `insertEventTx()`
- `insertEventTx()` normalizes unknown keys via `normalizeStoredSessionKey()`
- unknown/non-Clawline keys fall back to the user's personal Clawline session
- replay uses the same normalization path

Consequence:

- adopted-session assistant messages and replay would collapse into the native Clawline main stream unless the adopted path bypasses current Clawline-only normalization.

## Security Analysis

## Can `provisionedSessionKeys` include adopted keys at auth time?

Mechanically yes, but only with server-side validation.

If the client simply sends `adoptedSessionKeys` and the provider blindly merges them into:

- `session.provisionedSessionKeys`
- `session.sessionKeys`

then the client gains both:

- send permission
- replay/live-subscription visibility

for any key it names.

### Why this is unsafe today

The shared OpenClaw session store has useful metadata (`channel`, `origin`, `lastChannel`, `lastTo`, etc.) but not a trustworthy owner/visibility field for arbitrary non-Clawline sessions.

That means the provider currently lacks a clean server-owned proof that:

- a given non-Clawline session key belongs to the authenticated Clawline user
- the user is allowed to subscribe to and send on that adopted key

### Additional current risk

The current `/api/trackable-sessions` feed now excludes native Clawline keys and provisioned rows, but it no longer applies a clear ownership check for non-Clawline sessions. That increases the importance of defining a server-side visibility rule before auth-time adopted-key merging.

## Parser Question

## Should `parseClawlineUserSessionKey()` handle non-Clawline formats?

No.

Reasons:

- It is the native Clawline parser and is used by native stream lifecycle and validation paths.
- Clawline delivery targets are intentionally Clawline-specific.
- Broadening it to accept arbitrary OpenClaw keys would mix two concepts:
  - native Clawline stream identity
  - adopted opaque OpenClaw session identity

Recommended direction:

- keep `parseClawlineUserSessionKey()` strict
- add a separate adopted-session branch that treats the session key as an opaque OpenClaw key plus session-store metadata

## Core vs Extension Changes

## What appears to be extension-only

- auth-time adopted-key handling
- adopted-session allowlist/subscription merge
- separate inbound send path for non-Clawline keys
- adopted-session context builder
- adopted-session persistence/replay normalization fixes

## What may require core support

The main likely core requirement is a trustworthy ownership/visibility signal for arbitrary session-store entries.

Core routing itself does not look like the blocker:

- core already resolves the active agent from arbitrary `agent:*` session keys
- core reply routing already supports non-Clawline channels when `OriginatingChannel` and `OriginatingTo` are correct

If multi-user security must be preserved, either:

- core needs to persist ownership/visibility metadata in the session store, or
- the provider needs another server-owned lookup source that can prove adopted-key visibility per user

## Persistence Findings

## Can adopted messages use the existing `events` table?

Yes, structurally.

The current schema does not require a `stream_sessions` row for an event's `sessionKey`.

What must change:

- assistant-message persistence must stop coercing adopted keys back to the user's personal Clawline stream
- replay must preserve adopted keys instead of re-normalizing them into native Clawline keys

Conclusion:

- a separate store is not obviously required
- but the current Clawline-specific normalization path cannot be reused unchanged

## Delivery Routing Findings

## What has to change so messages reach agents on other channels?

The main requirement is not just changing `route.channel`; it is building the full inbound context from the adopted session's real origin metadata.

An adopted-session path would need to derive, from the session store or equivalent server-owned metadata:

- `SessionKey` = adopted session key
- `Provider`
- `Surface`
- `OriginatingChannel`
- `OriginatingTo`
- `AccountId` / thread metadata when relevant
- any last-route update behavior appropriate for that provider

It must not use:

- Clawline `streamSuffix`
- `ClawlineDeliveryTarget`
- Clawline DM/global follow-me semantics

for non-Clawline adopted keys.

## Open Questions

1. What is the authoritative server-side rule for determining that a non-Clawline session-store entry is visible to a specific Clawline user?
2. Should adopted keys be sent by the client during auth, or should the provider derive them from a server-side adopted-linkage store?
3. Is the existing session store the intended long-term source of origin/delivery metadata for adopted sessions, or is another provider-owned linkage table needed?
4. Should adopted-session history be exposed through the current WS replay path only, or should a dedicated HTTP history endpoint be added?
5. Does Clawline need a separate subscription set for adopted sessions, distinct from native `provisionedSessionKeys`, to avoid concept drift?

## Implementation Handoff

- Preserve native Clawline stream semantics as-is.
- Add a separate adopted-session path rather than loosening native Clawline parsers.
- Do not merge client-supplied adopted keys into the auth allowlist until server-side visibility validation is explicitly defined.
- Reuse the existing `events` table if possible, but split adopted persistence/replay away from Clawline-only key normalization.
- Build adopted inbound contexts from real origin metadata so core can route replies to the adopted session's original provider.
