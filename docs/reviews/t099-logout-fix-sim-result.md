# T099 Logout→Login Fix Simulator Result

Date: 2026-02-27
Branch: `per-stream-state`
Worktree: `/Users/mike/src/worktrees/per-stream-state`
Simulator: iPhone 17 (`21F3F731-1FDB-439B-A89A-3F112F7C4E0D`)

## Implemented changes (scoped)
1. Preserve persisted per-user active session key on logout path only.
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:258-269`
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:775`

2. Stop resetting provisioning state during intermediate reconnecting phases.
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1641-1643`
- Terminal reset remains at `.../ChatViewModel.swift:1644-1648`

No other source files were changed.

## Simulator verification flow
Performed an in-session cycle using AXe UI automation:
1. Started from connected `DM` stream (`Send message` visible).
2. Triggered in-app logout via `/logout` slash command.
3. Logged back in (account picker checkmark, then server send).
4. Verified active stream and connection state immediately and after 30s.
5. Switched to non-active stream (`DM`) and re-checked after 30s.

Evidence artifacts:
- `/tmp/t099-cycle2-start.txt`
- `/tmp/t099-cycle2-after-logout.txt`
- `/tmp/t099-cycle2-after-login.txt`
- `/tmp/t099-cycle2-after-login-30s.txt`
- `/tmp/t099-cycle2-after-switch-dm.txt`
- `/tmp/t099-cycle2-after-switch-dm-30s.txt`

## Result
- (a) Return to previous stream after logout→login (expected: `DM`, not Personal): **FAIL**
  - Before logout: `DM` active (`/tmp/t099-cycle2-start.txt`).
  - After fresh login: active stream is `Personal` with `Stream 2 of 2` (`/tmp/t099-cycle2-after-login.txt`).

- (b) Non-active streams load without yellow/reconnecting stall: **FAIL**
  - After fresh login, active stream remained `Reconnecting` after 30s (`/tmp/t099-cycle2-after-login-30s.txt`).
  - After switching to `DM`, send button remained `Reconnecting` after 30s (`/tmp/t099-cycle2-after-switch-dm-30s.txt`).

## Conclusion
The two surgical fixes were applied exactly as scoped, but the logout→fresh-login simulator regression is not resolved by these changes alone.
