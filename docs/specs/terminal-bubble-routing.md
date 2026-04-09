# Terminal Bubble Routing

Date: 2026-04-04

## Goal

Make terminal bubble destination selection explicit per bubble instead of implicit in one provider-global tmux host setting.

After this change, the product rule is:

- one client request names one destination address
- the provider makes that connection
- the provider forwards bytes back to the client
- if the destination refuses or cannot be reached, the bubble fails on that destination
- the bubble descriptor truthfully states which destination address the bubble is on

## Current Problem

Current terminal bubbles are only half-explicit.

- The bubble descriptor names `terminalSessionId`, but not the destination address.
- The provider-wide config `terminal.tmux.mode` plus `terminal.tmux.ssh.target` decides where all remote terminal bubbles go.
- `TerminalSessionRecord` stores `tmuxSessionName` only, and today it is derived directly from `terminalSessionId`.
- `handleTerminalAuth` rehydrates a session by `terminalSessionId` and assumes the provider-global tmux backend is still the right place to attach.

Observed consequence:

- one client request may intend "open a bubble on eezo"
- but the actual destination is hidden in provider process config, not in the request or descriptor
- the UI therefore cannot truthfully tell the user which destination a given bubble is on
- mixed-destination terminal bubbles are impossible because one provider process only points at one configured remote tmux host at a time

This violates single-source-of-truth for routing. The bubble artifact visible in chat is not the routing authority for the bubble it represents.

## Ground Truth Product Behavior

This spec is grounded in the behavior already implemented for terminal bubbles:

- terminal bubbles are delivered as inline document attachments with MIME `application/vnd.clawline.terminal-session+json`
- the client detects terminal bubbles by MIME type, decodes the inline descriptor, and renders a terminal surface
- the client opens a separate `/ws/terminal` socket and authenticates with `terminal_auth`
- the provider owns the terminal transport and performs the connect/attach step; the client never SSHes directly
- `terminal_auth` identifies the bubble by `terminalSessionId`
- the provider finds or reconstructs the terminal session record, attaches to the destination, and forwards output back to the client

The routing fix must preserve that behavior shape. This is not a design to move destination connections into the client. It is a design to make the provider’s per-bubble routing choice explicit and persisted.

## Non-Goals

- Do not change the separate `/ws/terminal` transport model.
- Do not move SSH logic into the client.
- Do not add a registry or named-machine indirection layer.
- Do not redesign terminal bubble visuals beyond making destination display truthful.
- Do not change terminal bubbles from per-user streams to global/admin streams.
- Do not solve multi-hop shells, kubectl exec, or container routing in this spec.
- Do not add a second mutable routing authority in the UI or auth handshake.

## Single Source of Truth

- Canonical bubble destination: the terminal session descriptor embedded in the bubble attachment
- Canonical provider execution target: the destination snapshot persisted in `TerminalSessionRecord`
- Canonical UI display source: the decoded descriptor destination fields

Provider config may still supply generic SSH behavior defaults, but it must stop being the hidden per-bubble routing authority.

## Design Overview

Introduce an explicit destination object on terminal bubble requests and descriptors.

New bubble flow:

1. A client action that requests a terminal bubble includes a destination address.
2. The provider validates the destination shape and creates a terminal session record that snapshots it.
3. The provider emits a terminal session descriptor attachment containing both `terminalSessionId` and destination metadata.
4. On `terminal_auth`, the provider resolves the session by `terminalSessionId`, then attaches using that record’s destination snapshot, not a process-global tmux host setting.
5. The client renders the bubble and any destination label from the descriptor, so the UI matches reality.

## Terminology

### Destination address

The concrete remote address the provider should connect to for this bubble. In the initial version of this fix, this is an SSH target string such as `mike@eezo` or `eezo`.

### Destination

The per-bubble execution target carried in the request, descriptor, and session record.

## Request Shape

The client-side request that asks for a terminal bubble must explicitly name a destination address.

Required shape:

```json
{
  "destination": {
    "address": "mike@eezo"
  },
  "title": "eezo"
}
```

Rules:

- `destination.address` is required for newly created bubbles once this spec ships.
- `destination.address` is the routing authority for the bubble request.
- `title` remains optional presentation text. It must not be the routing authority.
- The provider may default `title` from `destination.address` when the request omits it.

Why direct address instead of named-machine indirection:

