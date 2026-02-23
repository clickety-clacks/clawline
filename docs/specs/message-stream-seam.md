# Message Stream Seam (Canonical Insertion Protocol)

## Goal
Define one canonical mutation seam for the iOS chat message stream so every bubble mutation flows through a single protocol. This is an invariant for ongoing development, not a one-time patch.

Primary outcome:
- No direct mutation of `sessionMessages` (or equivalent future store) outside the seam.
- All sources (network replay/live, cache restore, optimistic input, maintenance cleanup) express intent through seam operations.
- Input/send eligibility is unambiguous: no send before active session is provisioned.

## Non-Goals
- Redesign transport/reconnect architecture.
- Change server replay contract.
- Introduce a new persistence format.
- Preserve legacy "send before provisioning" behavior.

## Problem Statement
Current behavior allows multiple message mutation paths with duplicated and divergent logic. This causes race conditions and inconsistent conflict handling (replay/cache/live, placeholder replacement, stream deletion, logout reset).

The architecture must enforce one write path with deterministic conflict and ordering rules.

## Canonical Seam
Implement one message mutation API owned by `ChatViewModel` state layer (or a dedicated internal store object owned by it). All callers invoke this API only.

### Public seam operations (conceptual)
Callers express intent, not list surgery:
- `upsert(sessionKey, message, sourceFlags)`
- `remove(sessionKey, messageId, reason)`
- `clearSessionMessages(sessionKey, reason)`
- `removeSession(sessionKey, reason)`
- `clearAllForLogout(reason)`

### Explicitly NOT public
- `replaceSession(...)` is not exposed to callers.
- `removeByIdGlobal(...)` is not part of the canonical public seam.
- Callers must not submit full-session replacements.
- Read-modify-write decisions stay inside seam internals.

### Source metadata model
Use minimal source flags the seam actually needs:
- `isServer: Bool`
- `isCache: Bool`

Derived policy:
- server message: `isServer = true`
- cache message: `isCache = true`
- optimistic/local maintenance paths: both false unless explicitly needed

Callers do **not** provide:
- direct index manipulation
- direct array reassignment
- conflict resolution logic
- ordering logic

## Invariants Enforced By The Seam
1. Single writer
- Only the seam mutates message collections.

2. Dedup by message ID per session
- At most one message with a given `id` per `sessionKey`.

3. Server-wins conflict policy
- If same `(sessionKey, id)` exists from non-server source and a server message arrives, server payload replaces existing entry.
- If same `(sessionKey, id)` exists from server source, latest server payload replaces previous server payload.
- Cache never overwrites an existing ID.

4. Stable ordering
- Upsert of a new ID appends at tail.
- Upsert of an existing ID updates in place (does not move position).
- Relative order of existing IDs remains stable.

5. Cache is gap-fill only
- Cache may insert only IDs absent from current session set.
- Cache cannot delete, reorder, or overwrite existing IDs.

6. Streaming update-in-place
- Repeated server events for the same streaming message ID must update the existing bubble in place, not append duplicates.
- This is distinct from initial insert and must be tested separately.

7. Retry is new attempt at tail
- Retrying a failed message uses a new client ID and appends at the end of the session timeline.
- Retry does not preserve original failed bubble position.

8. Logout clear is atomic across dependent state
- `clearAllForLogout` must atomically reset:
  - all per-session message collections
  - active session selection state (`engineActiveSessionKey`, UI-selected key or successor)
  - reconnect cursor state (global and per-session)
  - pending local message tracking / placeholder tracking
  - message failure tracking tied to the cleared messages
- No partial clears that leave stale cross-references.

9. Side effects centralized
- Persistence, cursor updates, active-session projection (`messages`), and dependent bookkeeping occur inside seam-owned flow.

10. Provisioning gate for send eligibility
- `canSend` requires:
  - connected transport state, and
  - active session key present in `provisionedSessionKeys`.
- Input composer should remain ghosted/disabled until the active session is provisioned.
- No optimistic placeholder creation is allowed before provisioning readiness.

