# Dictation Motion Model

## Spirit
One model governs the intricate state coordination between gestures, UI presentation, and timers — providing a clear picture of what the UX should be at any point in time for the dictation and text input interface.

Every invariant, architecture decision, and implementation choice in this spec serves this principle. When in doubt, ask: "Does this make the picture clearer or muddier?"

## Goal
Define a single motion model that owns all vertical dictation interaction (drag, reveal, pull-to-send, dismiss), settled-state transitions, inset commits, and gesture-driven animation for `MessageInputBar` dictation UI.

This replaces the current scattered state writes across gesture handlers, layout callbacks, and dictation coordinator side effects.

## Non-Goals
- Redesign dictation networking, Soniox protocol, or transcript formatting.
- Change visual style choices (waveform palette, copy text, etc.) beyond motion/data-flow requirements.
- Rework unrelated chat layout systems.

## Required Invariants
These are hard invariants, not guidance.

1. Drag tracks thumb 1:1 — no multiplier, no acceleration curve.
2. Bottom inset commits only on settled state — never during drag or animation.
3. Surface visibility and inset derive from ONE source of truth — no independent signals that can disagree.
4. No layout feedback loops — gesture uses stable coordinate space, view movement cannot change gesture reference frame.
5. Text input is non-interactive during drag — cursor/selection locked while gesture active, ALWAYS unlocked on gesture end including cancellation/abandonment.
6. Pull-to-send is the same gesture continuum — one model, continuous thresholds, no competing animation sources.
7. Waveform stays alive during pause — audio capture drives amplitude even when Soniox disconnected.
8. Waveform period decreases with amplitude — louder = taller AND faster waves.
9. Inactivity timeout resets on Soniox token receipt — not audio amplitude.
10. `originSessionKey` must be restored on resume after stream switch — no silent transcript drops.
11. Waveform amplitude curve must be fast-rising then asymptotic to panel max height (tanh/log-like): normal speech fills most of the surface; loud speech approaches but never clips panel bounds.
12. Waveform period scaling curve is intentionally different from amplitude curve: frequency increases with amplitude without asymptotic ceiling, while amplitude remains bounded by panel height.
13. Phone sleep is prevented during active dictation (`UIApplication.shared.isIdleTimerDisabled = true`) and restored to `false` on stop/collapse/dismiss.
14. Pager indicator (stream dots) is motion-coupled to the input bar as one rigid visual unit during drag and settle; no independent pager motion.
15. On gesture release, input bar + dictation surface must animate smoothly to resting detent with spring physics; no teleport/snap.
16. Drag-up continuum (reveal + pull-to-send) must be draggable from both the text input bar and the dictation surface; the whole bottom composer region is one drag target.
17. ALL dictation stop/pause paths must enter a finalization hold and wait for Soniox final tokens (`finished`) or timeout before executing pending actions; never act before final token window completes.
18. First dictation attempt must not accidentally trigger walkie-talkie mode during a normal push-up reveal gesture.
19. First dictation attempt reliability must match subsequent attempts; cold-start audio/connection issues that self-resolve on retry must be internally retried and not surfaced as immediate user-facing errors.
20. Pull-to-send must respect exactly the same enabled/disabled/error gating as the send button; if send is disabled, pull-to-send cannot fire.
21. Text-editing gestures and dictation drag gestures must coexist without conflict: cursor drag/pickup and selection-handle drags inside focused text editor must never arm dictation drag, while dictation drag remains available from non-text-edit gesture origins in the bottom composer region.

## Architecture

### Single Owner
Create a single `@MainActor` motion owner (proposed: `DictationSurfaceMotionModel`) that is the only writer for:
- current drag translation (`dragY`)
- gesture lifecycle (`gesturePhase`)
- settled surface state (`collapsed`, `openPaused`, `openListening`)
- pull-to-send arming/progress
- committed bottom inset target
- transient visual offset used during active drag and spring settle

`MessageInputBar` reads this model; it does not derive competing local state for these same concerns.

### Mutation Seam
All vertical motion mutations go through model methods only:
- `gestureBegan(originWasOpen:)`
- `gestureChanged(globalTranslationY:, velocityY:)`
- `gestureEnded(globalTranslationY:, predictedY:, velocityY:, context:)`
- `gestureCancelled()`
- `setListeningState(...)` (from coordinator state changes)
- `commitSettledState(...)` (single place that commits inset)

No direct writes to `surfaceInteractiveProgress`, pull-to-send booleans, or inset toggles outside this seam.

## State Model

