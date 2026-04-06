# T173: Drag-to-Reorder Streams in the Clawline Chat Popup

## Goal

Make the stream list in the Clawline chat popup reorderable by drag, with the new order:

- updating immediately in the popup
- persisting on the provider via the existing stream REST surface
- rewriting `stream_sessions.orderIndex`
- broadcasting the canonical reordered list to every connected client for that user
- converging cleanly when two devices reorder at the same time

## Current State

- The popup already has partial drag affordance work: drag handles are visible and rows can be dragged, but the drag does not complete the full data flow to canonical stream order.
- The provider already stores `orderIndex` on `stream_sessions`.
- Stream CRUD already uses:
  - `GET /api/streams`
  - `POST /api/streams`
  - `PATCH /api/streams/:sessionKey`
  - `DELETE /api/streams/:sessionKey`
- WebSocket clients already consume `stream_snapshot`, `stream_created`, `stream_updated`, and `stream_deleted`.

## Non-Goals

- Do not add a separate `streamId`; `sessionKey` remains the canonical stream identifier.
- Do not invent a second ordering source on iOS. Persisted order remains server-owned.
- Do not pin built-in or adopted streams to fixed positions.
- Do not add version vectors, merge UI, or per-row conflict prompts for reorder.
- Do not change create/delete semantics outside the explicit reorder path.
- Do not add watchOS or other non-popup drag UI in this ticket.

## Product Behavior

- Every visible stream row in the popup shows a drag handle when reorder is currently allowed.
- Dragging a row reorders the popup list immediately.
- Dropping commits the full reordered list to the provider.
- When the provider accepts the reorder, every connected device for that user converges on the same order via WebSocket `stream_snapshot`.
- If the reorder fails, the popup rolls back to the latest canonical order from the view model.
- Rename, delete, add, adopt/untrack, search filtering, and reorder are mutually exclusive popup mutation modes. Reorder is disabled while any of those transient states are active.

## Single Source of Truth

- Canonical persisted order: provider `stream_sessions.orderIndex`
- Canonical wire representation: ordered `StreamSession[]` returned by `GET /api/streams`, `PATCH /api/streams`, and `stream_snapshot`
- Popup-local optimistic order: a transient `[sessionKey]` array owned by the popup view only while the popup is visible

The popup may reorder locally before server acknowledgment, but it must treat the provider snapshot as authoritative once it arrives.

## Ordering Rules

- User-defined order is the primary ordering rule.
- After this feature, iOS must not impose local priority sorting such as:
  - built-ins before custom streams
  - admin/global streams before personal streams
- Everywhere that renders stream order must sort by:
  1. `orderIndex`
  2. `sessionKey` only as deterministic tie-breaker

This is required so drag reorder actually changes visible order. Any local priority sorting would silently override the user’s chosen order.

## Client Design

### Popup UI seam

The popup keeps a local `displayedSessionKeys: [String]` initialized from the current `streams` prop.

Required behavior:

- The row list is rendered from `displayedSessionKeys`, resolved back to `StreamSession`.
- SwiftUI reorder flows through one move seam:
  - `onMove(fromOffsets:toOffset:)`
- If the popup keeps a custom always-visible drag handle instead of stock edit-mode handles, that drag surface must still reduce into the same `onMove`-style mutation path. There must be one local reorder write seam, not separate drag and move implementations.
- `onMove` mutates `displayedSessionKeys` immediately for optimistic local reorder.
- Drag handles remain visible only when reorder is enabled.
- Reorder is disabled when:
  - search query is non-empty
  - inline rename is active
  - delete/untrack confirmation is active
  - pending create placeholder rows exist
  - a create/delete/reorder request is already in flight

Disabling reorder during filtered mode is required because a filtered subset cannot safely produce a full canonical ordering for all visible streams.

### Commit path

When the drag completes, the popup builds the reordered full visible session-key list and sends it to the view model:

`ChatViewModel.reorderStreams(sessionKeys: [String])`

Rules:

- The array must contain every currently visible popup stream exactly once.
- The popup does not synthesize or modify `orderIndex` locally.
- The popup only sends the final order after drop completion, not intermediate hover states.

### View model seam

Add a dedicated reorder mutation seam:

- `ChatServicing.reorderStreams(sessionKeys: [String]) async throws -> [StreamSession]`
- `ProviderChatService.reorderStreams(...)`
- `StreamAPIClient.reorderStreams(...)`
- `ChatViewModel.reorderStreams(sessionKeys:) async -> Bool`

`ChatViewModel.reorderStreams` responsibilities:

- validate that the submitted array is a permutation of current ordered streams
- call the provider reorder endpoint
- on success, apply the returned canonical stream snapshot
- on transient `not_connected`, reuse the same reconnect-and-retry pattern already used by create/delete
- on failure, show the existing toast error and leave canonical order unchanged

