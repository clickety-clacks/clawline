# T100 Connection Failure Diagnosis (per-stream-state)

Date: 2026-02-27
Branch inspected: `per-stream-state`

## Trace Result

### 1) App launch -> ChatViewModel init -> lifecycleCoordinator init

- iOS app injects `ProviderChatService` into environment at launch:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ClawlineApp.swift:46-51`
- visionOS app does the same:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline Spatial/Clawline_SpatialApp.swift:34-39`
- `RootView` constructs `ChatViewModel` with environment `chatService`:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/RootView.swift:93-101`
- `ChatViewModel` creates `ConnectionLifecycleCoordinator` with service bridge closures:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:393-400`

### 2) Auth token received -> setAuthToken + startIfNeeded

- Auth-change path does both operations:
  - `setAuthToken` and `seedCanonicalCursor` in one task:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:475-478`
  - `startIfNeeded` in a separate task:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:482`
- On first screen task, scene-active + onAppear path also runs:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Views/Chat/ChatView.swift:458-460`

### 3) startIfNeeded -> startConnecting -> what calls `startConnectionAttempt`

- Coordinator path:
  - `startIfNeeded` -> `startConnecting`:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:191-193`
  - `startConnecting` dispatches service start via closure:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:531-552`
- Closure target is `chatService.startConnectionAttempt(...)`:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:394-396`

### 4) Does coordinator output actually trigger service connect?

- Yes, coordinator directly calls the `startAttempt` closure in `startConnecting`:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:551`
- Provider service entrypoint is implemented and launches lifecycle connect task:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:353-357`
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:496-547`

### 5) Is `observeLifecycleTransportEvents()` started and receiving?

- It is started from `startObserving()` task group:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:515-531`
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:535-538`
- But lifecycle stream has no replay buffer; events emitted before subscriber attach are dropped:
  - broadcaster behavior:
    - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:15-37`
- Coordinator also drops late/stale epoch events:
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:236-239`

## Exact Break Point

The flow breaks at the **service -> coordinator lifecycle-event bridge timing**, not at coordinator/service wiring.

- `startConnectionAttempt` can emit lifecycle events quickly (`transportOpened` emitted immediately after connect call):
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:535-537`
- Observer startup is asynchronous (`startObserving` launches detached task group, then connect is kicked off in separate tasks):
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:475-482`
  - `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:515-531`
- If early lifecycle events are missed or processed late, coordinator never advances that epoch and stale events are discarded.

This is why behavior appears as "connecting forever": UI maps `connecting/authenticating/replaying/recovering` into a single reconnecting state:
- `/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1137-1139`

## Bottom Line

- Coordinator -> service call path is wired correctly.
- The failure is at lifecycle event delivery/ordering: event consumer startup + non-replayed stream + stale-epoch drop.
