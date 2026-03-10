# T099 Yellow Pulse UI Disconnect Assessment

## 1) What state drives the yellow reconnect pulse?
The yellow pulse is driven by `ChatViewModel.connectionState` through `sendButtonConnectionState`.

Evidence:
- `ChatView` passes `viewModel.sendButtonConnectionState` into `MessageInputBar`:
  - `ios/Clawline/Clawline/Views/Chat/ChatView.swift:861`
- `sendButtonConnectionState` maps `.connecting/.reconnecting -> .reconnecting`:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:314-322`
- `MessageSendControl` shows the pulsing yellow dot only when `connectionState == .reconnecting`:
  - `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift:365`
  - pulse rendering/animation: `:419-425`
  - reconnect yellow color: `:380-383`

There is no other reconnect-pulse UI path in the codebase; this control is the pulse source.

## 2) Does that property update when coordinator reaches `live`?
By code path, yes.

Evidence:
- Lifecycle output handler maps `.live -> .connected` and calls the only connection-state mutation seam:
  - mapping: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1263-1267`
  - mutation call: `:1273`
  - mutation seam writes `connectionState`: `:1704-1707`
- `transitionConnectionState(...)` is only called from lifecycle output handling (single callsite):
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1273`

Device evidence from the instrumented Ansible capture (`reviews/t099-device-auth-path-capture.md`):
- `[T099-COORD] ... observeLifecycleOutputs output=phaseTransition(... replaying -> live ...)`
- This means `handleLifecycleOutput(.phaseTransition to: .live)` executed on that VM, and by the code above it maps to `.connected`.

## 3) What can reset it back to yellow after `live`?
Anything that causes a later lifecycle phase transition out of `live` to a reconnecting phase will flip the UI back to yellow.

Direct reset path:
- Any later phase transition to `.connecting/.authenticating/.replaying/.recovering` is remapped to `.reconnecting`:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1266-1267`

Concrete triggers for that transition:
1. Service-level `connectionInterrupted` event:
- ChatViewModel handles `.connectionInterrupted` by calling coordinator `reconnectIntentTransportInterrupted()`:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1619-1622`
- Coordinator transitions `.live -> .recovering` on this path:
  - `ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:219-224`
- That produces a phase transition which remaps UI to `.reconnecting`.

2. Socket-close path in ProviderChatService:
- On socket close, service emits `.connectionInterrupted(...)` when `shouldNotifyDisconnect` is true, and also emits lifecycle `transportClosed`:
  - `ios/Clawline/Clawline/Services/ProviderChatService.swift:1116-1128`
  - policy-violation branch equivalent: `:1103-1110`

3. Stale VM forced disconnect (high-risk path):
- Any `ChatViewModel.onDisappear()` unconditionally calls both coordinator disconnect and `chatService.disconnect()`:
  - `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:503-504`
- If a stale VM fires this while a current VM is connected, the shared transport is torn down and active UI is driven back into reconnect flow.
- Prior diagnosis already found multiple VM generations persisting during login (`reviews/t099-three-vm-diagnosis.md`).

## Assessment
- The yellow pulse is definitively tied to `connectionState == .reconnecting`.
- Coordinator reaching `live` should clear yellow for that VM by design.
- If yellow persists indefinitely despite observed `live`, the likely disconnect is **post-live re-entry into reconnecting** (from `.connectionInterrupted` / close / forced disconnect), or a VM-generation mismatch where a stale instance is still influencing shared transport.

No fix implemented in this pass (assessment only).
