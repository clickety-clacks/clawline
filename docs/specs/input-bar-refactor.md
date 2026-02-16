# MessageInputBar Refactor Spec (Lightweight)

## Goal
Refactor the input bar to establish a durable pattern with minimal architecture overhead:

1. Keep connection-state UI strictly in send control.
2. Keep editor chrome (text field visuals) connection-state agnostic.
3. Make this separation obvious in code shape so future changes follow it.

## Current Problems
1. `MessageInputBar` still concentrates too many concerns in one body (editor chrome, send-state UI, platform branches, layout).
2. This monolithic pattern is easy for future edits to copy, which risks reconnecting connection state to input chrome.
3. We need a stronger pattern signal than comments alone, but less ceremony than a new formal style type hierarchy.

## Proposed Architecture (Minimum Viable Pattern)

### 1) Two extracted subviews + thin shell

#### `MessageEditorChrome`
Owns only:
1. Rich text editor bindings.
2. Editor shape/height rendering.
3. Editor chrome visuals (tint/text/background/stroke) and sending opacity.
4. Focus and submit wiring.

Must not accept:
1. `SendButtonConnectionState`
2. Connection/error status strings.

#### `MessageSendControl`
Owns only:
1. Send/cancel/reconnect behavior.
2. Dot/icon morph and pulse animation lifecycle.
3. Connection-state accessibility labels.

May depend on:
1. `SendButtonConnectionState`
2. `isSending`, `canSend`

#### `MessageInputBar` (shell)
Owns composition only:
1. Appearance/add utility controls.
2. `MessageEditorChrome` + `MessageSendControl` layout.
3. Shared sizing/layout pass-through.

### 2) Editor chrome style shape (no formal type yet)
Inside `MessageEditorChrome`, define chrome as a private computed tuple (not a standalone `MessageInputChromeStyle` type) containing the small set of visual values needed now.

Rationale:
1. Provides a local single source of truth for editor chrome.
2. Avoids premature abstraction ceremony.
3. Keeps a clear upgrade path to formal type only if second call site or variant pressure appears.

### 3) Narrow platform-branch rule
1. Editor platform branches stay in `MessageEditorChrome`.
2. Send platform branches stay in `MessageSendControl`.
3. Utility control branches remain in shell or utility helpers.

No broad platform refactor beyond this boundary.

## Migration Path (Two Phases Max)

### Phase 1: Extraction and boundary setup
1. Extract `MessageEditorChrome` and `MessageSendControl` from `MessageInputBar`.
2. Keep behavior and visuals parity with current implementation.
3. Keep public call-site API stable.

### Phase 2: Boundary hardening + regression checks
1. Ensure connection state is only passed to `MessageSendControl`.
2. Ensure `MessageEditorChrome` has no connection-state input path.
3. Add regression checks for input chrome invariance across connection states.

## What Changes
1. `MessageInputBar` becomes a thin composition shell.
2. Editor and send concerns are split into separate subviews.
3. Editor chrome values are centralized as a private tuple in `MessageEditorChrome`.

## What Does Not Change
1. Chat transport/reconnect pipeline in `ChatViewModel`.
2. T069 send-button state semantics and animations.
3. Parent-level focus ownership contract in `ChatView`.

## Invariants (High-Signal)
1. Connection state cannot enter `MessageEditorChrome` API.
2. Input chrome remains identical across connection states.

## Test Strategy
1. Regression UI test/snapshot: input chrome is identical for connected/reconnecting/disconnected/failed.
2. Interaction test: send control still shows correct state transitions (send/reconnect/reconnecting pulse) and actions.
3. Device check: no input border tint or inline error text appears during connection failures.

## Risks / Adversarial Notes
1. Extraction can still regress focus/keyboard behavior if view identity changes unexpectedly.
2. Animation continuity can regress if pulse state ownership moves incorrectly.
3. Mitigation: keep parent-owned focus plumbing unchanged, preserve send-control animation behavior, and verify on device.

## Acceptance Criteria
1. `MessageEditorChrome` and `MessageSendControl` exist and are used by `MessageInputBar`.
2. `MessageEditorChrome` takes no connection-state input.
3. Input chrome does not change across connection states.
4. Send control preserves T069 behavior and animations.
