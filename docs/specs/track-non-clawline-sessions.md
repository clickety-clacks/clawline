# Track Non-Clawline Sessions

## Goal

Define how the T155 Track flow surfaces non-Clawline agent sessions for adoption without changing the meaning of the normal Clawline stream list.

## Non-Goals

- Do not include non-Clawline sessions in the normal Clawline stream list before they are tracked.
- Do not broaden `/api/streams`, WebSocket `auth_result.sessionKeys`, or WebSocket `session_info` to include non-Clawline sessions as if they were native Clawline streams.
- Do not create SQLite-backed Clawline stream rows just to make a non-Clawline session visible in the picker.
- Do not change startup routing, admin routing, or shared-session defaults.

## Source Of Non-Clawline Session Keys

Non-Clawline track candidates come from a distinct provider HTTP API backed by the gateway session store, not from the existing Clawline stream manifest.

### Required source

- The provider exposes a new authenticated endpoint for Track candidates, for example `GET /api/trackable-sessions`.
- The endpoint reads from the OpenClaw session store (`sessions.json` / `SessionEntry` records), which already contains agent-session metadata.
- The endpoint returns only sessions that are visible to the authenticated Clawline user.
- The endpoint excludes:
  - native Clawline stream sessions
  - sessions already provisioned as Clawline streams
  - sessions already adopted locally if the client sends those keys for exclusion

### Why this source

- The gateway is the source of truth for non-Clawline agent sessions.
- Existing Clawline stream APIs are SQLite-backed stream manifests and must stay stream-only.
- Client-local message caches are not a reliable or complete inventory of trackable agent sessions.

## Track Picker Presentation

The Track UI presents non-Clawline sessions in a distinct section from native Clawline sessions.

## Track Picker Ceremony (Selection Safety)

The Track flow should add light confirmation ceremony so accidental adoption is unlikely and reversal is cheap.

### Required interaction

- Tapping Track opens a modal picker (existing Track sheet/popover path is acceptable) showing adoptable sessions.
- Selecting a row only marks selection; it does **not** immediately adopt.
- User confirms with an explicit primary action (Adopt or Done) and may cancel without changes.
- If no session is selected, primary action stays disabled.

### Wrong-selection recovery

- Adopted sessions must remain easy to remove (Untrack in one quick action).
- After untrack, show an Undo affordance/toast so recovery is near-zero penalty.
- Untrack never deletes the underlying gateway session; it only removes Clawline linkage.


### Required presentation

- The Track picker shows a dedicated section such as `Other Sessions` or `Agent Sessions`.
- Native Clawline sessions, if they are ever shown in the same picker, remain in their own `Clawline Chats` section.
- Non-Clawline rows must have distinct visual treatment so they are not mistaken for native Clawline streams.
  - Minimum treatment: a section boundary plus a short secondary label such as `Agent session`.
- The normal popup list remains Clawline-stream-only. Non-Clawline sessions appear only inside the Track picker until adopted.

## Track Behavior

Tracking a non-Clawline session creates a local adopted Clawline chat entry that points at the existing gateway session key.

### Required behavior

- Selecting a non-Clawline session from the Track picker adopts that session into Clawline using its existing session key.
- Adoption does not create a new provider-side SQLite stream row.
- The adopted chat appears in the normal Clawline stream list only after tracking.
- The adopted chat uses existing adopted-session semantics:
  - it can be opened like a Clawline chat
  - swipe action shows `Untrack`, not `Delete`
  - untracking removes only the Clawline linkage and leaves the underlying gateway session alive
- If the same underlying non-Clawline session is still available later, it may appear in the Track picker again after untrack.

### UX expectations

- Before tracking: visible only in the Track picker, not in the main popup stream list.
- After tracking: visible in the main popup as an adopted chat, alongside native Clawline chats.
- After untracking: removed from the main popup, but not deleted on the gateway.

## Data Contract

Non-Clawline track candidates do not have the full native Clawline stream shape.

### Data expected from the new endpoint

- `sessionKey`
- a user-facing title derived from session-store metadata (`displayName` or `label`)
- last activity timestamp (`updatedAt`)
- optional origin/routing context for secondary text, such as `channel`, `lastChannel`, `lastTo`, or `origin`

### Data that is not guaranteed

- SQLite stream ordering metadata
- native Clawline stream `kind`
- `isBuiltIn`
- native stream creation/update timestamps from the Clawline streams table
- any guarantee that the session has prior Clawline-local transcript or unread state

### Client synthesis rules

- When adopted, the iOS client synthesizes the local `StreamSession` fields it needs for presentation and persistence.
- The client must treat this as an adopted/local linkage, not as proof that the provider now owns a native Clawline stream row for that session.

