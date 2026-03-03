# T100 stale-listener close race fix

## Root cause
- In lifecycle connect fallback, attempt 1 could leave a stale listener alive while attempt 2 became active.
- The stale listener later emitted socket-close handling that produced `transportClosed(.error)` and could knock the coordinator from `authenticating` to recovery/failure before active auth success landed.
- Evidence in service path:
  - Fallback branch that previously continued without full stale listener suppression: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:549`
  - Socket-close handler was previously shared and not attempt-token scoped: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:1033`

## What changed
- Added lifecycle connection token ownership so events/closes are accepted only from the active connection:
  - token assignment on successful connect: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:537`
  - stale event drop gate: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:935`
  - stale socket-close ignore gate: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:1033`
- In fallback `continue` path, explicitly disconnect/cleanup before moving to next transport:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:549`
- Added regression test for stale-close race so stale attempt close cannot move epoch 1 from `authenticating -> recovering`:
  - test case: `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/ClawlineTests/ProviderServiceTests.swift:384`

## Simulator retest result
- Focused iOS Simulator retest after patch no longer stayed in persistent yellow connecting.
- Runtime evidence showed stale close suppression (`ignoring stale lifecycle socket close`) and UI state moved off reconnecting to `Disconnected. Tap to reconnect.` (not stuck in yellow pulse).
