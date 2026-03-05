# T099 Three-`ChatViewModel` Diagnosis

## Scope
Diagnose why three `ChatViewModel` instances are alive during login, where each is created, what triggers each creation, and why no `deinit` is observed.

## Creation Seam (single source)
All runtime `ChatViewModel` creation goes through a single view-hierarchy path:

1. `ClawlineApp` renders `RootView` in `WindowGroup` (`ios/Clawline/Clawline/ClawlineApp.swift:54-63`).
2. `RootView` creates `ChatViewModel` only in `ensureChatViewModel()` (`ios/Clawline/Clawline/Views/RootView.swift:90-101`).
3. `ensureChatViewModel()` is triggered by:
- authenticated task path (`ios/Clawline/Clawline/Views/RootView.swift:53-70`, especially `:65-67`)
- fallback `ProgressView.task` path when `chatViewModel == nil` (`ios/Clawline/Clawline/Views/RootView.swift:44-47`)

`rg` check confirms no other runtime initializer callsites beyond `RootView` (preview-only callsites in `ChatView.swift` are not runtime).

## Instance Timeline (from simulator trace)
Evidence from captured trace: `/tmp/t099-stalevm-key-lines.txt`.

1. **VM #1** `AF4CD600-C2D2-468F-8876-4F4E622857B8`
- Init: `19:38:19.337` (`line 3` in trace)
- Trigger: authenticated start immediately follows (`line 4`)
- Creation source in code: `RootView.task(id: auth.isAuthenticated)` -> `ensureChatViewModel()` -> `ChatViewModel(...)` (`RootView.swift:53-70`, `:90-101`)

2. **VM #2** `A3665309-654A-4C8E-9F5E-8D2FA44B849E`
- Init: `19:38:44.073` (`line 213`)
- Trigger: fresh authenticated transition during logout->login cycle (`line 214`)
- Same creation seam as VM #1 (`RootView.swift:53-70`, `:90-101`)

3. **VM #3** `822EC543-D9C8-4E43-991C-1E1D045E6A33`
- Init: `19:39:13.422` (`line 464`)
- Trigger: next authenticated transition (`line 465`)
- Same creation seam as above

## Why all three remain alive (no `deinit`)
### Observed behavior
- `onDisappear` disconnects are logged for old VMs (`lines 201`, `342`, `450`, `525` in `/tmp/t099-stalevm-key-lines.txt`).
- After those disappears, older VMs still react to auth-change (`lines 459-460` show #1 and #2 both start again).
- No `ChatViewModel deinit` appears in trace (`rg "ChatViewModel deinit"` returns none).

### Code-level retention mechanism
1. `ChatViewModel` registers `AuthStateDidChange` observer in init (`ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:438-443`) and only removes it in `deinit` (`:453-457`).
2. Each instance creates long-lived observation loops via `observationTask` in `startObservingIfNeeded()` (`ChatViewModel.swift:551-571`).
3. Those loops run `for await` over service streams (`ChatViewModel.swift:587-607`) and keep the instance active while running.
4. When old instances do not deallocate, they continue receiving auth notifications and run `handleAuthStateChange()` (`ChatViewModel.swift:498-510`), so multiple VMs start/restart connection flow during a single login.

### Additional strong-retention path in view stack
- `MessageFlowCollectionViewController` stores a strong `viewModel` (`ios/Clawline/Clawline/Views/Chat/MessageFlowCollectionView.swift:190`, assigned at `:1640`).
- This provides another path for stale UIKit controllers (including prewarm shells) to keep prior VM generations alive past logout/login transitions.

## Conclusion
Three VMs are not created by three different hierarchy nodes. They are **three generations from the same `RootView.ensureChatViewModel()` seam**, triggered by repeated auth transitions. Prior generations are not deallocated, so they continue observing auth changes and participating in connection startup, yielding concurrent stale/live VM activity during login.
