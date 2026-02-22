# Emacs-Style Ctrl Shortcuts for Hardware Keyboard Input Bar

Implements Clawline GitHub issue #43.

## Goal
Add Emacs-style `Ctrl` shortcuts to the Clawline iOS input bar so hardware-keyboard users can edit compose text without leaving the keyboard, matching Helm behavior.

## Non-Goals
- Adding `Alt`/`Option` or `Command` shortcut features beyond this issue.
- Reworking existing return/send, paste, dictation, or autocomplete behavior.
- Implementing global shortcuts outside the input text view.

## Scope
- iOS input bar text view used by `MessageInputBar`.
- Shortcut handling only while the input text view is first responder and enabled.
- Registration via `UIKeyCommand` overrides on the input text view subclass.

## Behavioral Requirements

### Activation + Registration
- Register commands by overriding `keyCommands` on the input text view subclass.
- Include `super.keyCommands` in the returned array to preserve system/default behavior.
- Shortcuts must execute only when both are true:
  - Input view is first responder.
  - Input is enabled.
- If input is disabled, do not handle these commands.

### Shortcut Contract

1. `Ctrl-A`
- Move insertion point to beginning of input.
- Collapse any existing selection to location `0`.

2. `Ctrl-E`
- Move insertion point to end of input.
- Collapse any existing selection to end of document.

3. `Ctrl-W`
- If selection is active (non-empty), delete selection and stop.
- Otherwise perform Unix-style backward kill-word:
  1. Start at insertion point.
  2. Skip trailing whitespace immediately before cursor.
  3. Delete contiguous non-whitespace run before that.
- No-op if nothing exists to delete.

4. `Ctrl-U`
- Delete from insertion point to beginning of input.
- Mirror Helm behavior for selections by using `selectedTextRange.start` as cursor anchor.
- No-op when already at beginning.

5. `Ctrl-K`
- Delete from insertion point to end of input.
- Mirror Helm behavior for selections by using `selectedTextRange.start` as cursor anchor.
- No-op when already at end.

6. `Ctrl-C`
- Clear entire input content (full document delete), regardless of current selection.

## Edge Cases + Invariants
- Empty input: all delete shortcuts are safe no-ops except `Ctrl-C`, which is also effectively no-op.
- Selection handling:
  - `Ctrl-W` deletes active selection first (explicit requirement).
  - `Ctrl-U`/`Ctrl-K` follow Helm anchor semantics (`selectedTextRange.start`).
  - `Ctrl-A`/`Ctrl-E` collapse selection to boundary.
- Whitespace definition for `Ctrl-W` follows Swift `Character.isWhitespace`.
- Must preserve existing keyboard features:
  - Standard text system commands from `super.keyCommands`.
  - Existing return/send behavior in `shouldChangeTextIn`.
  - Existing paste/image interception behavior in `PastableTextView`.
  - Existing dictation and other input-system behaviors (no broad key event interception that swallows unrelated keys).
- Must not crash on marked text/IME composition; rely on `UITextInput` range APIs and guard nil ranges.

## Reference Implementation Pointers

Primary behavior source (Helm):
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:81`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:100`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:142`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:187`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:193`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:199`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:208`
- `/Users/mike/src/Helm/Helm/Features/Chat/Components/ChatViewHelpers.swift:216`

Likely Clawline integration points:
- `/Users/mike/src/clawline/ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift:298` (`PastableTextView`)
- `/Users/mike/src/clawline/ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/RichTextEditor.swift:310` (text view init/config)
- `/Users/mike/src/clawline/ios/Clawline/Clawline/DesignSystem/ChatFlowOrganic/Components/MessageInputBar.swift:283` (`RichTextEditor` use site)

## Design Notes (Implementation Direction)
- Extend the existing text view subclass used by `RichTextEditor` (`PastableTextView`) rather than introducing a parallel compose view stack.
- Add a local enabled-state property for keyboard-command gating (Helm-style `isInputEnabled`), mapped from compose enabled/editable state.
- Implement each command using `UITextInput` APIs (`selectedTextRange`, `textRange(from:to:)`, `replace`) for cursor-safe edits.
- Keep command handlers narrow and side-effect free: edit text only; do not alter send state, focus ownership rules, or layout behavior.

## Acceptance Criteria
- All six shortcuts function exactly per behavior contract above on hardware keyboard.
- Commands fire only while compose text view is focused and enabled.
- No regressions in existing input behaviors (typing, send/newline handling, paste pipeline, dictation).
- `Ctrl-W` deletes active selection when selection exists.

## Test Plan

### Manual Hardware-Keyboard Matrix
Run on iPad simulator + at least one physical iPad keyboard setup.

1. Focus + enabled gating
- With input focused: shortcuts are active.
- With input unfocused: shortcuts do nothing to input.
- With input disabled: shortcuts do nothing to input.

2. `Ctrl-A` / `Ctrl-E`
- Cursor mid-string -> jumps to start/end.
- Active selection -> selection collapses to boundary.

3. `Ctrl-W`
- Cursor after `"foo   "` -> deletes `"foo   "` (skip trailing spaces then word).
- Cursor after `"foo bar"` -> deletes `"bar"`.
- Active selection -> deletes selection (not kill-word algorithm).
- Cursor at start -> no-op.

4. `Ctrl-U`
- Cursor mid-string -> deletes prefix only.
- Cursor at start -> no-op.
- With selection -> behavior matches Helm (`selectedTextRange.start` anchor).

5. `Ctrl-K`
- Cursor mid-string -> deletes suffix only.
- Cursor at end -> no-op.
- With selection -> behavior matches Helm (`selectedTextRange.start` anchor).

6. `Ctrl-C`
- Clears entire input from any cursor/selection state.

7. Regression checks
- Return key still sends according to current send guard logic.
- Paste text/images still works with existing sanitization/attachment flow.
- System keyboard shortcuts and text editing commands still work.
- Dictation and IME composition still function without crashes or stuck focus.

### Optional Unit Coverage
- If `Ctrl-W` boundary logic is factored into a pure helper, add unit tests for whitespace and word-boundary cases.

## Open Questions
1. What is the canonical "enabled" source of truth for compose shortcuts in Clawline?
- Current `MessageInputBar` passes `isEditable: true` to `RichTextEditor` even while sending (`MessageInputBar.swift:290`), so implementation may need an explicit enabled prop instead of relying on current `isEditable`.

2. Should `Ctrl-C` always clear input when dictation is active, or should it be ignored/repurposed during active dictation mode?
- This spec assumes "always clear input" per issue request; confirm if dictation-specific behavior is desired.

## Implementation Handoff
- In scope: input text view keyboard command registration and handlers for the six shortcuts.
- Out of scope: redesigning message send flow, dictation state machine, or non-compose keyboard shortcut systems.
- Main risk: accidental key handling regressions from overriding `keyCommands`; mitigation is preserving `super.keyCommands` and validating regression checklist above.
