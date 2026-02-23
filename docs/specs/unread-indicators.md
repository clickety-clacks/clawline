# T091 Unread Indicators

Status: Draft (implementation-grade)
Last updated: 2026-02-20
Source: clickety-clacks/clawline#93
APNS follow-up: clickety-clacks/clawline#102 (backburnered)

## 1. Goal

Implement per-stream unread indicators in the iOS client.

Required outcomes:
1. Per-stream read cursor tracking.
2. Pager dot turns red for unread streams.
3. Stream selector shows unread red dot per unread stream.

## 2. Scope / Non-Goals

In scope:
1. Client read cursor state: `lastReadMessageIdBySession`.
2. Unread UI in pager dots and stream selector.

Out of scope for T091:
1. APNS token registration.
2. Provider presence protocol.
3. Remote push infrastructure.
4. App-icon badge count handling.
5. Server-side unread counts or cross-device read sync.

## 3. Current State (Codebase)

1. Pager dots are custom SwiftUI circles in `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift`.
2. Stream selector rows are rendered in `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`.
3. Message ingest mutation seam is `ChatViewModel.handleIncoming(_:)` / `setMessages(_:for:)` in `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`.

## 4. Architecture Overview

### 4.1 Unread model

Add client state in `ChatViewModel`:
- `lastReadMessageIdBySession: [String: String]`
- `hasUnreadBySession: [String: Bool]`

Rules:
1. Incoming assistant message for `sessionKey != activeSessionKey` sets `hasUnreadBySession[sessionKey] = true`.
2. Selecting a stream sets `lastReadMessageIdBySession[sessionKey]` to that stream tail message id (if present) and clears unread.
3. Deleting/removing a stream clears its unread/read-cursor entries.

### 4.2 Persistence

1. Persist `lastReadMessageIdBySession` in user-scoped `UserDefaults`.
2. On restore, recompute unread by comparing persisted cursor to cached tail message id when available.

### 4.3 Mutation seam

Unread mutation stays centralized in `ChatViewModel`:
1. `handleIncoming(_:)` for unread set.
2. `setActiveSessionKey(_:)` path for unread clear.
3. Stream deletion/snapshot reconciliation for cleanup.

## 5. UI Changes

### 5.1 Pager dot unread indicator

File: `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift`

Changes:
1. Accept unread session key set.
2. Dot color logic:
- Active stream: existing active color.
- Inactive unread stream: theme-red.
- Inactive read stream: existing inactive color.

### 5.2 Stream selector unread indicator

File: `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`

Changes:
1. Accept unread session key set.
2. Render right-side unread red dot for unread rows.
3. Preserve existing row height/layout.

## 6. Race / Edge Cases

1. Stream-switch race:
- Evaluate unread mutation against current `activeSessionKey` on MainActor after stream selection mutation.

2. Cached-message eviction:
- If stored read cursor no longer exists in cache, use cached tail-id comparison fallback for unread boolean.

3. Deleted stream state:
- Remove any unread/read-cursor state for the deleted stream.

## 7. Acceptance Checks

1. Non-active stream receives assistant message while foregrounded:
- Pager dot turns red.
- Stream selector row shows unread red dot.

2. User opens unread stream:
- Pager/selector unread indicators clear.
- Read cursor updates to stream tail message id.

3. Stream deleted with unread state:
- Unread/read-cursor state for that stream is removed.

## 8. Implementation Handoff

1. Implement exactly this client-local scope for T091.
2. Do not add any push/delivery infrastructure in this ticket.
3. Track APNS work separately in issue #102.

## 9. Research Reference (UIPageControl)

`UIPageControl` has global tint properties and per-page image overrides, but no per-dot tint API. Keep existing custom dot view for unread coloring.
