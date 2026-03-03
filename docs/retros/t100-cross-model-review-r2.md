# T100 Cross-Model Review — Round 2

Date: 2026-02-27
Branch: `per-stream-state`
HEAD: `3415ce986`
Method: Claude Opus adversarial review (`claude-opus-4-5-20251101`) over targeted spec + code snippets.
Source output: `/Users/mike/src/worktrees/per-stream-state/scratch/t100-cross-model-r2-opus-output.md`

## Results

1. Race: subscription exists before ANY coordinator-connect trigger path (`onAppear`, `authChange`, `sceneActive`, `manualRetry`)
- **FAIL**
- PASS paths:
  - `onAppear` calls `startObserving()` before `startIfNeeded()`:
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:463)
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:465)
  - auth-change path calls `startObserving()` before `startIfNeeded()` task:
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:498)
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:504)
  - scene-active path now ensures subscription before foreground connect intent:
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:528)
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:530)
- Failing path:
  - `reconnect()` triggers `manualRetry` without explicit subscription guard:
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:485)
    - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:488)

2. F5: history reset calls `StreamSwitchCoordinator.reset()`
- **PASS**
- `handleHistoryResetRequired` now invokes reset before coordinator acknowledgment:
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:929)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:936)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:939)

3. F7 + C1: `ProviderChatService.handleMessage` skips legacy decode/cursor-write in lifecycle mode
- **PASS**
- Lifecycle path now emits lifecycle event and returns immediately:
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:663)
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:665)
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:666)
- Legacy decode/cursor write remains only after the non-lifecycle guard:
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:668)
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:679)

4. AC8: reconnect cursor from canonical writer-owned state
- **PASS** (Opus verdict)
- Coordinator uses actor-local canonical cursor for attempt dispatch:
  - [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:103)
  - [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:157)
  - [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:161)
  - [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:551)

5. AC11: single-writer audit (`ConversationStoreWriter` seam)
- **FAIL**
- No formal `ConversationStoreWriter` type found.
- Direct state mutations remain in `ChatViewModel`:
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:930)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:931)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:932)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:933)
  - [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1097)
- Cursor state still has service-side mutation APIs and writes in non-lifecycle paths:
  - [ChatServicing.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Protocols/ChatServicing.swift:65)
  - [ChatServicing.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Protocols/ChatServicing.swift:66)
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:377)
  - [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:679)

## Overall
- **FAIL**
- Remaining blockers from this round: race guarantee not complete for `manualRetry` path, and AC11 single-writer seam not implemented.
