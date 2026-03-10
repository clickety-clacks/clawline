# Connection State UI

## Goal

Align Clawline error UX with GitHub issue #4 (`clickety-clacks/clawline#4`): separate event notifications from persistent state indicators, unify connection state into send-button UI, and keep toasts strictly for user-initiated failures.

## Issue #4 Alignment Matrix

- `errorBanner` dismissible red bar is removed as a connection-state surface.
- Connection state is shown in one place only: send button state variant.
- Passive connection changes do not fire toasts.
- Failed-message UI uses a single icon badge + context-menu resend.
- Resend creates a new outgoing bubble and removes the failed bubble.

## Non-Goals

- No new `unresponsive` transport state.
- No red banner, no input border alert stroke, no inline error text in input.
- No changes to server protocol or ack semantics.

## Current Code Findings (Investigation)

### WebSocket and Connection State Patterns

- `ConnectionState` is modeled as `.disconnected`, `.connecting`, `.connected`, `.reconnecting`, `.failed(Error)` in `ios/Clawline/Clawline/Protocols/ChatServicing.swift`.
- Runtime chat transport state is emitted by `ProviderChatService` and consumed by `ChatViewModel` (`ProviderChatService.connectionState` -> `ChatViewModel.handleConnectionState`).
- `ChatViewModel` currently drives reconnect scheduling/backoff and also drives connection alerts that feed UI (`connectionAlert`, `error`, toast emissions).

### Timeout / Liveness Detection

- Main chat socket path has connect/auth timeout behavior, but no heartbeat watchdog for "unresponsive while still open":
- `URLSessionWebSocketConnector` sets connect/resource URLSession timeouts.
- `ProviderChatService` uses `authTimeout` (12s) while awaiting auth result.
- Socket-close handling transitions state and triggers reconnect, but no "last message age" or ping-based dead-socket detector in chat path.
- Pairing path (`ProviderConnectionService`) has operation/pending timeouts, but this is pairing-only.
- Terminal path (`TerminalSessionService`) has its own `sendPing` loop every 15s; this is terminal-specific and separate from chat send-button state.

### Why We Are Not Surfacing "Unresponsive" in UI

- Current chat transport does not produce a reliable unresponsive signal distinct from normal slow generation.
- A synthetic unresponsive heuristic risks false positives during valid long responses.
- Per product direction, we intentionally keep a strict 3-state connection UI: connected/reconnecting/disconnected.

## UI Design

### State Mapping

- `.connected` -> Connected
- `.connecting` -> Reconnecting presentation
- `.reconnecting` -> Reconnecting presentation
- `.disconnected` -> Disconnected presentation
- `.failed(Error)` -> Disconnected presentation

### Connected

- Send button remains current visual treatment and behavior.
- Button tappable for normal send.
- Existing empty-input behavior is preserved (disabled/dimmed send affordance when there is nothing to send).

### Reconnecting

- Send button morphs into a small yellow pulsing dot.
- Dot remains center-anchored to the existing send button frame.
- Dot size target: 12pt diameter (or ~40% of send control width, whichever is smaller).
- No icon.
- Not tappable.
- Input remains editable.

### Disconnected

- Send button switches to theme red variant (design token defined for both light/dark).
- Icon is reload (`arrow.clockwise` or equivalent final token-approved glyph).
- Button tap attempts reconnection immediately and transitions to reconnecting presentation.
- Input remains editable.

## Transition and Motion Requirements

- All state transitions are smooth morphs; no hard-cut swaps.
- Required paths:
- Connected -> Reconnecting
- Reconnecting -> Connected
- Reconnecting -> Disconnected
- Connected -> Disconnected (if reconnect attempts exhaust/fail and state settles to disconnected)
- Disconnected -> Reconnecting (tap action)
- Motion should preserve button center anchor and avoid layout shift in input bar.
- Pulse animation target: 0.8s ease-in-out opacity pulse (0.4 <-> 1.0), continuous while reconnecting.

