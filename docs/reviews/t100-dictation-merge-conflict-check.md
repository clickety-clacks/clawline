# T100 vs Dictation ProviderChatService Conflict Check

## Inputs reviewed
- Dictation repo: `~/src/clawline-dictation`, commit `53409a47c` on `feature/voice-dictation`
- T100 repo: `~/src/worktrees/per-stream-state`, commit `ae7933d18`
- File compared: `ios/Clawline/Clawline/Services/ProviderChatService.swift`

## 1) Does dictation `isConnecting`/in-flight join fix conflict with our connection-token gating?
- **Behavioral conflict:** **No direct behavioral conflict**.
  - Dictation fix adds a connect join gate for overlapping non-lifecycle `connect(...)` calls.
  - T100 fix adds lifecycle connection-token gating for stale listener events/closes.
- **Patch-level conflict risk:** **Yes, likely textual conflict** in same class-state/connect-method region.
  - Dictation replaces `isConnecting` with `connectJoinGate` and rewrites `connect(token:lastMessageId:)`:
    - `53409a47c` `ProviderChatService.swift:47-68`, `:240`, `:307-326`
  - T100 currently still has `isConnecting` and `connectInternal(...)` path, plus lifecycle token state:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:223`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:305-352`
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:225`

## 2) Do we both modify the same lines or adjacent logic?
- **Yes.**
  - Same property block around connection state:
    - Dictation: `connectJoinGate` at `:240` in commit `53409a47c`
    - T100: `isConnecting`, `connectAttemptTask`, `activeLifecycleConnectionToken` at lines `223-225`
  - Same connect-entry logic region:
    - Dictation rewrites `connect(token:lastMessageId:)` and introduces `performConnect(...)` (`:307-326`)
    - T100 keeps `connectInternal(...)` with `isConnecting` guard (`:305-352`)
- Lifecycle-specific changes (T100) are in separate lower regions:
  - `startConnectionAttempt(...)` and lifecycle tokenization (`:354+`, `:534+`, `:935+`, `:1033+`).

## 3) Merge ordering: independent merge or reconcile into one patch?
- **Recommendation: needs reconciliation first** (single combined patch), not independent blind merge.
- Reason:
  - Both commits touch the same connection entry/property area in `ProviderChatService.swift`.
  - Order alone does not avoid the semantic overlap (`isConnecting` guard vs join-gate pattern).
- Practical merge strategy:
  1. Keep T100 lifecycle token gating unchanged (`activeLifecycleConnectionToken`, stale close/event guards).
  2. Apply dictation join-gate semantics to **non-lifecycle** `connectInternal(...)` entry path.
  3. Remove/replace old `isConnecting` guard consistently so only one in-flight policy exists for non-lifecycle connects.

## 4) Does dictation fix affect lifecycle path, or purely non-lifecycle?
- **Primarily non-lifecycle path.**
  - Dictation commit edits `connect(token:lastMessageId:)` flow and test for overlapping `connect` calls.
  - It does **not** touch lifecycle-specific APIs in that commit (`startConnectionAttempt`, lifecycle event emission, lifecycle close handling).
  - Dictation test added is non-lifecycle-connect oriented:
    - `53409a47c` `ProviderServiceTests.swift:182-220`

## Final recommendation
- **Needs reconciliation first** before merging.
- It is not a conceptual feature conflict, but it is a same-region integration conflict in `ProviderChatService.swift` and should be merged as one intentional patch to preserve both:
  - Dictation non-lifecycle in-flight join behavior
  - T100 lifecycle stale-listener token gating