## Operation Semantics
### `upsert(sessionKey, message, sourceFlags)`
- Missing ID: append.
- Existing ID: resolve by source precedence (server > non-server), update in place.
- Preserve stable ordering.
- Supports both initial server insert and streaming update-in-place.
- Placeholder replacement is same-session only under provisioning gate policy.

### `remove(sessionKey, messageId, reason)`
- Remove one ID from known session.
- No-op if absent.

### `clearSessionMessages(sessionKey, reason)`
- Remove all messages for an existing session key.
- Session key remains present in stream/session metadata.

### `removeSession(sessionKey, reason)`
- Remove entire session entry including associated message collection and cursor state.
- Distinct from `clearSessionMessages`.

### `clearAllForLogout(reason)`
- Atomically reset message stream and logout-coupled dependent state (see invariant 8).

## Required Migration Strategy (Compiler-Error-First)
This is mandatory to discover all callsites.

### Step 1: Remove/lock legacy direct mutation APIs first
- Delete or make unavailable old helpers and direct-write entry points.
- Remove writable access to backing message store from non-seam code.
- Where immediate deletion is unsafe, mark as unavailable with compile-time failure (`@available(*, unavailable, message: ...)`).

Purpose:
- Force compiler errors at every bypass callsite.
- Build migration list from real compile breaks.

### Step 2: Route each compile break through seam operations
- Convert each callsite to one of:
  - `upsert`
  - `remove`
  - `clearSessionMessages`
  - `removeSession`
  - `clearAllForLogout`
- No ad-hoc local merge logic remains in callers.

### Step 2a: Temporary private migration shim (if required)
- If a transitional path still lacks session ownership for remove-by-id cleanup,
  implement a private/internal shim inside seam internals only.
- The shim is migration-only and must not be public API.

### Step 3: Delete temporary compatibility shims
- After migration, remove all legacy mutation entry points.
- Remove any temporary private global-remove shim introduced in Step 2a.

## Expected Touchpoint Classes (migration checklist)
- Incoming server message initial insert (live + replay)
- Incoming server streaming update-in-place (same ID)
- Cache restore apply (gap-fill only)
- Optimistic placeholder insertion
- Pending->server replacement (same-session)
- Retry new-at-tail flow (old client ID retired, new ID appended)
- Attachment hydration updates
- No-reply synthetic message insertion
- Stream deletion (`removeSession`) vs clear-only paths (`clearSessionMessages`)
- Logout/global atomic clear (`clearAllForLogout`)

## Acceptance Criteria
1. Structural
- Exactly one internal seam exists for message-store writes.
- No direct writes to `sessionMessages` (or successor store) outside seam implementation.
- No public `removeByIdGlobal` in final seam API.

2. Behavior
- Dedup by `(sessionKey, id)` always enforced.
- Server-wins conflict policy always enforced.
- Streaming updates update in place.
- Cache only fills missing IDs.
- Retry appends as a new attempt at tail.
- Send is blocked unless active session is provisioned (`activeSessionKey in provisionedSessionKeys`).
- No cross-session placeholder relocation behavior remains in seam requirements.
- `clearSessionMessages` and `removeSession` are behaviorally distinct.
- Logout clear is atomic across message + dependent state.

3. Migration proof
- Legacy direct mutation APIs removed/unavailable first.
- Migration completed by fixing all resulting compile errors.

4. Tests
- New/updated tests verify:
  - duplicate ID update-in-place
  - server overwrites non-server payload for same ID
  - streaming same-ID update-in-place vs initial insert
  - cache gap-fill only
  - retry appends at tail
  - clear-session vs remove-session semantics
  - logout atomic clear semantics

## Ongoing Guardrail
Any new feature that inserts/removes/replaces bubbles must use seam operations. PRs introducing direct message-store mutation outside seam are invalid.

## Implementation Handoff
Scope boundaries:
- In scope: seam operations, migration of all current callsites, and tests for invariants in this spec.
- Out of scope: transport protocol redesign, replay transport metadata redesign.

Risks:
- Hidden direct writes in async helper paths.
- Retry/placeholder regressions if new-at-tail semantics are inconsistently applied.
- Missed distinction between clear-session and remove-session in stream lifecycle paths.
- Transitional private shim lingering beyond migration if not explicitly removed.