### Stored State
- `gesturePhase: .idle | .dragging | .settling`
- `settledSurface: .closed | .openPaused | .openListening`
- `dragTranslationY: CGFloat` (global-space translation; negative is upward)
- `visualOffsetY: CGFloat` (applied transform)
- `isTextInteractionLocked: Bool`
- `pullToSendProgress: CGFloat` (`0...1`)
- `isPullToSendArmed: Bool`
- `originAtGestureStart: .closed | .open`
- `pendingCommit: SettledCommit?`

### Derived State (read-only)
- `isSurfaceOpen = settledSurface != .closed || gesturePhase != .idle && visualOffset indicates reveal`
- `bottomInsetTarget = f(settledSurface)` only
- `micVisible = !isSurfaceOpen && textEmpty && !textFocused` (existing mic policy remains source-compatible)
- `dictationVisualProgress = clamp(revealDistance / revealThreshold)`

## Gesture Pipeline

### Coordinate Space
Use global coordinate space for drag translation and keep it as raw finger delta. The moving view must not redefine the gesture reference frame.

### 1:1 Tracking
During `.dragging`, `visualOffsetY` is a direct transform of raw drag delta with no scaling multiplier and no acceleration.

### Continuum
One vertical gesture continuum:
- Region A: below reveal threshold => collapse intent
- Region B: reveal region => open surface intent
- Region C: above send threshold => arm send intent

Thresholds are evaluated in one place in `gestureChanged/Ended`; no parallel animation source can independently arm/disarm send.

### End/Cancel
Both `gestureEnded` and `gestureCancelled` must call the same teardown path:
- unlock text interaction
- clear gesture start tracking
- reset transient pull-to-send visuals
- enter spring settle to chosen detent (no snap/teleport)

No code path is allowed to skip this teardown.

## Insets and Layout

### Commit Discipline
Bottom inset is never changed while `gesturePhase == .dragging` or `.settling`.

Inset commit occurs only in `commitSettledState` after spring completion callback (or equivalent deterministic settle event), based strictly on `settledSurface`.
If animation completion callbacks are unreliable, a deterministic time-based settle fallback (for example, 300ms) is allowed before inset commit.

### Single Signal
`settledSurface` is the only signal for both:
- whether surface is considered open/closed
- what bottom inset is committed

This removes current divergence where gesture flags and layout callbacks can disagree.

### Feedback Loop Prevention
- Gesture uses global coordinates.
- Motion during drag is transform/offset only.
- Inset/layout mutation deferred until settle.
- No layout callback writes back into drag progress.

## Pull-to-Send Rules

Use same gesture and same model:
- `sendThreshold > revealThreshold` in a single monotonic axis.
- Arming visual is derived from `pullToSendProgress` only.
- On release above threshold:
  - if walkie-from-closed hold context: send + collapse
  - if sticky/open context (surface already open before gesture): send + keep surface open

Context is captured once at gesture begin (`originAtGestureStart`, walkie hold status), not inferred later from scattered state.

## Text Interaction Lock

While `gesturePhase == .dragging`, text view interaction is disabled (no cursor movement/selection).

Unlock is guaranteed in shared teardown called by both end and cancel/abandonment paths. This directly addresses permanent lock regressions.

## Dictation/Waveform Integration Requirements

### Paused Waveform
Paused surface keeps audio capture + level stream alive. Soniox may be disconnected; waveform still reads live amplitude.

### Waveform Dynamics
Waveform uses amplitude for:
- vertical displacement (height)
- period/speed modulation (louder => shorter period / faster wave motion)

Amplitude and period must use different mapping curves:
- Amplitude mapping: fast initial gain with asymptotic approach to max visual height (no hard clipping edge).
- Period/frequency mapping: monotonic increase without an asymptotic cap from the mapping curve (visual/system limits may still bound rendering).

### Timeout Reset Source
Inactivity timer reset source is Soniox token receipt events only. Audio level events do not reset inactivity timeout.

### Timeout Diagnostics (Required)
Add structured diagnostics to trace every timeout event:
- log each Soniox token receipt timestamp (and token/event metadata if available)
- log every inactivity timer reset timestamp and source/caller
- log timer start/cancel/fire with task id and timeout deadline
- log elapsed duration from last token receipt to timer fire

This is required to distinguish token-delivery gaps (`> timeout`) from reset-path defects/races.

### Finalization Hold For All Stop/Pause Paths (Required)
For all dictation stop/pause paths (walkie release, pull-to-send release, tap pause, send tap, dismiss/collapse, timeout), the system must:
- enter a brief `finalizing` hold state
- wait for Soniox `finished` OR a bounded timeout (500ms to 1s)
- only then execute pending action (send/collapse/pause transition)