The view model should not create a second long-lived ordering cache. It should continue to derive ordered streams from `streamsBySessionKey` plus server-provided `orderIndex`.

### Snapshot convergence

The initiating client will usually see two confirmations:

1. the HTTP response from `PATCH /api/streams`
2. the WebSocket `stream_snapshot` broadcast

Rules:

- The HTTP response may be applied immediately as the canonical post-mutation state.
- The subsequent `stream_snapshot` must still be accepted, even if identical.
- If a later `stream_snapshot` disagrees with the popup’s optimistic order, the popup must snap to the snapshot; do not preserve stale local order.

## REST Contract

## Chosen shape

Reuse the collection route:

- `PATCH /api/streams`

Request body:

```json
{
  "sessionKeys": [
    "agent:main:clawline:flynn:s_bravo",
    "agent:main:clawline:flynn:main",
    "agent:main:clawline:flynn:s_alpha"
  ]
}
```

Response body:

```json
{
  "streams": [
    {
      "sessionKey": "agent:main:clawline:flynn:s_bravo",
      "displayName": "Bravo",
      "kind": "custom",
      "orderIndex": 0,
      "isBuiltIn": false,
      "adopted": false,
      "createdAt": 1700000000000,
      "updatedAt": 1700000005000
    }
  ]
}
```

## Why batch full-list PATCH

- Reorder is inherently a whole-list mutation, not a single-row patch.
- A single move gesture should not emit N incremental server writes.
- The server must validate that the client reordered the exact visible set it is allowed to mutate.
- Returning the full reordered snapshot matches existing stream bootstrap and broadcast semantics.

## Why not a dedicated `/reorder` endpoint

No new route is needed. `PATCH /api/streams` already represents collection-level mutation and keeps reorder inside the existing stream CRUD namespace.

## Request validation

The provider must reject reorder requests unless `sessionKeys`:

- exists
- is a non-empty array of strings
- contains no duplicates
- resolves only to stream rows the authenticated user can mutate
- includes every visible stream exactly once

Failure codes:

- `400 invalid_request`
  - malformed body or duplicate keys
- `400 stream_reorder_requires_full_list`
  - the array is a stale/incomplete permutation of the current visible set
- `404 stream_not_found`
  - a submitted key is no longer valid or visible to that user

No idempotency key is required for reorder in T173. The call is a final-state replacement, not a create/delete side effect that needs replay protection.

## Server Persistence

### Storage

Persist reorder only by updating `stream_sessions.orderIndex`.

No schema change is required.

### Transaction shape

The provider must rewrite all affected rows in one transaction.

Because `stream_sessions` has `UNIQUE (userId, orderIndex)`, direct in-place updates can collide when two rows swap positions. The write path must therefore use a two-pass rewrite inside one transaction:

1. write temporary non-conflicting negative `orderIndex` values
2. write final dense `0...N-1` values

Example:

- final requested order: `[bravo, personal, alpha]`
- temporary write:
  - `bravo -> -1`
  - `personal -> -2`
  - `alpha -> -3`
- final write:
  - `bravo -> 0`
  - `personal -> 1`
  - `alpha -> 2`

Each updated row also gets a fresh `updatedAt`.

### Hidden rows

The reorder endpoint operates on the caller’s visible stream set.

If the server has additional rows for that user that are not visible to this caller, it must:

- preserve their relative order
- append them after the reordered visible set during the transaction

This keeps `orderIndex` unique without granting the caller mutation power over hidden rows.

### Interaction with existing delete behavior

- Delete/untrack continues to leave gaps when it happens by itself.
- Reorder is the first explicit path that is allowed to renumber rows densely.
- After any successful reorder, `orderIndex` becomes dense again for the affected user-visible set.

## Server Broadcast

### Chosen WebSocket behavior

After a successful reorder transaction, broadcast a full:

- `stream_snapshot`

to every connected socket for that user.

Do not emit one `stream_updated` per moved row.

Reasons:

- reorder is a list-level atomic mutation
- every stream’s `orderIndex` may change
- a single snapshot avoids clients reconstructing list order from a burst of row updates
- existing clients already treat `stream_snapshot` as the canonical full-list replacement

### Broadcast ordering

For the user that initiated reorder:

1. HTTP response returns reordered `streams`
2. provider broadcasts `stream_snapshot`

All connected devices, including the initiator, converge by applying that snapshot.

## Conflict Resolution

## Simultaneous reorder requests

Two devices for the same user may reorder at nearly the same time.

Chosen rule: newest wins.

For T173, "newest" is defined as:

- the last reorder request the server receives

Provider behavior:

- serialize reorder mutations through the existing per-user write queue
- do not perform merge logic
- do not perform conflict detection
- apply requests in server-receive order
- broadcast a canonical snapshot after each accepted reorder

Client behavior:

