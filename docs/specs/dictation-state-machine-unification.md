# Dictation State Machine Unification

## Goal

Unify `DictationCoordinator` and `ComposeInputDictationBridge` under a single state-machine owner for the live dictation interaction timeline.

This spec is based on the confirmed current coupling:
- `DictationCoordinator.swift:1084`, `1717`, `1763`, `1779`
- `ComposeInputDictationBridge.swift:59`, `141`, `152`, `226`

Those sites show that the coordinator and bridge are already co-owning one interaction timeline: activation, selection anchoring, transcript buffering, user-edit suppression, and transcript application. The refactor makes that ownership explicit and singular.

## Non-Goals

- Do not unify `MessageInputBar` into the dictation machine.
- Do not move raw keyboard geometry ownership out of `ChatView`.
- Do not change dictation UX v2 behavior, Soniox transport behavior, timing constants, or published dictation UX invariants.
- Do not redesign `DictationMotion` in this spec.
- Do not change provider/session-routing architecture outside the dictation entry points already touched by this flow.

## Current Problem

Today the dictation product state is split across two mutable owners:

- `DictationCoordinator`
  - owns lifecycle, transport, mode, `originSessionKey`, `preDictationSnapshot`, `transcriptBuffer`, `pendingTranscriptUpdate`, `pendingActivationMode`, `isSocketConnected`, `isPhase3StreamingAudio`
- `ComposeInputDictationBridge`
  - owns `transcriptStateBySession`, `preferredSelectionRangeBySession`, `activationSelectionRangeBySession`, and user-edit suppression behavior

That split is structurally wrong because the bridge state is not merely rendering state. It decides:
- where dictation owns text
- what provisional text span may be rewritten
- when user edits suppress the next endpoint commit
- what insertion anchor survives gesture/focus churn

Those are dictation domain invariants, not UI helper concerns.

## Design Summary

Keep `DictationCoordinator` as the single owner of dictation interaction state.

After the refactor:
- `DictationCoordinator` owns all lifecycle state and all transcript ownership state
- `ComposeInputDictationBridge` becomes a bindable text-application helper with no per-session dictation memory
- `ChatView` projects dictation state and reports raw UI observations; it does not co-own dictation behavior
- `MessageInputBar` becomes a gesture adapter that emits intents and applies local UIKit interaction locks, but does not own dictation semantics

This is one state machine with thin adapters, not one giant UIKit god object.

## Unified Machine

### Owner

`DictationCoordinator` remains the owner type unless renamed in a later cleanup. Renaming is not part of this spec.

### Public Contract

The published external contract remains conceptually similar to the current one:
- `surfaceTarget`
- `mode`
- `isListening`
- `errorMessage`
- `audioLevel`
- key-prompt / key-status projections already exposed today

The UI must continue to consume projections, not internal lifecycle details.

Internal lifecycle details remain private.

### Concurrency and Isolation

All unified machine state mutations are `@MainActor`.

Rules:
- transport callbacks, audio events, timer completions, and gesture callbacks must hop onto `@MainActor` before mutating machine state
- `TranscriptOwnership`, `PendingAction`, and lifecycle phase are never mutated off-main
- the text helper is also `@MainActor`, but it is write-only with respect to the machine; it may not mutate machine state directly
- UI callbacks caused by machine-authored text application must re-enter the machine through explicit guarded observation paths, not implicit delegate side effects

This is mandatory. The unification refactor is not allowed to introduce a second serialization mechanism or ad hoc locking layer.

## State Model

The unified machine owns one internal state model composed of:
- lifecycle phase
- transcript ownership
- pending stop action
- UI interaction policy projection inputs captured from adapters

### 1. Lifecycle Phase

`LifecyclePhase`:
- `idle(surface: SurfaceTarget)`
- `prewarming(mode: DictationMode, trigger: ActivationTrigger)`
- `listening(mode: DictationMode)`
- `paused`
- `finalizing(pendingAction: PendingAction, pendingSurface: SurfaceTarget)`
- `error(surface: SurfaceTarget, message: String)`

