# T091 Unread Indicators + Local/Remote Notifications for Streams

Status: Draft (implementation-grade)
Last updated: 2026-02-20
Source: clickety-clacks/clawline#93

## 1. Goal

Implement per-stream unread state and notifications so users can see activity in non-active streams.

Required outcomes:
1. Pager dots: stream with unread messages renders theme-red.
2. Stream selector: unread streams show right-side unread indicator.
3. Notifications:
- Foreground + viewing different stream: local notification.
- Background/disconnected: remote APNS notification from provider.

## 2. Scope / Non-Goals

In scope:
1. iOS client unread tracking by stream.
2. iOS pager/selector unread UI.
3. iOS local notifications for non-active streams.
4. Provider APNS integration for background notifications.
5. Device token register/unregister lifecycle.
6. Presence protocol for WS->APNS transition safety.

Out of scope (T091):
1. Cross-device server-authoritative read receipts.
2. Dot badge overlays (dot color only).
3. User-facing notification preference UI.
4. Server-computed unread counts.
5. APNS app-icon badge counts.

## 3. Binding Decisions (Resolved)

These are implementation decisions, not optional questions.

1. Notification trigger scope:
- Notify only for incoming `assistant` role messages in non-active streams.
- Do not notify for local user echoes/placeholders.

2. Provider presence protocol (WS->APNS race handling):
- Provider tracks per `(userId, deviceId)` presence with lease semantics.
- Client sends heartbeat every 15s while WS is connected and app is active.
- Presence lease TTL is 45s.
- On disconnect/background, client sends best-effort `presence=inactive`.
- Provider applies a 20s grace window after last heartbeat before enabling APNS fanout.
- Result: message during short WS drop is still treated as potentially connected (no lost gap between WS and APNS path).

3. APNS badge policy:
- Provider MUST omit `aps.badge`.
- Client MUST NOT set/update app-icon badge in T091.

4. Notification recipient mapping:
- Provider uses the same recipient user set as existing message fanout for that `sessionKey`.
- For per-user streams, recipient is that stream owner user.
- For shared streams (for example global/admin), recipients are all users currently authorized by existing routing.
- APNS fanout is per recipient user’s registered tokens.

## 4. Current State (Codebase)

1. Pager dots are custom SwiftUI circles in `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift`.
2. Stream selector rows are rendered in `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`.
3. Message ingest mutation seam is `ChatViewModel.handleIncoming(_:)` / `setMessages(_:for:)` in `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`.
4. No APNS token registration or notification coordinator exists yet.

## 5. Architecture Overview

### 5.1 Unread model

Add per-stream state in `ChatViewModel`:
- `lastReadMessageIdBySession: [String: String]`
- `latestSeenMessageIdBySession: [String: String]`
- `hasUnreadBySession: [String: Bool]`

Mutation rules:
1. On incoming assistant message for `sessionKey != activeSessionKey`:
- Set `latestSeenMessageIdBySession[sessionKey] = message.id`
- Set `hasUnreadBySession[sessionKey] = true`
2. On stream activation:
- Set `lastReadMessageIdBySession[sessionKey] = latest message id currently in that session` (if present)
- Clear `hasUnreadBySession[sessionKey] = false`
3. On stream deletion/snapshot removal:
- Remove entries from all three dictionaries.

### 5.2 Ordering constraint (explicit)

T091 unread logic does not require full ordered history traversal.

Rule:
1. Unread is a boolean driven by event-time offscreen arrivals.
2. On cold restore, unread fallback is tail-id comparison only:
- If cached tail message id exists and differs from `lastReadMessageIdBySession[sessionKey]`, mark unread.
- If read cursor references an evicted/non-cached message, keep unread if any cached tail exists and ids differ.

This avoids requiring a global “messages after cursor” ordering contract in T091.

### 5.3 Persistence

Persist `lastReadMessageIdBySession` in user-scoped defaults key.

Restore behavior:
1. Restore dictionaries at launch/login.
2. Recompute `hasUnreadBySession` from cached stream tails + read cursor.
3. If no cached messages for a stream, default to `false` until new message arrives.

## 6. UI Changes

### 6.1 Pager dot unread indicator

File: `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift`

Changes:
1. Accept unread session key set.
2. Dot color logic:
- Active stream: existing active color.
- Inactive unread stream: theme-red.
- Inactive read stream: existing inactive color.

Use existing theme red token from design system (no new literal color).

### 6.2 Stream selector unread indicator

File: `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`

Changes:
1. Accept unread session key set.
2. Render right-side unread dot for unread stream rows.
3. Keep current row height/layout constraints.

## 7. Research Question #1: UIPageControl Per-Dot Coloring

Question: Can `UIPageControl` natively color individual dots?

Answer:
1. `UIPageControl` exposes global tint properties only: `pageIndicatorTintColor` and `currentPageIndicatorTintColor`.
2. It supports per-page image overrides (`setIndicatorImage(_:forPage:)`, `setCurrentPageIndicatorImage(_:forPage:)`) but no per-page tint API.
3. Conclusion: native per-dot arbitrary color state is not directly supported.

Recommendation:
1. Keep/extend current custom SwiftUI dot view (`StreamPageDotsView`).
2. Do not migrate this feature to `UIPageControl`.

## 8. Research Question #2: Can Provider Be Its Own APNS Service?

Yes. Clawline provider can send APNS directly via Apple HTTP/2 Provider API using token auth.

Required flow:
1. Apple setup:
- Enable Push Notifications capability for app ID.
- Create APNS Auth Key (`.p8`).
- Collect Team ID, Key ID, Bundle ID topic.