- matches the product rule directly
- avoids inventing a registry layer that does not exist in the product requirement
- keeps one request naming one concrete destination
- lets the provider attempt exactly the requested connection and fail if that destination refuses

## Descriptor Shape

Extend `TerminalSessionDescriptor` with explicit destination metadata.

New shape:

```json
{
  "version": 2,
  "terminalSessionId": "term_abc123",
  "title": "eezo",
  "destination": {
    "address": "mike@eezo"
  },
  "provider": {
    "baseUrl": "https://provider.example",
    "wsPath": "/ws/terminal"
  },
  "capabilities": {
    "interactive": true,
    "supportsBinaryFrames": true,
    "supportsResize": true,
    "supportsDetach": true
  },
  "auth": {
    "mode": "chat_token"
  }
}
```

Descriptor rules:

- `version: 2` means destination-aware descriptor.
- `destination.address` is required for version 2 descriptors.
- The existing `provider`, `capabilities`, `auth`, and `expiresAtMs` fields remain unchanged.
- The client must not derive destination identity from `provider.baseUrl`, `terminalSessionId`, or title if `destination` is absent.

## Provider Session Model

`TerminalSessionRecord` must stop collapsing routing into `tmuxSessionName` alone.

New required fields:

- `terminalSessionId`
- `ownerUserId`
- `sessionKey`
- `title`
- `createdAt`
- `lastSeenAt`
- `tmuxSessionName`
- `destination.address`

Provider rules:

- `terminalSessionId` remains the primary session lookup key over `/ws/terminal`.
- `tmuxSessionName` may still equal `terminalSessionId` in the first implementation slice.
- Attach/reconnect behavior must use the record’s destination snapshot, not a provider-global backend chosen once at startup.
- If the provider restarts, DB or event-tail rehydration must restore the same destination snapshot the descriptor carried.
- Rehydration from historical bubble attachments must decode destination metadata from the attachment itself for version 2 descriptors.

## Provider Connection Behavior

The provider is responsible for making the destination connection named by the bubble.

Required behavior:

- if `destination.address` is present, the provider attempts to connect there for this bubble
- if the destination accepts the connection, the provider attaches tmux and forwards PTY bytes back to the client
- if the destination refuses, times out, or cannot be resolved, terminal setup fails for that bubble

This is intentionally direct. The provider does not remap one address to some other address through a separate registry layer.

## Transport/Auth Contract Changes

`terminal_auth` remains keyed by `terminalSessionId`.

No new client auth fields are required for v1 of this routing fix because:

- the client already authenticates the specific bubble session by `terminalSessionId`
- the provider already owns the authoritative session record lookup
- the missing behavior is not socket-level addressing, it is record-level destination persistence

Provider auth rules:

- on `terminal_auth`, load the session record for `terminalSessionId`
- verify user ownership as today
- attach using that record’s destination
- if the record cannot be resolved to a destination, return `terminal_error`

The client must not send a second destination hint at auth time. That would create two routing authorities for one bubble.

## Backward Compatibility

This change must keep older bubbles and older clients working.

### Old clients reading new bubbles

Old clients already fall back to generic document attachments when they do not understand a terminal descriptor shape. That remains acceptable.

For clients that can decode the attachment but do not know `destination`, the descriptor extension must be additive so decode does not fail if the client ignores unknown fields.

### New clients reading old bubbles

Old descriptors have no explicit destination. New clients must treat those bubbles as destination-unknown, not as "on eezo" or "on provider".

Required UI behavior for old descriptors:

- render the terminal bubble as functional if connection/auth succeeds
- do not claim a destination that the descriptor does not contain
- if a destination label is shown at all, it must be explicitly unknown, for example `Destination unknown`

Historical behavior note:

- old persisted bubbles are not rewritten in place
- destination truth for historical version 1 bubbles remains unavailable at the descriptor layer
- compatibility execution fallback for those bubbles does not grant the UI permission to invent a destination label

### Old provider config

During migration, the provider may continue using the legacy global `terminal.tmux.mode` and `terminal.tmux.ssh.target` only as compatibility fallback for version 1 bubbles that do not carry explicit destination data.

That compatibility fallback is migration scaffolding, not the routing model for new bubbles.

## Migration From the Current Global tmux Setting

Migration must be safe and incremental.

### Phase 1: add explicit destination data model

- add request/descriptor `destination.address`
- add destination fields to `TerminalSessionRecord`
- make terminal attach choose backend from the record instead of a single process-global host setting
- update historical session rehydration so version 2 descriptors recover destination from attachment payload