Notes:
- `finalizing` is internal only and never leaks directly to UI.
- `surfaceTarget` may still project immediately from intent while internal phase is `finalizing`, preserving current dictation architecture behavior.

### 2. Transcript Ownership

`TranscriptOwnership`:
- `inactive`
- `active(TranscriptSession)`

`TranscriptSession` owns:
- `originSessionKey`
- `baseSnapshot: ComposeDraftSnapshot`
- `dictationStartUTF16`
- `committedText`
- `committedLenUTF16`
- `provisionalText`
- `suppressedUntilNextEndpoint`
- `pendingUpdate: DictationSegmentUpdate?`
- `activationSelectionRange: NSRange?`
- `preferredSelectionRange: NSRange?`
- `walkieOrigin: WalkieOrigin?`

This replaces all bridge-owned per-session dictionaries and transcript state.

### 3. Pending Stop Action

`PendingAction`:
- `none`
- `pause(reason: String)`
- `dismiss(reason: String)`
- `send(reason: String)`
- `stopKeep(reason: String)`
- `transportFailure(stage: String)`
- `protocolError(code: String?, message: String)`

This makes stop/finalize outcome explicit rather than scattering it across ad hoc flags and callbacks.

### 4. Captured UI Context

The machine may store the minimal UI context needed to preserve current behavior:
- `keyboardWasVisibleAtActivation`
- `editorWasFocusedAtActivation`
- `activationSource` (`micButton`, `pushGesture`, `voiceOverAction`, `resume`, etc.)

This is input metadata, not UI ownership.

## Owned Invariants

After the refactor, these invariants are mandatory:

1. `DictationCoordinator` is the only owner of transcript insertion authority.
- No other type may persist dictation-owned insertion range, provisional span, or endpoint-suppression state.

2. `originSessionKey` and transcript ownership are inseparable.
- If one exists, the other exists.
- If transcript ownership is inactive, `originSessionKey` must not survive elsewhere.

3. Activation selection and preferred selection are machine-owned.
- UI may report selection observations.
- Only the machine decides which one becomes the insertion anchor.
- During active dictation, every user-authored caret movement or text selection reported by the compose adapter becomes the authoritative insertion/replacement anchor for subsequent dictated text in that transcript session.
- Dictation may preserve committed/provisional ownership prefix internally, but it must not continue inserting at a stale activation anchor after a valid user selection observation.
- If the reported selection has nonzero length, the next machine-authored dictation application must replace that selected range with the newly dictated suffix or segment; it must not append elsewhere or clear the selection before consuming it as the replacement anchor.

4. User edits during active dictation are machine-handled.
- Suppression-after-edit behavior is domain state and may not live in a helper object.
- While dictation is paused but the dictation interaction remains active, compose selection changes and user edits are still domain observations.
- Paused-state observations must update coordinator-owned transcript ownership exactly as active observations do unless the interaction has explicitly ended.

5. Endpoint commits and provisional revisions flow through one mutation seam.
- Token buffering, coalescing, suppression, and text replacement planning all originate in the machine.

6. Machine-authored text application must suppress re-entrant user-edit and selection callbacks.
- The machine owns the rule that programmatic dictation replacement does not feed back as a fresh user edit.
- The text helper may implement the local UIKit guard mechanics, but only under machine-directed policy.

7. `ComposeInputDictationBridge` stores no session-keyed dictation state.
- No `transcriptStateBySession`
- No `preferredSelectionRangeBySession`
- No `activationSelectionRangeBySession`

8. If the compose surface is temporarily unavailable, transcript ownership remains in the machine.
- Surface rebinding must not reset transcript ownership.
- On rebind, the helper re-applies the machine-authored current transcript session to the new surface.

9. Attachment preservation and prefix-mismatch recovery remain machine-specified behavior.
- If the live compose content diverges from `baseSnapshot`, the machine must still define the fallback replacement behavior.
- Attachment state restoration remains part of the compose draft contract.

