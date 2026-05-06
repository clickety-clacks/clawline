# T216 Keyboard Shortcut Architecture Retro

Date: 2026-04-24

## Product Model

- App-level command shortcuts own command-modified chat actions:
  - Cmd-L: focus/activate Prompt Input.
  - Cmd-Shift-L: next/right chat.
  - Cmd-Shift-H: previous/left chat.
  - Cmd-Shift-J/K: page-scroll down/up in the active chat.
  - Cmd-;: open the chat popup/list.
  - Plain Cmd-H is intentionally unowned by Clawline because macOS owns it for Hide.
  - Cmd-/ is intentionally unowned by Clawline.
- The hidden no-text responder owns only unmodified shortcuts that should work when no text input owns key events:
  - `/`: open/filter the chat popup.
  - Space / Return: activate Prompt Input.
- Text-input components own normal typing and editing while focused, but do not suppress app-level command shortcuts unless a command conflicts with native text editing semantics:
  - Prompt Input.
  - Popup filter.
  - Typing indicators/dialog text fields.
  - Rich text/table editors.
- Embedded interactive scroll surfaces own their internal scroll gestures and focused web input:
  - Interactive HTML bubbles.
  - Persistent web/link preview bubbles.
  - Chat-surface keyboard/page-scroll commands must not steal scroll ownership while one of these embedded web scroll responders owns first responder.

## Focus Model

- Prompt Input focus is tracked in stable `ChatView` state and reported from `MessageInputBar`.
- When Prompt Input or any other `UITextInput` owns first responder, global chat commands delivered through app command notifications still route to `ChatView`.
- Catalyst installed builds cannot rely on SwiftUI `Commands` alone for delivery. Command shortcuts are registered as `UIKeyCommand`s on the active hardware-key input owner:
  - The no-text shortcut host when no editor owns input.
  - `RichTextEditor` while Prompt Input owns input.
  - SwiftUI `Commands` remain as a menu/keyboard presentation layer, but are not the sole runtime route.
- Text input retains normal character entry and editing because no-text responder shortcuts are only unmodified `/`, Space, and Return, and those are active only when no text input owns first responder.
- When no text input or embedded web scroll surface owns first responder and the popup/sheets are closed, the no-text responder may become first responder to capture only unmodified `/`, Space, and Return.
- Popup filter/list keyboard behavior stays local to the popup while it owns focus; Up/Down/Return remain popup concerns.

## Failure Diagnosis

The pre-fix architecture mixed two shortcut domains in one hidden first-responder `UIView`:

- Unmodified no-text activation keys.
- Command-modified app commands.

That made command shortcut reliability depend on whether the hidden view happened to remain first responder and whether UIKit's `UIKeyCommand` lookup still used that responder after focus transitions. It also caused escalation patches such as `wantsPriorityOverSystemBehavior` and raw `pressesBegan` fallbacks to accumulate inside the same host. Those fallbacks made the host more stateful and increased the chance that Esc or command-key paths could perturb its first-responder state, which explains the observed pattern: command shortcuts could stop working independently, and after Cmd-L plus Esc the host could be left unable to service Space/Return.

## Routing Contract

One key gesture has exactly one owner:

- Command modifier present:
  - Cmd-L/Cmd-Shift-H/Cmd-Shift-L/Cmd-Shift-J/Cmd-Shift-K/Cmd-; route through the app-command notification bus to `ChatView`.
  - Cmd-L uses the same Prompt Input focus request seam as Space/Return, but is registered as an app command so it works in Catalyst while text input focus changes.
  - UIKit input-mode adapters register the same app-command shortcuts with `UIKeyCommand` so Catalyst and Spatial have a responder-chain route even if SwiftUI menu commands do not fire.
  - Plain Cmd-H, Cmd-/ and all other command combinations are not owned by Clawline.
  - App-level command shortcuts remain active while text input is focused unless a future shortcut explicitly conflicts with platform text editing.
- No command modifier:
  - `/`, Space, and Return route through the no-text responder only when no text input is active.
  - Everything else belongs to the active responder/text input.
- Embedded scroll owner:
  - If the current first responder belongs to an embedded `WKWebView`, the no-text responder does not activate over it.
  - Cmd-Shift-J/K chat page-scroll notifications defer, so the bubble keeps its own scroll behavior instead of having the chat surface consume the scroll command.

This keeps command shortcut registration independent from the hidden no-text responder lifecycle and prevents command and non-command shortcuts from diverging again.