Outcome:

- newly created bubbles become explicit
- existing deployments do not need immediate config removal

### Phase 2: UI truthfulness

- client decodes and displays destination metadata when present
- client shows unknown for old descriptors rather than inventing a host

Outcome:

- the UI becomes truthful without requiring historical bubbles to be rewritten

### Phase 3: stop authoring legacy-only bubbles

- terminal bubble creation paths require `destination.address`
- product surfaces that launch terminal bubbles must include the destination address in the request

Outcome:

- every new bubble has an explicit destination

### Phase 4: retire hidden global routing for new bubbles

- remove new-bubble dependence on provider-global `terminal.tmux.mode` / `ssh.target`
- keep legacy read support only as a temporary fallback for old version 1 bubbles

Outcome:

- provider-global tmux host config stops deciding where new bubbles go

## UI Truthfulness Rules

The bubble UI must only say what the descriptor proves.

Required rules:

- if descriptor `destination.address` exists, show that destination or a direct display derived from that same address
- if descriptor has no `destination`, do not display a guessed destination
- do not infer destination from provider URL, current provider config, or `terminalSessionId`
- bubble title and destination label are separate concepts; title may match the destination, but it is not the routing authority

Accessibility rule:

- accessibility text for terminal bubbles should include the explicit destination when present
- otherwise it should say the destination is unspecified or unknown

## Minimal Safe Implementation Slices

Ship this in the smallest slices that preserve one authority per concept.

### Slice 1: provider routing model

- add per-record destination storage
- refactor terminal attach from one global host choice to per-record destination choice
- keep `tmuxSessionName = terminalSessionId`

This is the structural change. Without it, the rest is cosmetic.

### Slice 2: descriptor and creation path

- extend descriptor schema to version 2 with `destination.address`
- update terminal bubble creation to require a destination address for new bubbles
- persist and emit destination metadata in the attachment descriptor

This makes the bubble artifact explicit.

### Slice 3: client decode and UI

- extend `TerminalSessionDescriptor` to decode `destination`
- surface explicit destination text in UI/accessibility only when present
- show unknown rather than guessed for old descriptors

This makes the UI truthful.

### Slice 4: tests

- provider tests for destination persistence, mixed-destination attach, and restart rehydration
- client tests for version 2 descriptor decode and old-descriptor unknown-destination rendering

## Acceptance Checks

1. Two terminal bubbles created in the same user session can target two different destination addresses, and each bubble reconnects to its own destination after client detach/reattach.
2. Provider restart does not move an existing explicit bubble onto a different destination.
3. New client UI shows `mike@eezo` or a direct display derived from that same descriptor address for a bubble that explicitly names `mike@eezo`.
4. New client UI does not claim `eezo`, `tars`, or `provider` for an old descriptor that lacks destination metadata.
5. A destination connection failure causes only that bubble to fail; the provider does not silently reroute it through some other global host setting.
6. The provider never requires the client to SSH directly.
7. Event-tail or DB-based rehydration restores `mike@eezo` for a version 2 bubble that was originally created on `mike@eezo`.

## Risks

- If destination is not snapshotted into the session record, provider restarts can still silently reroute bubbles.
- If auth accepts a destination hint from the client in addition to the record, routing authority splits and replay/reconnect become ambiguous.
- If UI derives destination from title or provider config, product copy can lie even after the transport fix ships.
- If new bubbles still fall through to one hidden global host setting, the current bug survives behind a different schema.

## Open Questions

1. What exact product surface creates a terminal bubble request today, and where does the destination address enter that flow?
2. Should the visible UI show the raw destination address or a direct user-facing formatting of that same string?
3. Do we need any narrowly-scoped validation on `destination.address` beyond non-empty string, or is that intentionally out of scope for this minimal spec?

## Implementation Handoff

Scope boundary:

- implement only explicit per-bubble destination routing for terminal bubbles
- do not broaden this into registry management or generalized remote-exec infrastructure
- do not add unspecced fallback routing paths

Critical invariant:

- for a given bubble, there is exactly one routing authority, and it is carried by the descriptor plus persisted session record

Suggested file seams:

- provider terminal session creation and `TerminalSessionRecord`
- provider `handleTerminalAuth` attach path
- iOS `TerminalSessionDescriptor`
- iOS terminal bubble presentation/accessibility
