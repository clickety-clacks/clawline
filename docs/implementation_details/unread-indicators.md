# Unread Indicators — Non-Obvious Details

## Unread set mutations centralized in ChatViewModel only — three specific call sites
All unread/read-cursor mutations must go through:
1. `handleIncoming(_:)` — sets unread for non-active session on incoming assistant message
2. `setActiveSessionKey(_:)` path — clears unread and updates read cursor on stream selection
3. Stream deletion/snapshot reconciliation — cleans up cursor entries

Any other call site for unread mutation is out-of-spec and creates divergence.

## Stream switch clears unread and sets read cursor to tail — not to "first unseen"
Selecting a stream sets `lastReadMessageIdBySession[sessionKey]` to the stream's current tail message ID and clears unread. This is "mark all as read on visit," not "mark only up to current scroll position." Unread state restored on next login only reflects messages received AFTER that tail ID.

## APNS / cross-device read sync is explicitly out of scope for T091
The unread indicators are client-local only. No server-side unread counts, no push notification registration, no cross-device read sync. A second device will show different unread state. This is a known limitation that is explicitly deferred.
