# Message Stream Seam: Canonical Insertion Protocol

Status: Spec Review candidate for T105

Source repair: this spec promotes and expands the preserved source document from `/Users/mike/shared-workspace/clawline/implementation_details/message-stream-seam.md`. That preserved document is retained as provenance, but this file is the canonical shared-workspace spec for T105.

## Goal

Define one canonical mutation seam for the Clawline iOS chat message stream. Every source that can change the visible or cached message collection must express intent through this seam. The seam owns deterministic deduplication, conflict resolution, ordering, cache gap-fill, session clear/removal semantics, logout atomicity, and send/provisioning admission.

The architectural invariant is: no production code mutates `sessionMessages` or equivalent per-session message collections directly outside the seam.

## Non-Goals

- No redesign of message bubble UI, markdown rendering, scrolling, or notification surfaces.
- No change to provider wire protocol unless implementation proves the existing data is insufficient.
- No optimistic local placeholder creation before send admission is satisfied.
- No public full-session replacement API for arbitrary callers.

## Terms

- Seam: the single write path that applies message stream mutations.
- Operation: a caller intent submitted to the seam, such as upsert, remove, clear session, remove session, or logout clear.
- Current session set: the authoritative in-memory message IDs currently known for one session.
- Cache restore: persisted message recovery used only to fill missing IDs.
- Live event: network/provider lifecycle or service event that may insert or update messages.
- Placeholder: a local pending user message created after send admission succeeds.

## Protocol Requirements

### T105-R1: Single Writer

All production message collection changes must route through the seam. Direct writes to `sessionMessages` or equivalent per-session arrays/dictionaries are prohibited outside the seam implementation and its tests.

### T105-R2: Compiler-Error-First Migration

Implementation must delete, mark unavailable, or otherwise make legacy direct-write APIs fail before routing callers through compatibility wrappers. The migration list must be discovered from compile errors, not from a guessed call-site inventory.

Rationale preserved from source: if direct-write APIs remain available during migration, bypasses can silently survive and reintroduce races.

### T105-R3: Operation Vocabulary

Callers must express intent using bounded seam operations:

- upsert message
- remove message
- clear session messages
- remove session
- clear all for logout
- cache gap-fill

Callers must not submit arbitrary full-session replacement operations. `replaceSession`, if needed, is internal seam machinery only.

### T105-R4: Deterministic Upsert

For a new message ID, upsert inserts according to the seam’s canonical ordering rule. For an existing message ID, upsert updates in place. Repeated server events for the same streaming message ID must update the existing entry rather than append another entry.

### T105-R5: Cache Is Gap-Fill Only

Cache-restored messages may insert only IDs absent from the current session set. Cache restore must not delete, reorder, or overwrite an existing ID. If live replay has already supplied a message ID, later cache restore for that ID is a no-op for stream state.

### T105-R6: Retry Appends At Tail

Retry of a failed message uses a new client ID and appends at the end through the normal seam path. Retry must not reuse the original bubble position or original client ID.

### T105-R7: Provisioning Gate

The composer may create/send local placeholders only when transport is connected and the active session key is provisioned. `canSend` must require both conditions. No optimistic placeholder may be created before the provisioning gate passes.

### T105-R8: Clear Session vs Remove Session

`clearSessionMessages` removes messages while preserving stream/session metadata. `removeSession` removes the session and associated cursor state. Implementations must keep these behaviors distinct.

### T105-R9: Logout Clear Atomicity

`clearAllForLogout` must atomically reset:

- all per-session message collections
- active engine session key
- active UI-selected session key
- global and per-session reconnect cursor state
- pending local message tracking
- message failure tracking

Partial logout clears are invalid because they leave stale cross-references that can surface as ghost messages or wrong-stream state on next login.

### T105-R10: Ordering And Conflict Resolution

The seam must own ordering and conflict resolution for all operations. Callers do not reorder message collections directly. If implementation encounters unresolved ordering conflicts not covered by existing model fields, it must add an explicit open question or request product/architecture clarification before inventing a heuristic.

### T105-R11: Ongoing Enforcement

The implementation must include tests or static checks that fail when production code mutates the message collection outside the seam. The enforcement should be narrow enough to allow seam internals and test fixtures, but strict enough to catch new direct production writes.

## Acceptance Criteria

- T105-A1: A code search or static check shows no production direct mutations to `sessionMessages` outside the seam.
- T105-A2: Existing message ID upserts update in place and do not append duplicates.
- T105-A3: Streaming repeated server events for the same message ID update one message entry.
- T105-A4: Cache restore after live replay does not overwrite, delete, or reorder live messages.
- T105-A5: Retry of a failed message creates a new client ID at the tail through the seam.
- T105-A6: Composer send admission remains blocked until both connected transport and active-session provisioning are true.
- T105-A7: `clearSessionMessages` and `removeSession` have distinct tested effects on metadata and cursor state.
- T105-A8: Logout clear removes all message/session/cursor/pending/failure state atomically.
- T105-A9: Build or tests fail if a new production direct-write path bypasses the seam.

## Verification Plan

1. Run focused unit tests for seam upsert, duplicate ID replacement, streaming update-in-place, cache gap-fill, retry append, clear/remove distinction, provisioning gate, and logout clear.
2. Run the static/direct-write enforcement check.
3. Run the Clawline iOS build gate.
4. Perform a real Clawline chat smoke on the message stream surface: live messages, replay/cache restore, retry, session switch, and logout/login should not produce duplicate, reordered, stale, or ghost messages.

## Implementation Handoff

Implementation should first introduce the seam interface and make old direct-write APIs unavailable so compiler errors enumerate all call sites. Then migrate each compiler-reported call site to an explicit seam operation. Do not preserve broad compatibility wrappers that allow new direct writes.

Implementation should not add unrelated stream UI behavior, notification behavior, or provider protocol changes unless a specific requirement above cannot be satisfied without it.

## Open Questions

- T105-Q1: If the current message model cannot express a deterministic ordering conflict, which source field should become authoritative: provider sequence, timestamp, receive order, or another explicit field?
- T105-Q2: Should direct-write enforcement be implemented as a unit/static test in the iOS test target, a repo script, or both?
