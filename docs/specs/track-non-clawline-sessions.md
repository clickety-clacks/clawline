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
