# Dictation Merge Conflict Analysis

Repo: `/Users/mike/src/clawline-dictation`
Branch: `feature/voice-dictation`

Question answered: for each high-risk overlap file, do main’s changes actually contradict/break the dictation changes, or are they orthogonal additions that can coexist?

Baseline:

- merge base: `c10be684bdb5b39cb061b2fd86e6a9327bfd376a`
- main-only range: `HEAD..origin/main`
- branch-only range: `origin/main..HEAD`

## Short Answer

- `MessageInputBar.swift`: **orthogonal**
- `ChatView.swift`: **mostly orthogonal**
- `RichTextEditor.swift`: **one real behavioral contradiction**

The only actual contradiction I found is in the new main-side typing-activity callback path. If merged naively, dictated programmatic transcript updates would be treated as user typing.

## 1. `MessageInputBar.swift`

### What main changed

Main added:

- `fontScaleChangeSequence`
- `onTextEditActivity`
- cached bar width recalculation via `refreshMaxBarWidth()`
- `UIFont.clawline(.bodyText)`-based sizing/placeholder rendering

Representative main-only commits:

- `16ccf287f T168 reduce typing latency`
- `0f6710026 Fix live font scale rerender across chat views`

### What we changed

The branch changed `MessageInputBar` into the dictation gesture/intent adapter:

- `DictationInteractionProjection`
- `DictationInteractionEmitter`
- pan intent classification
- gesture locking and teardown behavior
- dictation-specific interaction contracts and motion wiring

### Do main’s changes contradict dictation?

**No.**

Main’s additions are UI/editor ergonomics:

- font-scale propagation
- max-width recalculation
- a generic text-edit activity callback

Those do not change:

- dictation gesture classification
- transcript ownership
- dictation state projection
- dictation stop/start semantics

### Verdict

`MessageInputBar.swift` is **same-file, different-concern** overlap. Main’s changes can coexist with the dictation changes.

The only caveat is that `onTextEditActivity` becomes behaviorally meaningful once it is wired through `RichTextEditor`; that tension is not created in `MessageInputBar` itself.

## 2. `ChatView.swift`

### What main changed

Main added two clusters:

1. Track/untrack UI flow
- `isTrackPickerPresented`
- `TrackPickerSheet`
- adopted-stream presentation / dismissal plumbing
- focus restoration after the track picker closes

2. Font-scale / typing-activity plumbing
- `fontScaleChangeSequence`
- `settings.fontScaleToastSequence`
- `isTypingActive`
- `typingActivityResetTask`
- `recordTypingActivity()`
- `clearTypingActivity()`
- `ToastBanner` action wiring
- passes `fontScaleChangeSequence` and `onTextEditActivity` into the editor/input stack

Representative main-only commits:

- `cb72c6991 Refine stream manager track controls and keyboard gap`
- `935f4e7a6 Add Track adoption ceremony and undo`
- `b023e2d4e Fetch trackable sessions for Track flow`
- `6671b662c Wire font scale toast and reset shortcut`
- `0f6710026 Fix live font scale rerender across chat views`
- `16ccf287f T168 reduce typing latency`

### What we changed

The branch changed `ChatView` to own the dictation UI seam:

- builds `DictationInteractionProjection`
- routes `DictationInteractionIntent` to `DictationCoordinator`
- owns dictation observation/projection instead of letting UI children co-own behavior
- wires the unification contract into `MessageInputBar`

### Do main’s changes contradict dictation?

**Mostly no.**

Track-picker work is orthogonal to dictation. It affects stream management, popup presentation, and focus restoration after that modal closes. That does not redefine dictation semantics.

Font-scale toast wiring is also orthogonal to dictation.

The only real tension here is downstream of main’s new typing-activity model:

- main’s `ChatView` uses `isTypingActive` to drive `MessageFlowCollectionView`
- in main, `isTypingActive` is fed from `onTextEditActivity`
- if that callback fires for dictated programmatic transcript updates, then dictation updates would incorrectly look like “active typing” to the message list

That is not a contradiction in the track-picker or font-scale work. It is a contradiction in the typing-activity path when paired with our dictation-driven editor mutations.

### Verdict

`ChatView.swift` is **mostly orthogonal**, with one dependent risk:

- track picker: orthogonal
- font-scale toast: orthogonal
- typing-activity path: only safe if `RichTextEditor` suppresses activity reporting for programmatic dictation updates

So `ChatView` itself does not directly break dictation, but one of its new integrations depends on a guard in `RichTextEditor`.

## 3. `RichTextEditor.swift`

### What main changed

Main added:

- `fontScaleChangeSequence`
- `onTextEditActivity`
- `UIFont.clawline(.bodyText)` usage
- base-attribute reapplication keyed by font-scale changes

Representative main-only commits:

- `16ccf287f T168 reduce typing latency`
- `0f6710026 Fix live font scale rerender across chat views`

Critically, main’s diff adds:

- `parent.onTextEditActivity?()` in `textViewDidChange(_:)`

### What we changed

The branch uses `RichTextEditor` as part of the dictation insertion seam:

- programmatic dictation update flags on `PastableTextView`
  - `dictationProgrammaticUpdateInFlight`
  - `dictationProgrammaticEditInFlight`
- selection suppression after programmatic transcript replacement
- `onUserEdit` callback in `shouldChangeTextIn`
- `onTextViewReady`
- direct cooperation with `DictationTranscriptApplicator` / `DictationCoordinator`

### Do main’s changes contradict dictation?

**Yes, one part does.**

The font-scale rerender changes are orthogonal.

The contradiction is `onTextEditActivity` in `textViewDidChange(_:)`.

Why:

- our dictation path performs programmatic text replacement into the live `UITextView`
- those replacements can trigger `textViewDidChange(_:)`
- main’s callback, as written, is generic and would report those updates as user typing
- main’s `ChatView` then turns that into `isTypingActive`
- main’s `MessageFlowCollectionView` uses `isTypingActive` to defer updates during active typing

That means a naive merge would blur two different behaviors:

- user typing
- programmatic transcript insertion/replacement

For dictation, those are not equivalent.

This is an actual behavioral contradiction, not just same-file overlap.

### Specific reason this matters

Our branch already distinguishes user edits from programmatic dictation edits in `shouldChangeTextIn`:

- `onUserEdit` only fires when `dictationProgrammaticEditInFlight` is false

Main’s new `onTextEditActivity` path bypasses that distinction because it lives in `textViewDidChange(_:)`, not in the guarded user-edit path.

### Verdict

`RichTextEditor.swift` contains the one **real merge-semantic conflict**:

- font-scale changes: orthogonal
- typing-activity callback: **contradicts dictation semantics unless guarded**

## Final Conclusion

If the merge were done carefully:

- `MessageInputBar.swift`: can coexist
- `ChatView.swift`: can coexist, except that its typing-activity wiring depends on the editor guard
- `RichTextEditor.swift`: needs an explicit semantic merge, because main’s new activity callback would otherwise misclassify dictated transcript application as typing

So the honest answer is:

- there is **not** a broad architectural contradiction between main and the dictation work
- there **is** one concrete behavioral contradiction in the `RichTextEditor` typing-activity path

Everything else in these three files is an orthogonal addition, not a competing dictation model.