10. UI never reads internal finalization state.
- UI reads the published projection only.

11. Keyboard state is preserved, not dictated.
- The machine may remember activation-time UI context, but it does not own keyboard visibility.

## Transition Model

### Activation

Commands:
- `startSticky`
- `startWalkieTalkie`
- `resume`
- `beginGesturePrewarm`

Transitions:
- `idle(surface: .closed|.open)` -> `prewarming(...)`
- `paused` -> `prewarming(mode: .sticky, trigger: .resume)`

On activation:
- capture current session key
- capture compose snapshot
- capture activation / preferred selection as applicable
- initialize `TranscriptOwnership.active(...)`
- reset token buffer / pending update state
- project `surfaceTarget` immediately per current UX rules

### Transport Ready / Listening

Transitions:
- `prewarming` -> `listening(mode)`

On entry:
- audio capture and Soniox transport become active
- transcript ownership remains the same active session

### Token Receipt

Input:
- Soniox response tokens / finished / endpoint markers

Behavior:
- machine updates transcript buffer
- machine merges/coalesces pending updates
- machine decides immediate vs delayed flush
- machine computes resulting transcript ownership state
- machine instructs the text helper to apply the computed delta

There is no second state machine interpreting the update afterward.

### User Edit / Selection Change

Inputs:
- `selectionChanged(selectionRange)`
- `userEdited(editedRangeUTF16, replacementUTF16Length)`

Behavior:
- applies during both `listening` and `paused` while transcript ownership is active
- machine updates transcript ownership directly
- machine adjusts suppression and insertion anchor directly
- a valid caret movement becomes the next dictated insertion anchor
- a valid nonempty selection becomes the next dictated replacement range
- helper does not make independent policy decisions

### Stop / Pause / Dismiss / Send / Error

Inputs:
- explicit user stop
- send tapped
- pull-to-send
- dismiss gesture
- transport failure
- protocol error
- inactivity timeout
- max duration timeout
- interruption

Transitions:
- `listening` -> `finalizing(pendingAction: ..., pendingSurface: ...)`
- `prewarming` -> `idle` or `error` depending on current rules
- `finalizing` -> `paused`, `idle(surface: .open|.closed)`, or `error(...)`

Rules:
- `surfaceTarget` may project immediately from pending intent
- final transcript flush happens before the pending action resolves
- transcript ownership is cleared only when the stop outcome actually ends the current dictation interaction

### Stream Switch Guard

If active dictation ownership exists and `currentSessionKey` no longer matches `originSessionKey`, the machine remains the sole owner of the stop decision and cleanup path.

`ChatView` and the text helper do not implement independent stream-switch transcript logic.

## What the Bridge Becomes

`ComposeInputDictationBridge` stops being a state machine.

It becomes a bindable text-application helper. Rename is optional; shrinking its responsibility is mandatory.

### Allowed Responsibilities

- hold weak references to the host / current compose text view
- bind / unbind to the current compose surface
- capture a `ComposeDraftSnapshot`
- apply a caller-provided text delta to the compose text view or host
- restore a caller-provided snapshot
- expose raw compose-view observations needed by the machine, if convenient
- perform local UIKit guard mechanics for machine-authored text replacement

### Forbidden Responsibilities

- storing per-session transcript state
- storing insertion anchors across events
- storing activation/preferred selection state
- deciding suppression-after-edit behavior
- deciding how committed/provisional text is interpreted

### Replacement Contract

Conceptually:
- input: `TextApplicationPlan`
- output: apply exactly that plan to the compose surface

`TextApplicationPlan` includes:
- target session key
- base snapshot
- replacement range or previous transcript length
- replacement attributed text
- cursor movement policy
- whether this apply must suppress re-entrant user-edit / selection callbacks

The helper applies; it does not decide.

### Surface Rebinding Contract

The helper is allowed to be temporarily unbound from a live `UITextView`.