## Implementation Handoff

- Provider: add a separate authenticated endpoint for non-Clawline track candidates backed by the session store.
- iOS: fetch those candidates specifically for the Track picker and render them in a separate section with distinct labeling.
- Preserve the existing `/api/streams` and WebSocket stream/session-info contracts as Clawline-stream-only.

## Message Delivery to Adopted Sessions

Adopted sessions must support sending messages from the Clawline client through to the gateway agent.

### Current blockers (provider-side)

1. **Session allowlist rejection**: `provisionedSessionKeys` (set during auth from SQLite stream manifest) does not include adopted session keys. Message handler rejects with `stream_not_found`.
2. **Session key parser**: `parseClawlineUserSessionKey` expects `agent:main:clawline:<userId>:<streamSuffix>` format. Non-Clawline keys (e.g. `agent:main:discord:channel:123`) are rejected.
3. **Stream suffix routing**: The inbound message handler derives `streamSuffix` from parsed Clawline key structure. Non-Clawline keys have no suffix to extract.
4. **Message persistence**: `persistUserMessage` writes to Clawline SQLite events table. Adopted sessions have no corresponding stream row.
5. **Message history**: No provider path to fetch prior messages for non-Clawline sessions through the Clawline HTTP/WS APIs.
6. **Agent delivery routing**: The `route` object hardcodes `channel: "clawline"` — adopted sessions may have originated on other channels.

### Required behavior

- The provider must accept sends to adopted session keys that are present in the gateway session store, even if they are not native Clawline streams.
- The provider must route these messages to the gateway using the adopted session's original channel context (not hardcoded `clawline`).
- The provider should persist user messages for adopted sessions so the Clawline client can display conversation history locally.
- The `provisionedSessionKeys` allowlist sent during auth must include adopted session keys (client reports which sessions it has adopted).
- Non-Clawline session keys must not be forced through `parseClawlineUserSessionKey`.

### Implementation approach

- Client sends adopted session keys during WebSocket auth (e.g. `adoptedSessionKeys` field alongside existing auth payload).
- Provider merges adopted keys into `provisionedSessionKeys` for the session.
- Message handler adds a code path for non-Clawline session keys: skip Clawline-specific parsing, route directly to gateway with original channel context from session store metadata.
- Persistence: store messages in the existing events table keyed by adopted session key, or in a separate lightweight store.
- History: optionally expose adopted-session message history through `/api/streams/<sessionKey>/events` or a new endpoint.

### Not required (for initial implementation)

- Real-time typing indicators for adopted sessions
- Read receipts across adopted sessions
- Full parity with native Clawline stream features (ordering, pinning, etc.)

## Adoption Security Policy

### Design principle

Stream ownership is a UX convenience (each user sees their own streams), not a security boundary. The Clawline extension's `provisionedSessionKeys` allowlist is extension-level UX scoping, not core security — core OpenClaw has no concept of per-user session ownership.

### Policy

- Only admin users (`isAdmin`) can adopt session keys from the gateway session store.
- Adopting another user's stream effectively creates a group chat — both users can see and send to that session.
- No ownership validation beyond the admin check — admin can adopt anything.
- Non-admin users cannot use the Track/adopt flow.

### Auth-time behavior

- When the client reports adopted session keys during auth, the provider merges them into `provisionedSessionKeys` without ownership checks.
- On successful adoption via the adopt endpoint, the provider adds the key to the client's live session immediately.
- On reconnect/re-auth, the provider rebuilds the adopted set from server-side adoption records.

## Adopted Session Message Delivery

### Approach

- Add a separate inbound code path for non-Clawline session keys — do NOT broaden `parseClawlineUserSessionKey()`.
- For adopted keys, skip Clawline-specific parsing and `streamSuffix` derivation.
- Build inbound context from the session store's real origin metadata (`channel`, `lastChannel`, `lastTo`) so core can route replies to the correct provider/channel.
- Persist messages in the existing `events` table keyed by the adopted session key — bypass Clawline-only key normalization that coerces unknown keys to the personal stream.

### What changes where

- **Clawline extension only** — no core changes needed. Core already routes arbitrary `agent:*` keys and supports cross-channel reply delivery.
- Provider auth: merge adopted keys into `provisionedSessionKeys` and subscriptions.
- Provider inbound: add adopted-session branch in `processClientMessage` before the Clawline parser.
- Provider persistence: skip `normalizeStoredSessionKey` coercion for adopted keys.
- Provider context: build route from session-store metadata, not hardcoded `clawline`.
