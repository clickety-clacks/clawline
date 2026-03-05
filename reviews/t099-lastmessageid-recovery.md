# T099: Ansible `lastMessageId` Recovery Analysis

## Evidence Collected

### 1) Device log pull status
- Fresh live capture attempt from Ansible failed while device was locked:
  - XcodeBuildMCP `stop_device_log_cap` output at `2026-02-28 11:41`:
    - `Unable to launch co.clicketyclacks.Clawline because the device was not, or could not be, unlocked.`
- I used prior Ansible runtime capture already pulled from this device:
  - `/private/tmp/ansible-devicectl-console.log`

### 2) What the device logs show
- Repeating loop on connect:
  - `idle -> connecting -> authenticating -> recovering` across epochs
  - e.g. `/private/tmp/ansible-devicectl-console.log:40`, `:50`, `:199`, `:206`, `:213`, `:282`, `:886`, `:907`, `:1030`
- Repeated server-side error envelope received by client during auth window:
  - `message-level error without messageId code=invalid_message`
  - `/private/tmp/ansible-devicectl-console.log:195`, `:274`, `:1018`, `:1105`, `:1223`

### 3) Why this maps to `Invalid lastMessageId`
- Provider auth code rejects malformed `lastMessageId` with this exact error payload:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:6629-6636`
  - sends `{ type: "error", code: "invalid_message", message: "Invalid lastMessageId" }`
- Regex requires strict server event id form (`s_<uuid>`):
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:191-193`

## Root Cause: Why stale/invalid `lastMessageId` is sent after branch swaps

### A) Cursor is persisted across deploy swaps (same app container/user/device)
- Cursor store key is stable by user+device:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:1195-1199`
- Snapshot restored at service init:
  - `.../ProviderChatService.swift:244`
  - `.../ProviderChatService.swift:1201-1205`

### B) Restored values are not format-validated as server IDs
- Restore only filters empty strings, not ID shape/prefix:
  - `.../ProviderChatService.swift:1201-1205`
- `ChatViewModel` seeds coordinator cursor directly from `values.max()`:
  - `.../ChatViewModel.swift:510-515`
- Coordinator uses seeded cursor as `lastMessageId` in first auth attempt:
  - `.../ConnectionLifecycleCoordinator.swift:556-580`
- Service sends that value in auth payload:
  - `.../ProviderChatService.swift:565-570`

### C) No automatic cleanup on invalid cursor rejection
- When server returns `code=invalid_message`, client logs it but does not clear replay cursor state:
  - `.../ProviderChatService.swift:813-827`
- Socket close drives lifecycle to recovering/retry:
  - `.../ConnectionLifecycleCoordinator.swift:262-266`
  - `.../ConnectionLifecycleCoordinator.swift:291-296`
- Retry reuses same canonical cursor (not cleared), causing loop.

## Why branch swaps amplify this
- `main` and `per-stream-state` deployments share the same app container/device identity.
- `per-stream-state` persists replay cursor data under stable key (`clawline.replayCursorBySession.v1.<user>.<device>`).
- If an older deployment or corrupted local state wrote non-`s_*` cursor values, later builds reuse them immediately at startup and can fail auth before any live replay can correct state.

## Can client auto-recover without logout?
Yes, but current code does not.

### Recommended recovery behavior (no logout required)
1. Validate replay cursor IDs before use.
   - Accept only `s_` + UUID-form ids for:
     - restored snapshot values
     - seeded canonical cursor in `ChatViewModel`
2. Add explicit invalid-cursor recovery path:
   - If auth-phase server error is `invalid_message` with message `Invalid lastMessageId`:
     - clear replay cursor snapshot (`chatService.clearReplayCursors()`)
     - clear canonical cursor (`lifecycleCoordinator.updateCanonicalCursor(nil)`)
     - trigger immediate reconnect once (single-shot recovery attempt).
3. Safety fallback:
   - If the same error repeats once after clear, transition to failed with explicit UI guidance.

This preserves user auth/session and removes logout dependency for stale cursor corruption.
