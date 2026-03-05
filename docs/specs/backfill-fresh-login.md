# T054 Fresh Login Feed Backfill

Date: 2026-03-03  
Owner: Clawline (provider + iOS client)  
Status: Ready for implementation handoff

## Goal

On first authenticated login after pairing, backfill enough recent chat history so the visible feed is populated instead of appearing mostly empty.

## Non-Goals

- No redesign of stream routing/session-key semantics.
- No new user-facing pagination UI.
- No change to steady-state reconnect behavior when `lastMessageId` is present.

## Problem

Current fresh pairing/login behavior can start replay from the current cursor forward. On a brand-new device (`lastMessageId` missing), the chat often shows little or no recent context.

## Definitions

- **Fresh login**: authenticated `auth` where `lastMessageId` is missing or `null`.
- **Backfill target messages**: number of recent server `message` events requested for initial context population.
- **Initial viewport fill**: enough content that the first rendered feed is not mostly blank and starts at the latest messages.

## Design

### 1) Provider behavior on fresh pairing/login (cursor + replay)

Provider MUST treat fresh login as a tail-replay request, not as "start at now."

Rules:

1. Fresh detection:
- If `auth.lastMessageId` is missing/`null`, provider enters **fresh replay mode** for that auth epoch.

2. Fresh replay mode selection:
- Provider replays recent `message` events from newest backward up to `N` events per visible session key, then emits them in normal chronological order.
- `N` is derived from client hint `auth.initialBackfillTargetMessages` (new optional integer), clamped to `[24, 120]`.
- If hint is absent, default `N = 60`.

3. Existing-cursor behavior:
- If `auth.lastMessageId` is present, keep current replay semantics ("events after cursor") unchanged.

4. Replay contract compatibility:
- `auth_result.replayCount` remains authoritative and counts all replayed `message` events.
- `replayTruncated` MUST be `true` if server limits/history bounds prevent delivering the requested fresh replay window.

5. Per-device cursor write:
- After replay/live apply begins, cursor persistence continues exactly as today; no special cursor format is introduced for T054.

### 2) Client-side backfill behavior

Client MUST request and render enough history to fill the first visible screen on fresh login.

Rules:

1. Fresh auth payload:
- On fresh login (`lastMessageId == nil`), client sends `initialBackfillTargetMessages`.
- Compute value at runtime from viewport:
  - `visibleRows = ceil(viewportHeight / 72)`
  - `initialBackfillTargetMessages = clamp(visibleRows * 3, 24, 120)`
- On non-fresh auth, do not send this field.

2. Initial scroll position:
- After replay completion for the fresh-login epoch, default scroll position is **bottom** (latest message visible near composer), matching normal chat behavior.
- If user starts an explicit drag before replay completion, client MUST NOT force-scroll afterward; preserve user-driven position.

3. Unread/indicator semantics:
- Fresh-login replay/backfill MUST NOT increment unread counters or trigger "new message while scrolled up" bounce behavior.

4. Empty/small history:
- If replay returns fewer messages than needed to fill a screen, render what exists and remain bottom-anchored (no synthetic placeholders).

### 3) Edge Cases

1. No history for user/session:
- `replayCount = 0` path remains valid; UI shows empty state.

2. Truncated history:
- If provider returns `replayTruncated = true`, client still enters live after replay and may show existing truncated-history notice behavior.

3. Multi-stream accounts (admin + personal):
- Provider applies fresh replay window per visible session key.
- Client keeps per-stream message stores; only currently visible stream controls initial viewport behavior.

4. History reset:
- If `historyReset = true`, existing reset contract wins: clear local state, then apply fresh replay window for that epoch.

5. Reconnect during fresh replay:
- Existing epoch/replay gating rules from `connection-lifecycle.md` remain authoritative; stale replay events are dropped.

## Acceptance Checks

1. First login after pairing with non-empty history shows enough recent messages that the initial feed is visibly populated (not mostly blank).
2. Fresh-login view lands at bottom after replay unless the user actively scrolled during replay.
3. Fresh-login backfill does not generate unread count/bounce.
4. Existing reconnect flow with non-nil `lastMessageId` is unchanged.
5. `auth_result.replayCount` and replay completion behavior remain consistent with `connection-lifecycle.md`.

## Open Questions

1. Should `72` pt row estimate be moved to a shared UI constant once implemented, or stay local to T054 logic?

## Implementation Handoff

Scope boundaries:
- In scope: provider fresh replay window selection, auth payload optional backfill hint, iOS initial backfill target calculation, initial load scroll behavior.
- Out of scope: historical pagination APIs, stream-switch UX redesign, unread system redesign.

Primary risk:
- Over- or under-filling on extreme bubble-size distributions. The `3x visible rows` heuristic is intentional and can be tuned after validation without changing the protocol shape.
