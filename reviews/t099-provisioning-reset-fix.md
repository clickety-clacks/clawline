# T099 Provisioning Reset Cold-Launch Investigation

## Hypothesis
"Provisioning state is being cleared on every intermediate reconnect phase (connecting/authenticating/replaying), causing yellow pulse on cold launch."

## Verdict
**Not confirmed.**

## Code Trace
`ChatViewModel` only clears provisioning state on terminal connection states:
- [`ChatViewModel.swift:1630`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1630 ) `transitionConnectionState(...)`
- [`ChatViewModel.swift:1644`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1644 ) `case .disconnected, .failed:`
- [`ChatViewModel.swift:1647`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1647 ) `resetSessionProvisioningState(clearPendingSend: true)`

Intermediate states do **not** call reset:
- [`ChatViewModel.swift:1641`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1641 ) `case .connecting, .reconnecting:` only clears typing flags.

All reset call sites in file:
- [`ChatViewModel.swift:788`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:788 ) logout path
- [`ChatViewModel.swift:1647`]( /Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1647 ) terminal connection path

## Simulator Cold-Launch Trace (Kill + Reopen)
I ran cold-launch traces in simulator by launching, stopping, and relaunching. Runtime sequence:
1. `idle -> connecting -> authenticating`
2. then auth fails (`auth_failed`) and lifecycle moves `authenticating -> failed`
3. `connectionState` shows `reconnecting` during intermediate phases, then `failed`

Observed in launch logs:
- `lifecycle phase-transition from=idle to=connecting epoch=1`
- `lifecycle phase-transition from=connecting to=authenticating epoch=1`
- `state -> failed (auth result) error=Authentication failed: auth_failed`
- `lifecycle phase-transition from=authenticating to=failed epoch=1`

This matches terminal-only reset behavior, not intermediate reset behavior.

## Fix Result
The requested fix (only clear provisioning on terminal `.disconnected/.failed`) is **already present** in this branch (see `transitionConnectionState` at lines 1644-1648). No additional code change was required for this specific hypothesis.

## Yellow Pulse Verification
I could not verify "cold launch no longer shows yellow pulse" in a healthy connected session, because simulator auth currently fails (`auth_failed`) during cold launch. In this state, yellow/reconnecting UI is expected from failed auth and does not validate the provisioning-reset hypothesis.