- a client may optimistically show its own drag result immediately
- if another reorder request reaches the server after it, the later request becomes canonical and the next `stream_snapshot` overrides the earlier local order
- do not attempt client-side merge of two concurrent reorder gestures

This is intentionally simple last-write-wins semantics with the server as the only authority.

## Stale list conflicts

If the visible stream set changes between drag start and reorder commit, the server must reject the stale reorder instead of guessing.

Examples:

- another device creates a stream
- another device deletes/untracks a stream
- the current stream becomes invalid/hidden

Server response:

- `400 stream_reorder_requires_full_list` when the submitted list no longer matches the current visible set
- `404 stream_not_found` when a submitted key disappeared

Client response:

- clear optimistic popup order
- apply the latest snapshot if one has already arrived
- otherwise fall back to current view-model order and let the next stream refresh/snapshot converge state

## Edge Cases

### Adopted streams

- Adopted streams participate in reorder exactly like native streams.
- They already have `stream_sessions` rows and `orderIndex`.
- Reorder does not touch `adopted_sessions`; it only rewrites `stream_sessions.orderIndex`.
- Untrack/delete rules remain unchanged. Reorderability does not imply rename/delete parity.

### Built-in streams

- Built-in streams remain non-deletable/non-renamable according to existing rules.
- Built-in status does not pin them in place.
- They participate in reorder like any other visible stream.
- iOS must not locally force built-ins ahead of custom streams once reorder is enabled.

### Streams created during reorder

- If a create/adopt succeeds after drag starts but before the reorder request executes, the submitted list is stale.
- The reorder request must fail with `stream_reorder_requires_full_list`.
- The client must revert local optimistic order and accept the newer canonical snapshot that includes the new stream.

### Streams deleted or untracked during reorder

- If a row disappears before the reorder request executes, the request must fail with `stream_not_found` or `stream_reorder_requires_full_list`, depending on which validation detects the mismatch first.
- The client must revert local optimistic order and accept the newer canonical snapshot without the deleted stream.

### Popup filtered state

- Reorder is disabled while search filtering is active.
- The popup must not attempt to reorder only the filtered subset.

### Popup dismissed mid-request

- If the popup closes while reorder is in flight, the request still completes.
- Canonical convergence still happens through the view model’s stream snapshot handling.
- The popup should not keep detached transient reorder state once dismissed.

## Implementation Handoff

- Keep `sessionKey` as the only stream identifier.
- Reuse `PATCH /api/streams`; do not add a second reorder-specific endpoint.
- Make reorder a single mutation seam in iOS and a single transaction seam on the provider.
- Remove any client-side sort priority that would override server `orderIndex`.
- Treat `stream_snapshot` as the canonical multi-device convergence event after reorder.
- Do not add speculative merge logic for simultaneous reorders.

## Acceptance Checks

1. Dragging a stream in the popup changes row order immediately before the network round-trip completes.
2. Dropping sends one `PATCH /api/streams` request with the full ordered `sessionKeys` list.
3. The provider rewrites `stream_sessions.orderIndex` transactionally without violating `UNIQUE (userId, orderIndex)`.
4. The HTTP response returns the reordered canonical `streams` array with updated `orderIndex`.
5. The provider broadcasts one `stream_snapshot` containing the canonical reordered list to every connected device for that user.
6. A second device connected to the same account updates to the new order without manual refresh.
7. If two devices reorder concurrently, both converge on the order from the last reorder request the server receives.
8. If create/delete/adopt/untrack changes the visible stream set during a drag, the stale reorder request is rejected and the initiating client rolls back to canonical order.
9. Built-in and adopted streams can be moved, but their existing rename/delete protections remain unchanged.
10. After reorder is implemented, client rendering order follows `orderIndex` rather than any hardcoded stream-kind priority.

## Test Plan

### iOS

- `StreamAPIClient` test for `PATCH /api/streams` request body and response decode
- `ProviderChatService` test that reorder forwards through control-plane auth
- `ChatViewModel` test that successful reorder applies returned canonical order
- popup/UI test that `onMove` mutates local display order immediately
- popup/UI test that failure restores canonical order
- popup/UI test that reorder is disabled during search/filter mode
- popup/UI test that incoming `stream_snapshot` while popup is open replaces stale optimistic order

### Provider

- success test for batch `PATCH /api/streams` returning reordered list
- broadcast test verifying all connected sockets receive `stream_snapshot`
- validation test for duplicate session keys
- validation test for missing one visible stream from the submitted list
- validation test for unknown/deleted stream key
- persistence test showing `orderIndex` is dense and unique after reorder
- edge-case test for reordering a list containing adopted and built-in rows
- concurrency test showing two reorder requests serialize and the last reorder request the server receives wins

## Open Questions

- None for T173. The chosen design is:
  - full-list `PATCH /api/streams`
  - transactional `orderIndex` rewrite
  - `stream_snapshot` fanout
  - newest-wins conflict handling, where newest means the last reorder request the server receives