During this hold window, show subtle finishing feedback in waveform/surface state. This prevents truncation from executing stop/pause actions before trailing tokens arrive.

### Stream Switch Resume
On resume from paused after stream switch, transcript apply context must be reinitialized if missing/mismatched:
- restore/assign `originSessionKey`
- reset transcript bridge state for current session
- avoid `applyTranscriptIfNeeded` dropping updates due to nil key

### Idle Timer Policy
While dictation is active (surface open and listening), disable device idle sleep:
- Set `UIApplication.shared.isIdleTimerDisabled = true` on dictation active entry.
- Restore `UIApplication.shared.isIdleTimerDisabled = false` on any stop/collapse/dismiss path.
- This must be centralized in one lifecycle seam to avoid leaked disabled state.

## Implementation Plan (Codebase Mapping)

### New/Updated Components
1. `DictationSurfaceMotionModel` (new, likely under `DesignSystem/ChatFlowOrganic/Components/` or `Dictation/`)
2. `MessageInputBar.swift`
   - remove duplicated local motion booleans/progress that bypass seam
   - route drag begin/change/end/cancel into model API
   - render from model-derived state
3. `DictationCoordinator.swift`
   - keep coordinator focused on dictation lifecycle/network/audio
   - expose only state inputs needed by motion model (`listening/paused/error`, walkie context)
4. `RichTextEditor` integration
   - lock/unlock editability from model `isTextInteractionLocked`

### Required Deletions/Consolidation
- Eliminate independent writers for surface progress, send arming, and inset freeze toggles that are outside the model.
- Replace ad-hoc defer resets with model-owned teardown.

## Determinism and Race Handling
- All model APIs are `@MainActor`; no background writes.
- Gesture updates are monotonic by event order.
- Settle completion commits state once; redundant commits are ignored.
- Cancel/end share identical teardown path.

## Acceptance Checks

1. Drag up/down follows thumb exactly 1:1.
2. During drag, bubble list does not jitter from inset commits.
3. Fling that fails reveal threshold settles closed and inset remains closed.
4. Surface open state and committed inset are always in sync after settle.
5. Interrupt/cancel gesture (system interruption, competing recognizer) never leaves text input locked.
6. Pull-to-send arming transitions smoothly within same drag continuum; no flapping/duplicate UI copies.
7. Paused waveform continues animating from live mic amplitude.
8. Loud speech increases waveform height and frequency/speed; quiet speech reduces both.
9. Inactivity timeout does not fire while tokens are arriving.
10. Pause -> stream switch -> resume continues transcript insertion in active stream.
11. Normal speech drives waveform near panel-max height without clipping; louder speech approaches the bound smoothly.
12. Period/frequency increase continues to feel faster at high amplitude while amplitude remains bounded.
13. Device idle timer disables during active dictation and always restores on stop/collapse/dismiss.
14. Pager indicator moves exactly with the input bar throughout drag and spring settle with no visible drift or lag.
15. Release always settles with smooth spring animation; no snapping/teleporting.
16. Pull-to-send collapse context is locked: pre-open surface stays open after send; walkie-from-closed collapses after send.
17. No stop/pause path truncates transcript: pending actions execute only after Soniox `finished` or finalization timeout window.
18. Timeout diagnostics logs are present and sufficient to reconstruct token/reset/fire chronology.
19. Drag-up and pull-to-send can be initiated from either input bar or dictation surface with identical behavior.
20. First-attempt reveal gestures do not accidentally enter walkie mode unless explicit hold intent is met.
21. First-attempt cold-start failures are retried internally before showing error UI; retry-success path is transparent to user.
22. Pull-to-send and send button are action-equivalent under all gate conditions (connectivity, empty content, error/disabled states).

## Risks / Open Questions
- Product rule for sticky-mode send outcome (collapse vs remain open) has changed multiple times; this spec expects one explicit rule to be locked before implementation to prevent branch churn.
- Need one deterministic settle callback source in SwiftUI to commit inset; if animation completion is unreliable, define explicit time-based settle gate in model.

## Implementation Handoff
- In-scope: motion seam unification, inset commit discipline, pull-to-send continuum, lock/unlock guarantees, waveform pause/live requirements, token-based timeout reset, stream-switch resume key restoration.
- Out-of-scope: redesigning coordinator protocol internals beyond required seam inputs.
- Required follow-up: adversarial cross-model review of this spec before implementation.