Required behavior:
- if the compose view is recreated, the helper may unbind without clearing transcript ownership
- while unbound, the machine continues to own transcript state and may continue buffering/coalescing updates
- on rebind, the helper must apply the machine-authored current transcript session to the newly bound compose surface
- rebinding is not allowed to invent a new insertion anchor or clear suppression state

## ChatView Cleanup

`ChatView` keeps ownership of raw view/container concerns:
- keyboard height
- keyboard animation metadata
- focus observation
- local layout and motion plumbing

`ChatView` must stop co-owning dictation semantics.

### ChatView Reads

`ChatView` reads projected dictation state such as:
- `surfaceTarget`
- `isListening`
- `mode`
- `errorMessage`
- `swipeActivationEnabled`
- explicit interaction-policy projection if needed

### ChatView Writes

`ChatView` may only report observations and user intents:
- active session key changes
- context terms
- input focus changes
- keyboard visibility observations
- user actions (send tapped, backgrounded, etc.)

### ChatView Must Not Own

- transcript routing logic
- stream-switch transcript guards
- focus-restore policy as dictation product state
- stop/finalize sequencing
- insertion-anchor semantics

If `ChatView` needs a behavior, it should come from a projected dictation policy or an explicit machine command.

## MessageInputBar Adapter Contract

`MessageInputBar` remains the adapter for gesture recognition and local UIKit interaction locking.

It should not own dictation semantics.

### Adapter Inputs

From the machine:
- `surfaceTarget`
- `mode`
- `isListening`
- `swipeActivationEnabled`
- `shouldLockTextViewGesturesDuringDictationDrag`
- `shouldKeepKeyboardStateUnchanged`

These may be grouped into a thin `DictationInteractionProjection`.

### Adapter Outputs

To the machine:
- `gestureBegan(context: GestureContext)`
- `gestureSelectionObserved(selectionRange)`
- `gesturePrewarmRequested(kind: .sticky | .walkie)`
- `gestureCommitRequested(action: GestureCommitAction)`
- `gestureCancelled`
- `composeSelectionChanged(selectionRange)`
- `composeUserEdited(editedRangeUTF16, replacementUTF16Length)`

`GestureContext` may include:
- start location
- whether the editor was focused
- whether the keyboard was visible
- current selection range

### Local-Only Adapter Responsibilities

These remain in `MessageInputBar`:
- hit testing
- pan intent classification from raw UIKit gesture data
- temporary disabling/restoring of `UITextView` gesture recognizers
- local geometry capture

Those are adapter mechanics, not product ownership.

## Migration Path

This refactor can be done incrementally.

It is not a full flag day, but it does require one explicit ownership cutover where transcript state stops living in the bridge.

### Phase 1: Introduce Unified Transcript Ownership in `DictationCoordinator`

- Add `TranscriptOwnership` and related structs inside `DictationCoordinator`
- Introduce shadow transcript state there for validation without changing the authoritative owner yet
- No public API change

Exit condition:
- coordinator can represent all transcript ownership state without consulting bridge dictionaries

### Phase 2: Flip Full Transcript Ownership

- Move the full `TranscriptSession` authority into coordinator in one cutover:
  - activation selection
  - preferred selection
  - suppression-after-edit
  - insertion anchor
  - committed/provisional transcript text
  - pending transcript update
  - walkie-origin routing state tied to the active transcript session
- `MessageInputBar` and `ChatView` continue sending the same observations/commands
- Bridge stops storing session-keyed selection/transcript state

This is the atomic cutover phase.

Exit condition:
- all transcript ownership mutations occur in coordinator only

Rollback rule:
- Phase 2 must land as a single isolated ownership-flip commit.
- If production or device validation finds transcript ownership regressions, revert the entire Phase 2 commit as one unit.
- Do not introduce a runtime dual-owner fallback path.

### Phase 3: Shrink the Bridge to a Text Helper

- Replace bridge policy methods with text-application methods
- Remove state dictionaries and transcript interpretation logic
- Bridge becomes a bindable helper with only ephemeral UI references to host/text view