## Failed-Message Badge + Resend (Explicit)

- Replace text-style failure affordance with a single symbol badge over failed bubble.
- `MessageFailureBadge` (textual retry affordance) is removed/deprecated in this flow.
- Candidate symbol: `exclamationmark.circle` (final symbol can vary but must remain single-badge style).
- Badge sits at bubble bottom-trailing corner as an overlay.
- No toast required for passive failure marking; badge is the persistent state indicator.
- Badge tap opens context menu with one v1 action: `Resend`.
- Resend behavior is mandatory:
- New outgoing message bubble is created with a fresh client id.
- Failed bubble is removed after resend is queued.
- Resend is not in-place mutation of the failed bubble.
- Failed badges persist until explicit resend; reconnect success does not auto-clear failed state.

### Failure Classification

A message is marked failed when either condition is true:

- Message-level error references that message id.
- Connection is lost while message remains pending ack.

## Toast Policy (User-Action Only)

## Rule

- Toasts are allowed only when a user action directly failed.
- Passive transport changes update indicators silently.

## Keep Toasts (user initiated)

- Send attempt fails because client is not connected -> `"Could not send; not connected."`
- Upload attempt fails -> `"Upload failed."`
- Explicit user operation fails (for example stream operation that user invoked and that fails).

## Remove / Suppress Toasts (passive)

- Socket close / reconnect race notifications.
- Passive transitions into disconnected/reconnecting.
- Passive "connection interrupted" style notifications.
- Passive "connecting to stream" notifications.

## Implementation Constraint

- Connection-state UI must not rely on `errorBanner` or input overlay messaging to communicate transport status.

## Design Token Requirement

- Define a dedicated connection-disconnected red token in design system for light and dark modes (no raw hardcoded red in production codepaths).
- Define a dedicated reconnecting yellow token in design system for light and dark modes.

## Accessibility

- Reconnecting presentation exposes accessibility label: `"Reconnecting"`.
- Disconnected presentation exposes accessibility label: `"Disconnected. Tap to reconnect."`
- Failed-message badge exposes accessibility label: `"Message failed to send. Tap for options."`

## Acceptance Checks

- Send button alone reflects connection state in all transport states.
- No connection red banner is rendered.
- Input border does not change with connection state.
- Input text remains editable in connected/reconnecting/disconnected.
- Reconnecting and disconnected states block send action.
- Connecting and failed states use reconnecting/disconnected presentation respectively per mapping.
- Disconnected button tap attempts reconnect and visibly transitions to reconnecting.
- Failed-message badge appears on failed messages and supports context-menu resend.
- Resend creates a new bubble and removes old failed bubble.
- Toasts only appear for user-initiated failures.
- No passive state-change toasts appear during reconnect cycles.

## Implementation Handoff

- Primary files likely touched:
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
- `ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift`
- `ios/Clawline/Clawline/Views/Chat/ChatView.swift`
- `ios/Clawline/Clawline/Views/Chat/MessageBubbleUIKitView.swift`
- Keep `ChatServicing.ConnectionState` shape unchanged unless implementation discovers hard blocker.
- Preserve session-key routing invariants and existing reconnect backoff behavior.

---

## Appendix: Preserved Notes

### From: specs/t069-connection-state-full-audit-retro.md

**Connection state mutation seam violation (pre-fix):**
`connectionState` had 3 independent direct mutation paths:
1. `observeConnectionState()` stream handler
2. `reconnect()`  
3. `handle(serviceEvent: .connectionInterrupted)`

This violates architecture-principles mutation seam discipline (single mutation point). Fix: centralize all `connectionState` writes through a single `transitionConnectionState(to:)` function.

**Input bar appearance:** Border color, placeholder text, and background are NOT driven by connection state — only `MessageSendControl` (send button) maps connection state to visual tokens. Connection state's only intended visual surface is the send button area.

**Send control state mapping:**
- Connected: paperplane icon (or stop when sending)
- Reconnecting: yellow dot
- Disconnected: red reconnect icon