2. Client registration:
- Request notification permission.
- Call `registerForRemoteNotifications()`.
- Receive APNS device token.
- POST token + `deviceId` + `topic` + `environment` to provider.

3. Provider token storage:
- Persist by `(userId, deviceId, apnsToken, topic, environment, updatedAt, isActive)`.
- Allow multiple tokens per user.
- Upsert on register.

4. Provider send:
- Build APNS JWT (`alg=ES256`, `kid=<KeyID>`, claims `iss=<TeamID>`, `iat=<now>`).
- Send HTTP/2 POST to `/3/device/<token>` at sandbox or production host.
- Headers: `authorization`, `apns-topic`, `apns-push-type: alert`, `apns-priority`.
- Payload: `aps.alert` + custom `sessionKey` and `messageId`.
- Omit `aps.badge` per Decision #3.

5. Error handling:
- Invalid/unregistered token responses deactivate/remove token.
- Retry transient failures with bounded backoff.

## 9. Presence + Dedupe Protocol

### 9.1 Presence state

Provider tracks per-device presence states:
1. `active` when heartbeats are current.
2. `grace` after heartbeat expiry until grace window ends.
3. `inactive` after grace expiration.

APNS send eligibility for a token:
1. Only when token owner device presence is `inactive`.
2. Suppress APNS for `active` and `grace` to avoid WS/APNS race duplicates.

### 9.2 Local vs remote boundary

1. Foreground non-active stream -> local notification.
2. Background/inactive presence -> APNS.
3. No APNS badge counts.

## 10. Client-Side Changes

1. `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- Add unread dictionaries and accessors (`unreadSessionKeys`, `hasUnread(sessionKey:)`).
- Update in `handleIncoming(_:)`, `setActiveSessionKey(_:)`, stream deletion/snapshot paths.
- Keep all unread mutation on MainActor (single mutation seam).

2. `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
- Pass unread set to dots and stream selector.
- Route notification tap using `selectStream(sessionKey)`.

3. `ios/Clawline/Clawline/Views/Chat/StreamPageDotsView.swift`
- Add unread-aware dot color path.

4. `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`
- Add right-side unread indicator.

5. App bootstrap (`ios/Clawline/Clawline/ClawlineApp.swift` + new notification/presence coordinator)
- Request auth, register APNS token, register `UNUserNotificationCenterDelegate`.
- Handle foreground display in `willPresent`.
- Handle tap response deep-link by `sessionKey`.
- Send presence heartbeats while active WS session exists.

## 11. Provider-Side Changes

Target: Clawline Node.js provider.

### 11.1 Data model

Add push registration store:
- `userId`, `deviceId`, `apnsToken`, `topic`, `environment`, `updatedAt`, `isActive`

Add presence lease store:
- `userId`, `deviceId`, `lastHeartbeatAt`, `state`

### 11.2 APIs

1. `POST /api/push/register`
- Body: `{ deviceId, apnsToken, topic, environment }`
- Auth required; upsert token row.

2. `POST /api/push/unregister`
- Body: `{ deviceId, apnsToken? }`
- Auth required; remove token(s).

3. `POST /api/presence/heartbeat`
- Body: `{ deviceId }`
- Auth required; refresh presence lease.

4. `POST /api/presence/inactive` (best effort)
- Body: `{ deviceId }`
- Auth required; set inactive immediately.

### 11.3 Message fanout hook

On persisted assistant message:
1. Resolve recipients from existing message fanout recipient set for `sessionKey`.
2. For each recipient user, resolve active APNS tokens.
3. For each token, check presence state; send APNS only when `inactive`.
4. Handle APNS errors and prune invalid tokens.

## 12. Race Conditions and Edge Cases

1. WS->APNS transition race:
- Covered by presence lease + grace state (Section 9).

2. Stream-switch race (message during navigation):
- All stream activation + incoming handling remains on MainActor.
- Notification scheduling reads current `activeSessionKey` after mutation in the same serialized actor turn.
- If message session equals newly active stream at evaluation time, do not notify.

3. Offline catch-up with evicted cursor:
- Use tail-id comparison fallback, not cursor traversal.

4. Multiple devices:
- Independent tokens and presence leases per device.

5. Stream creation/deletion:
- New stream starts read; deleted stream removes unread/read state immediately.

6. Notification tap to deleted/unknown stream:
- Ignore target if stream unavailable.

## 13. Acceptance Checks

1. Foreground/non-active stream assistant message:
- Pager dot turns theme-red.
- Stream selector shows unread dot.
- Local notification appears.

2. Open unread stream:
- Dot and selector unread indicators clear.

3. Background device message delivery:
- APNS delivered for inactive presence.
- Tap navigates to target stream.

4. WS disconnect short flap (< grace window):
- No notification loss window between WS drop and APNS eligibility.

5. No badge side effects:
- App icon badge unchanged by T091 flows.

## 14. Remaining Non-Blocking Question

1. Notification sound policy (default sound vs silent) can be chosen during implementation without changing architecture.

## 15. Implementation Handoff

1. Implement exactly this scope for T091.
2. Do not add server unread counts or cross-device read sync.
3. Keep unread mutation centralized in `ChatViewModel`.
4. Keep pager implementation custom (no `UIPageControl` migration).
5. APNS implementation must use `.p8` token auth and token pruning.

## 16. Research References

1. Apple UIKit header (`UIPageControl.h`, iOS SDK 26.1): global tint APIs + per-page image overrides, no per-page tint API.
2. Apple Remote Notifications Programming Guide (Provider API):
- https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/CommunicatingwithAPNs.html
3. Apple Account Help (APNS auth keys):
- https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens/