Exit condition:
- bridge applies plans but does not derive them

### Phase 4: Clean Up `ChatView`

- Remove any remaining dictation-semantic gating from `ChatView`
- Narrow `updateContext(...)` or equivalent APIs so `ChatView` reports observations instead of shaping behavior
- Keep keyboard/focus/layout ownership local

Exit condition:
- `ChatView` is projecting state and sending intents, not deciding transcript/session behavior

### Phase 5: Narrow `MessageInputBar` Contract

- Convert any remaining dictation-specific side effects into explicit intent emissions
- Keep only local gesture/UI lock mechanics in the view layer

Exit condition:
- `MessageInputBar` is a gesture adapter, not a dictation controller

## Incremental Safety Rules

During migration:

1. There must never be two live owners of any `TranscriptSession` field after Phase 2 begins.
2. Phase 1 mirroring may exist only as non-authoritative shadow state for validation; behavior still comes from the existing owner until the Phase 2 cutover commit.
3. After the Phase 2 cutover commit, the bridge may not persist committed text, provisional text, insertion anchor, suppression state, or pending transcript updates.
4. The bridge may temporarily forward raw observations, but not persist dictation policy state after Phase 2.
5. The external UI contract must remain stable until the bridge ownership cutover is complete.

## Acceptance Checks

The implementation is correct only if all of the following are true:

1. `DictationCoordinator` is the sole owner of transcript ownership state.
2. `ComposeInputDictationBridge` contains no per-session dictation dictionaries.
3. User edits during active dictation mutate coordinator-owned state only.
4. Selection anchoring for activation and re-anchoring lives in coordinator-owned state only.
5. `ChatView` does not implement transcript/session guard logic.
6. `MessageInputBar` emits intents and applies local UI locks, but does not own dictation product transitions.
7. The machine serialization boundary is explicit and all state mutation occurs on `@MainActor`.
8. Machine-authored text application suppresses re-entrant user-edit / selection feedback correctly.
9. Rebinding the compose surface does not reset transcript ownership or lose buffered/provisional text.
10. Send does not close the dictation surface.
11. Dictation does not force keyboard dismiss or keyboard show.
12. Internal finalization state remains private while `surfaceTarget` may project immediately from user intent.
13. `originSessionKey` remains machine-owned and stream-switch cleanup remains machine-owned.
14. Walkie-origin routing remains machine-owned and preserved across the new transcript session model.
15. Attachment state and prefix-mismatch compose recovery still work under transcript replacement.
16. During active dictation, moving the caret or selecting a substring changes where the next dictated suffix or segment is inserted or replaced.
17. During paused dictation, moving the caret or selecting a substring before resume preserves transcript ownership and keeps subsequent resumed tokens applying to the input field at that updated anchor.

## Open Questions

1. Should the owner type remain `DictationCoordinator`, or be renamed to `DictationSession` / `DictationStateMachine` after behavior is stable?
2. Should text-view focus/dismiss helpers stay with the text helper temporarily, or move into a separate compose-view adapter in the same refactor?
3. Does `DictationMotion` need a follow-on cleanup spec after this ownership refactor, or is the current projection boundary sufficient?

## Implementation Handoff

Scope boundary:
- This spec unifies `DictationCoordinator` and `ComposeInputDictationBridge`.
- It does not redesign the gesture model, motion model, or keyboard layout system.

Risk boundary:
- The highest-risk cutover is Phase 2, when transcript ownership stops living in the bridge.
- Treat any second writer of selection anchor, provisional span, or suppression state as a blocking structural bug.

Required regression coverage:
- activation with selected text
- provisional transcript rewrite
- endpoint commit after user edit suppression
- stream switch during dictation
- send during active dictation
- dismiss during finalization
- keyboard-up and keyboard-down activation parity
- compose view recreate / rebind during active dictation
- dictation replacement while attachments are present
- prefix-mismatch fallback during transcript apply
