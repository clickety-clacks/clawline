# T099 Root Cause C Fix (stale VM teardown)

## Root cause
`logout -> login` could leave prior `ChatViewModel` instances alive (`reviews/t099-three-vm-diagnosis.md`, `reviews/t099-stale-vm-trace.md`).  
Those stale instances could later run `onDisappear()` and call `chatService.disconnect()` while a newer VM was mid-connect, causing repeated reconnect knockbacks and long yellow pulse.

## What changed
1. Added explicit connection ownership + stale-instance retirement guards in `ChatViewModel`.
- Ownership seam: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:37-66`
- Startup path guards (`retired`/`non-owner`) on `onAppear`, auth-change, scene-active, reconnect, observer startup:
  - `:492-517`
  - `:533-541`
  - `:548-600`
  - `:613-670`

2. Added deterministic teardown API for replaced VMs.
- `prepareForReplacement()` marks VM retired, cancels observer tasks/subscriptions, cancels send, and disconnects only if that VM owns the connection:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:687-696`
- Shared teardown helper:
  - `:672-685`

3. Gated `onDisappear()` disconnect by owner.
- Non-owner VMs now cancel local tasks but skip shared transport disconnect:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:519-531`

4. Root now retires old VM before dropping reference.
- `RootView` calls `prepareForReplacement()` before `chatViewModel = nil` in both unauthenticated transitions:
  - `ios/Clawline/Clawline/Views/RootView.swift:61-62`
  - `ios/Clawline/Clawline/Views/RootView.swift:69-70`

## Why this fixes Root Cause C
This closes both stale-VM failure paths:
- Old VM observers are explicitly cancelled at replacement time (no lingering for-await loops).
- Even if stale lifecycle callbacks fire later, non-owner VMs cannot disconnect the shared transport.

Result: the newest VM is the only connection owner and only instance allowed to control lifecycle disconnect.

## Validation
- Build sanity check passed after changes:
  - `XcodeBuildMCP.build_sim` succeeded for scheme `Clawline`.
