# T1174 Failed MSR Cleanup Note

Date: 2026-06-03

Canonical checkout: /Users/mike/src/clawline
Feature worktree: /Users/mike/src/worktrees/clawline-t1174-notification-gestures

The reviewed T1174 notification gesture/navigation patch was ported into canonical main for MSR, but canonical focused simulator proof failed before commit or deploy.

Failed proof observed on canonical main:
- `xcodebuildmcp simulator test --project-path ios/Clawline/Clawline.xcodeproj --scheme Clawline --simulator-name 'iPhone 17 Pro' --json '{"extraArgs":["-only-testing:ClawlineUITests/T1150NotificationDockUITests/testDockedNotificationTapUndocksAllNotifications"]}'`
- Result: failed at `T1150NotificationDockUITests.testDockedNotificationTapUndocksAllNotifications`; docked tap did not expose the undocked notification stack.
- Earlier focused suite also failed docked tap plus docked left-swipe after the canonical port.

Canonical port finding:
- The feature patch did not apply cleanly to current canonical main; `ChatView.swift` and `T1150NotificationDockUITests.swift` required conflict resolution.
- After conflict resolution, the peeking/navigation changes were staged, but docked hit-target behavior on canonical main remained unsafe under the real XCTest surface.
- Production peek duration stayed 5 seconds; the 15 second path was debug-argument only.

Cleanup action:
- The canonical checkout should be restored only for:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
  - `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
  - `ios/Clawline/ClawlineUITests/T1150NotificationDockUITests.swift`
- Leave unrelated `docs/deploy-state.sqlite` untouched.

Patch context remains in the T1174 feature worktree, which still has uncommitted T1174 edits in the same three source/test files.
