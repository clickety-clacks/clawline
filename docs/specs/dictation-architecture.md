# Dictation Architecture

## Thesis

The dictation system is three models that compose through narrow interfaces.

1. **DictationSession** — "What is happening with dictation?" Lifecycle, network, audio, transcript, timers.
2. **DictationMotion** — "What does the UI look like, and where is the finger?" Gesture physics, visual offsets, layout signals.
3. **SonioxKeyStore** — "Do we have a Soniox key?" Key storage, verification.

Each model has one job. Each piece of state has one owner. The models compose through typed interfaces: motion reads session's declared surface target, session reads key store's key, the view routes gesture intents to session commands.

The critical architectural insight is that the session has **two faces**: an internal lifecycle (phase, finalization, timers) and an external UI contract (surface target). The motion model and views only see the external face. Finalization, retries, and timer internals are invisible to everything outside the session.

---

## DictationSession

### Job
Manage the lifecycle of dictation: start, stop, pause, resume, stream audio, receive transcripts, handle errors, manage timers. Expose a stable UI contract that other components can read without seeing internal plumbing.

### Internal Phase (private)

The session tracks its own lifecycle with a private phase enum:

```
.idle
.listening
.paused
.finalizing(pendingSurfaceTarget: SurfaceTarget)
.error
```

This is **not published**. No code outside the session reads it. The `.finalizing` variant carries the surface target that takes effect after finalization completes, so the intent is never ambiguous.

### External UI Contract (published)

The session publishes a small set of properties that the rest of the system reads:

```
surfaceTarget: SurfaceTarget          // .closed | .open
isListening: Bool                      // actively transcribing right now?
mode: DictationMode?                   // .sticky | .walkieTalkie | nil
errorMessage: String?                  // current error, nil if none
audioLevel: Float                      // raw RMS from microphone, 0...~10+
showsKeyPrompt: Bool                   // should key entry UI be shown?
```

`SurfaceTarget` is a two-case enum: `.closed` or `.open`. Not three — the distinction between "open listening" and "open paused" is captured by `isListening`, not by the target. This keeps the motion model's geometry simple (open or closed) while the view reads `isListening` and `errorMessage` for visual state (waveform active vs paused vs error).

**Why `surfaceTarget` exists:** When the user swipes down to dismiss, the session enters `.finalizing(pendingSurfaceTarget: .closed)` internally (to wait for final tokens) but immediately publishes `surfaceTarget = .closed`. The motion model sees `.closed` and animates the surface shut. Finalization happens invisibly in the background. Without this separation, `.finalizing` leaks into the UI and creates a window where the motion model doesn't know what to settle to.

The same pattern applies to pause: session enters `.finalizing(pendingSurfaceTarget: .open)`, immediately publishes `surfaceTarget = .open` and `isListening = false`. The motion model sees no change to geometry (surface stays open). The waveform view sees `isListening = false` and shows the paused state.

### Stored State (internal)

- Audio capture instance, Soniox client instance, transcript buffer
- `originSessionKey: String` — session where dictation was activated; preserved across pause/resume within the same session
- Pre-dictation snapshot for discard
- Activation generation counter (monotonically increasing)
- Timer tasks (inactivity, max duration, pre-warm idle)
- Pre-warm state and buffered audio frames
- `walkieOrigin: WalkieOrigin?` — whether walkie was initiated from closed surface (.pushHold) or paused waveform (.pausedHold)

### Commands (mutation seam)

```
startSticky()
startWalkie()
startWalkieFromPaused()
pause()
resume()
dismiss()
sendTapped(action: () -> Void)
gesturePrewarm(apiKey: String)
cancelPrewarm()
handleAppBackgrounded()
updateSessionKey(_ key: String)
```

All session state changes flow through these commands. No direct property writes from outside.

### Behavioral Contracts

**B1. Surface target is set immediately on user action.**
When the user dismisses, pauses, or stops, `surfaceTarget` updates in the same synchronous call — before any async finalization work begins. The motion model and layout system see the new target instantly.

**B2. Finalization hold on all stop/pause paths.**
Every path that stops or pauses Soniox (dismiss, pause, walkie release, send-stop, timeout, background) enters the finalization hold:
1. Send `{"type":"finalize"}` to Soniox
2. Send empty audio frame (end-of-audio marker)
3. Wait for `finished: true` response OR bounded timeout (1.2s)
4. Only then close the socket and complete cleanup

During the hold, `surfaceTarget` already reflects the intended post-finalization state. The hold is invisible to the UI.

**B3. Timer policy per mode.**
- **Sticky:** inactivity timeout (15s no tokens), max duration (60s). On either timeout, session transitions to paused (surfaceTarget stays .open, isListening becomes false).
- **Walkie-talkie:** NO timeouts. Walkie listens until the user releases. Timeouts would contradict the "hold to talk" mental model.

**B4. Phone sleep management — one seam.**
`UIApplication.shared.isIdleTimerDisabled` is managed by observing `surfaceTarget`:
- `surfaceTarget` becomes `.open` → disable idle timer
- `surfaceTarget` becomes `.closed` → restore idle timer

One observation, one write site. No scattered enable/disable calls across start/stop/pause paths.

**B5. originSessionKey lifecycle.**
- Set to `currentSessionKey` when dictation activates (startSticky, startWalkie)
- Preserved across pause/resume within the same session key
- On stream switch (session key changes during active dictation): force stop-keep, commit transcript to origin session's draft, preserve originSessionKey until cleanup completes
- On resume after stream switch: new originSessionKey is set to the new current session key; old session's transcript is already committed
- The bridge checks originSessionKey on every transcript application. If nil or mismatched, the application is skipped (safety net, should never happen if lifecycle is correct).

**B6. Stream-switch safety.**
When the active session key changes during dictation:
1. Session force-enters finalization for the current stream (stop-keep)
2. Transcript is committed to the origin session's draft (via bridge)
3. Surface stays open in paused state (surfaceTarget = .open, isListening = false)
4. User can resume in the new session context (new originSessionKey, fresh transcript state)

Dictation never silently drops or migrates transcript across sessions.

**B7. First-attempt retry.**
Phase 2 pre-warm (audio engine start + Soniox connect) has a retry budget of 1. If the first attempt fails (transient audio session error, connection timeout), the session retries once with a 220ms delay before surfacing an error. The retry is invisible to the user. This ensures first-attempt reliability matches subsequent attempts.

**B8. No key validation gate.**
The session does not check `keyStore.keyStatus == .validated` before connecting. It checks `keyStore.apiKey != nil`:
- If key is present → connect to Soniox. If auth fails, Soniox returns an error; session shows it.
- If key is absent → show key prompt (surfaceTarget = .open, showsKeyPrompt = true).

This eliminates the gate where an `.unverified` key blocks a valid connection. The key prompt only appears when there is literally no key. Verification in Settings remains as a proactive check, but it's never required for activation.

**B9. Keyboard orthogonality.**
The session never touches text field focus/first responder state. Surface target changes, phase transitions, finalization, timeouts — none of these resign or assign first responder. Keyboard visibility is entirely managed by user interaction (tap to focus/unfocus) and explicit view-level actions (send clears text, which may affect focus). If the keyboard is up when dictation pauses/resumes/errors, the keyboard stays up.

**B10. Soniox context terms.**
`SonioxStreamingConfig` includes an optional `contextTerms: [String]` field. The session receives context terms from the chat context (participant names, topic keywords) and includes them in the Soniox initial config payload. This improves recognition of names and domain terms.

### What the Session Does NOT Own

- Gesture state, visual offsets, drag translation — DictationMotion
- Surface visibility (combining session target + transient gesture state) — DictationMotion
- Mic visibility — View derivation
- "Last applied transcript text" — ComposeInputDictationBridge
- Waveform rendering curves — View
- Layout freeze signals — DictationMotion
- API key storage and verification — SonioxKeyStore

---

## DictationMotion

### Job
Translate gesture events into visual state and layout signals. Read the session's surface target to know where to settle. Return intent values on gesture end for the view to route to the session.

### Reference
DictationMotion holds a reference to DictationSession (set at init). It reads published session properties. It never calls session commands.

### Stored State

```
gesturePhase: GesturePhase              // .idle | .dragging | .settling
rawDragY: CGFloat                        // raw vertical translation, global coordinates
surfaceRevealProgress: CGFloat           // 0...1, stored for SwiftUI animation
visualOffsetY: CGFloat                   // stored for SwiftUI animation
originWasOpen: Bool                      // was surface open when this gesture started?
holdThresholdReachedTime: Date?          // when upward distance first crossed hold threshold
walkieStartedThisGesture: Bool           // did this gesture activate walkie mode?
deferredSettleTarget: SurfaceTarget?     // settle target received during drag, deferred
settleDurationMultiplier: Double = 1.0   // debug tuning: set to 2.0 to slow settle animation
```

`surfaceRevealProgress` and `visualOffsetY` must be stored (not derived) because SwiftUI needs stored properties to interpolate during animation. During drag, they are set to match what a derivation would produce. During settle, they are set to the target value inside `withAnimation` blocks so SwiftUI interpolates.

### Derived State (computed, no storage)

```
upDistance: CGFloat
    max(0, -rawDragY)

pullToSendProgress: CGFloat
    Linear ramp: 0 at pullToSendStartThreshold, 1 at pullToSendTriggerThreshold.
    Computed from upDistance and thresholds.

isPullToSendArmed: Bool
    pullToSendProgress >= 1.0

isTextInteractionLocked: Bool
    gesturePhase == .dragging

isSurfaceVisible: Bool
    session.surfaceTarget == .open || (gesturePhase != .idle && surfaceRevealProgress > 0)

shouldFreezeLayout: Bool
    gesturePhase != .idle

settleTarget: SurfaceTarget
    session.surfaceTarget (read directly from session reference)

composerLiftY: CGFloat
    The upward displacement beyond the surface reveal region.
    If originWasOpen: upDistance directly (entire drag is lift).
    If !originWasOpen: max(0, upDistance - revealThreshold).
```

**Why derived matters:** `isTextInteractionLocked` derived from `gesturePhase == .dragging` means text is locked exactly when dragging and unlocked otherwise — by construction, not by remembering to set a flag. `pullToSendProgress` derived from `upDistance` means it can never disagree with the drag distance. Every derivable property that was previously stored is one fewer thing that can desync.

### Commands (mutation seam)

```
gestureBegan(originWasOpen: Bool)
gestureChanged(translationY: CGFloat, velocityY: CGFloat)
gestureEnded(translationY:, predictedY:, velocityY:,
             context: GestureEndContext) -> GestureEndIntent
gestureCancelled()
settle(to target: SurfaceTarget)       // called by view on surfaceTarget change
commitSettledState()                    // called after settle animation completes
clearGestureState()                     // called on view disappear
```

### GestureEndContext and GestureEndIntent

`GestureEndContext` — values the view provides at gesture end (things the motion model needs but doesn't own):
```
pullToSendEligible: Bool      // can a send actually fire right now?
isSwipeActivationEnabled: Bool // selection empty, no active selection handles?
verticallyDominant: Bool       // abs(dy) > abs(dx) for the gesture?
```

`GestureEndIntent` — the motion model's decision, routed by the view:
```
.none                    // no action, just settle to current target
.send                    // fire send action
.startSticky             // start sticky dictation
.dismissSurface          // dismiss dictation surface
.endWalkieKeepOpen       // end walkie, surface stays open (walkie from paused)
.endWalkieAndDismiss     // end walkie and dismiss (walkie from closed)
.settleOpen              // animate to open
.settleClosed            // animate to closed
```

### Behavioral Contracts

**B11. Shared gesture teardown.**
Both `gestureEnded` and `gestureCancelled` call the same `teardownGesture()` internal method that:
- Sets `gesturePhase = .settling`
- Zeros `rawDragY`
- Clears `holdThresholdReachedTime`
- Clears `walkieStartedThisGesture`

After `teardownGesture()`, `gestureEnded` computes and returns an intent; `gestureCancelled` returns `.none` (settle to current target). The teardown path is identical. There is no asymmetry in cleanup.

Because `isTextInteractionLocked` is derived from `gesturePhase == .dragging`, and `teardownGesture()` sets phase to `.settling`, text is unlocked automatically in both paths. No explicit unlock step that could be missed.

**B12. No accidental walkie on reveal.**
Walkie-talkie activates only when ALL of these are true simultaneously:
1. Upward distance exceeds holdActivationThreshold (124pt)
2. The gesture has been held above threshold for holdDuration (550ms)
3. The gesture phase is still `.dragging` (user hasn't released)

A normal push-up-and-release gesture (even a slow one) triggers reveal, not walkie, because the release happens before the 550ms hold duration elapses. The hold timer resets if the finger drops below the threshold during the gesture.

**B13. Settle is reactive to surfaceTarget, with drag deferral.**
When `session.surfaceTarget` changes, the view calls `motion.settle(to: newTarget)`. This method:
- If `gesturePhase == .idle` or `.settling`: immediately writes stored animated properties (surfaceRevealProgress, visualOffsetY) to match the new target. View wraps this in `withAnimation(.spring)`.
- If `gesturePhase == .dragging`: stores the target in `deferredSettleTarget`. When the gesture ends and `teardownGesture()` runs, it checks for a deferred target and uses it as the settle destination.

This eliminates the `setListeningState` early-return desync. There is no guard that skips the update — there is deferral. The target is always applied, either immediately or on gesture end. No information is lost.

**B14. Settle animation timing is configurable.**
The settle spring animation base duration is ~300ms. `settleDurationMultiplier` (default 1.0) scales this. Set to 2.0 for debugging. This is a motion model property that can be changed at runtime.

**B15. Drag target scope.**
The pan gesture recognizer covers the entire bottom composer region as one unified drag surface:
- Plus button (add attachments)
- Text field
- Send button
- Dictation surface (when open)

A drag starting from any of these elements that meets the vertical dominance criteria initiates the dictation gesture. Tap actions (plus button tap, send button tap, text field tap-to-focus) are distinguished by the gesture recognizer's intent detection: taps resolve before the pan threshold is met.

**B16. 1:1 drag tracking.**
During `.dragging`, visual offset is a direct function of raw finger delta. No multiplier, no acceleration curve. The gesture uses global coordinates so the moving view cannot change the gesture reference frame (preventing layout feedback loops).

**B17. Transform-only visual movement and global-coordinate discipline for all affected elements.**
During drag and settle, all visual movement of the composer region is via CGAffineTransform, not layout changes. This means:
- No inset/constraint updates during drag (layout is frozen)
- No layout feedback loops (the transform doesn't trigger a layout pass)
- Pager indicator, version label, and input bar move as one rigid unit (same transform applied to all)
- Layout commits only after settle completes (commitSettledState sets phase to .idle, unfreezing layout)

This prevents jitter from spring animation oscillation causing onChange → callback → layout → feedback cycles. ChatView reads `motion.composerLiftY` directly via observation, and applies it as a transform. No callback chain.

**This principle extends to every interactive element whose position changes during dictation drag — not just the composer.** The scroll-to-bottom button (SBB) is an example: it sits in the chat content area, and its position shifts when the composer lifts during drag. If the SBB uses a local-coordinate `DragGesture`, the coordinate space redefines on every frame as the button moves, creating a horizontal oscillation (the button vibrates under the thumb). The fix: any element that (a) has a gesture recognizer and (b) moves as a side effect of composer motion during dictation drag must use a stable coordinate space (`.global` or `.named`) for its gesture tracking, not local coordinates. This is the same principle as B16 applied to collateral elements.

### What DictationMotion Does NOT Own

- Session lifecycle — DictationSession
- API key — SonioxKeyStore
- Waveform amplitude — DictationSession
- Transcript — DictationSession + Bridge pipeline
- Bottom inset value — ChatView computes from session.surfaceTarget and surface height
- Keyboard/focus — never touched

---

## SonioxKeyStore

### Job
Single in-memory owner of the Soniox API key and verification status.

### Stored State

```
apiKey: String?             // persisted to SonioxConfigurationStore on write
keyStatus: SonioxKeyVerificationStatus   // persisted on write
editableKey: String         // UI scratch state for key entry prompt
```

### Derived

```
hasKey: Bool                // apiKey != nil && !apiKey.isEmpty
ctaTitle: String            // "Get Key" when empty, "Verify" when present
statusText: String?         // "Invalid" or "Validated" from keyStatus
```

### Commands

```
setKey(_ value: String)     // write to persistence, reset status to .unverified
verify() async -> Bool      // call SonioxKeyVerifier, update status
```

### Lifecycle
App-scoped (singleton or `@Environment`). Initialized from `SonioxConfigurationStore` (UserDefaults). Both Settings UI and compose key prompt read and write through this one instance.

**What this eliminates:** The triple-cache where `SonioxConfigurationStore`, `SettingsManager`, and `DictationCoordinator` each hold independent mutable copies. One store, one truth.

---

## ComposeInputDictationBridge — Transcript Reconciliation

### Job
Apply transcript text from the session to the UITextView, respecting user edits. Own all "last applied" tracking.

### The Delete-Reinsert Problem

The current bridge uses prefix matching: if the new server transcript starts with the previous server transcript, append only the suffix. But `"".hasPrefix("")` is always true, so when the user deletes all dictated text and the server sends a new transcript, the entire transcript gets re-appended. Deleted text reappears.

### The Selection-Replace Problem

The current bridge captures the selection at dictation start and replaces it on first application. But if the user selects text mid-dictation, subsequent transcript updates don't respect the selection — they append at the cursor position regardless.

### Reconciliation Algorithm

The bridge maintains per-session state:

```
insertionPoint: Int             // where the server's text region starts in the text view
serverTextLength: Int           // UTF-16 length of the server's text region
previousServerTranscript: String // the full server transcript as of last application
hasAppliedTranscript: Bool
```

**Key concept: the "server text region."** This is the range `[insertionPoint, insertionPoint + serverTextLength)` in the text view where server-controlled text lives. Everything outside this range is user-owned text.

**On first application:**
1. If user has a selection, replace the selection with the transcript. Set insertionPoint to selection start, serverTextLength to transcript length.
2. If no selection, insert at cursor position. Set insertionPoint to cursor position, serverTextLength to transcript length.

**On subsequent applications:**
1. Compute the diff between `previousServerTranscript` and the new transcript.
2. Check if the server text region in the text view still matches `previousServerTranscript`:
   - Read the actual text in the text view at `[insertionPoint, insertionPoint + serverTextLength)`.
   - If it matches `previousServerTranscript`: user hasn't edited the region. Apply the diff (replace the server region with the new transcript). Update `serverTextLength`.
   - If it does NOT match: the user edited within the server region. The server region is now "user-owned." Do not replace it. Instead, append the new suffix (new transcript minus the old) at the end of the (now user-modified) region. Shrink `serverTextLength` to zero (the entire region is user-owned now). Future appends go after the old region.

**On user selection during dictation:**
- If the user has an active selection when a transcript update arrives, and the selection overlaps the server text region: replace the selected portion with the new transcript suffix. Adjust `serverTextLength` accordingly.
- If the selection is outside the server text region: insert at cursor position, starting a new server text region there.

**Invariant:** User deletions are permanent. If the user deletes text from the server region, the bridge detects the mismatch and never reinserts the deleted text. This is the core fix for the delete-reinsert bug.

**Invariant:** The bridge is the sole owner of "what was last applied." DictationSession does not cache `lastAppliedTranscriptText`. The bridge tracks `previousServerTranscript` and makes all comparison/diff decisions internally.

---

## Waveform Rendering Contract

The waveform is a view-level concern. DictationSession provides `audioLevel: Float` (raw RMS from the microphone). The view owns all visual mapping.

### Two curves, one source

The waveform view applies two separate mapping curves to the same `audioLevel`:

**Height curve (amplitude → bar displacement):**
- Fast-rising, then asymptotic to panel max height
- Shape: `tanh`-like or `log1p`-like
- Normal speech fills most of the panel height. Loud speech approaches but never clips the panel bound
- Specifically: no hard clipping edge. The curve approaches the max asymptotically

**Period curve (amplitude → wave speed):**
- Monotonic decrease in period (increase in frequency) as amplitude increases
- No asymptotic ceiling from the mapping curve (visual/system limits may still bound rendering)
- Louder = taller AND faster waves; both change together but with different curve shapes

**Why they differ:** The height must be bounded (can't exceed panel height) so it needs an asymptotic curve. The period has no such physical bound — faster is always distinguishable — so it uses a steeper, unbounded curve.

### Reduce motion

Under `@Environment(\.accessibilityReduceMotion)`:
- Waveform uses alpha pulse instead of positional animation
- Reveal/dismiss still follows finger (motion reduction only affects secondary waveform animation)
- The view reads the environment directly. The session does not track reduce-motion state.

### Raw audio level, not normalized

DictationSession publishes `audioLevel: Float` — the RMS amplitude value from the microphone, with minimal processing (smoothing is acceptable, normalization is not). The view applies both mapping curves to this raw value. This means:
- The height curve constants (floor, ceiling, tanh gain) exist in exactly one place: the waveform view
- The period curve constants exist in exactly one place: the waveform view
- There is no round-trip normalization where the session maps to [0,1] and the view unmaps back

---

## Gesture System Contract

### Attachment scope

`DictationPanGestureInstaller` (UIViewControllerRepresentable) installs a UIPanGestureRecognizer on the parent view. The active region covers the entire bottom composer area:
- Plus button
- Text field
- Send button
- Dictation surface (when open)

All of these are valid drag origins. Tap actions on these elements are distinguished by the intent detection system: taps complete before the pan displacement threshold is met.

### Intent detection (IntentLock)

The gesture recognizer maintains an `IntentLock` state machine that classifies each gesture:

**`.undecided`** — initial state. The recognizer observes touch movement to determine intent.

**`.dictation`** — the gesture is a dictation drag. Pan events are forwarded to DictationMotion.

**`.textEditing`** — the gesture is text cursor/selection manipulation. Pan is disabled; UIKit text interaction takes over.

**Promotion rules (touch starts in text field area):**
1. If surface is already open AND vertical downward ≥ 6pt → dictation (dismiss gesture)
2. If fast upward velocity (≤-220 pt/s) OR quick upward drag ≥ 22pt in <180ms → dictation (reveal gesture)
3. If elapsed ≥ 180ms OR downward ≥ 8pt OR horizontal ≥ 20pt → text editing
4. If none of the above after continued observation → text editing (default)

**Promotion rules (touch starts outside text field):**
1. If vertical dominant AND (upward ≥ 6pt OR (surface open AND downward ≥ 6pt)) → dictation
2. Otherwise → undecided (eventually text editing if not promoted)

**Invariant (gesture coexistence, inv 21):** Cursor drag, pickup (text loupe), and selection-handle drags inside the focused text editor never arm dictation drag. The intent detection prioritizes text editing when the touch starts in the text field and the motion is ambiguous. Dictation drag is only armed for clear vertical-dominant gestures or gestures starting outside the text field.

### Pan eligibility

`DictationMotion` provides `shouldBeginPan(selectionLength:) -> Bool`:
- Returns `true` if surface is currently visible (allows dismiss gesture), OR
- Returns `true` if session is idle, surface is closed, and selectionLength == 0 (allows reveal gesture), OR
- Returns `false` otherwise (selection handles active, or session in non-activatable state)

This is the single eligibility gate. There is no separate `swipeActivationEnabled` on the session.

---

## Composition

### Object Graph

```
                 ┌──────────────────┐
                 │  SonioxKeyStore  │  (app-scoped)
                 │  key, status     │
                 └────────┬─────────┘
                          │ reads apiKey
                          ▼
┌────────────┐    ┌──────────────────┐    ┌──────────────────────────┐
│  ChatView  │───▶│ DictationSession │───▶│ ComposeInputDictationBridge │
│  (owner)   │    │ surfaceTarget,   │    │ (transcript applicator)      │
│            │    │ isListening,     │    └──────────────────────────────┘
│            │    │ audioLevel, ...  │
│            │    └──────────────────┘
│            │              ▲
│            │              │ reads surfaceTarget, mode
│            │    ┌─────────┴────────┐
│            │───▶│ DictationMotion  │
│            │    │ gesture, offsets, │
│            │    │ layout signals   │
└────────────┘    └──────────────────┘
      │                    ▲
      │ passes both        │ gesture events
      ▼                    │
┌─────────────────┐        │
│ MessageInputBar │────────┘
│ (view, router)  │───────▶ routes intents to session commands
└─────────────────┘
```

**Ownership:**
- ChatView owns DictationSession (`@State`)
- ChatView owns DictationMotion (`@State`, initialized with session reference)
- ChatView passes both to MessageInputBar as parameters
- SonioxKeyStore is app-scoped (`@Environment`)
- ComposeInputDictationBridge is owned by DictationSession

**Why ChatView owns both:** ChatView needs `motion.shouldFreezeLayout` and `motion.composerLiftY` for layout. If the motion model lives inside MessageInputBar, ChatView can only get these via callbacks — which creates callback-shadow SSOT violations. Hoisting to ChatView lets both views observe the same model directly.

### Data Flows

**Gesture → Render (during drag):**
```
Touch event
  → DictationPanGestureInstaller (UIKit recognizer, intent lock)
  → MessageInputBar.handlePushChanged(translation:, velocity:)
  → motion.gestureChanged(translationY:, velocityY:)
  → motion updates stored animated props: surfaceRevealProgress, visualOffsetY
  → SwiftUI observes changes
  → MessageInputBar re-renders: surface opacity/clip, pull-to-send indicator
  → ChatView reads motion.composerLiftY → applies as CGAffineTransform
```

No callbacks. No pushed copies. Direct observation.

**Gesture End → Session Command:**
```
Touch end
  → DictationPanGestureInstaller
  → MessageInputBar.handlePushEnded(...)
  → let intent = motion.gestureEnded(translationY:, ..., context:)
  → motion calls teardownGesture(), enters .settling
  → view routes intent:
      .startSticky  → session.startSticky()
      .send         → onSend()
      .dismiss      → session.dismiss()
      .endWalkieKeepOpen → session.endWalkie()
      ...
  → view wraps in withAnimation(settleSpring) {
      motion.settle(to: motion.settleTarget)
    }
  → SwiftUI interpolates surfaceRevealProgress + visualOffsetY
  → after settle duration: motion.commitSettledState()
  → gesturePhase → .idle, layout unfreezes
  → ChatView layout updates from session.surfaceTarget
```

**Session State Change → Motion Settle (non-gesture):**
```
session.surfaceTarget changes (e.g., timeout causes .open → .open [no change],
                                or dismiss causes .open → .closed)
  → view's onChange(of: session.surfaceTarget) fires
  → withAnimation(settleSpring) { motion.settle(to: newTarget) }
  → if motion is .dragging: target deferred (stored in deferredSettleTarget)
  → if motion is .idle or .settling: immediate animation
  → after settle: commitSettledState()
```

**Transcript Flow:**
```
Soniox yields .response(tokens, finished)
  → DictationSession event handler
  → buffer.apply(tokens:, finished:) → DictationTranscriptSnapshot
  → bridge.apply(transcript: snapshot.text, for: originSessionKey)
  → bridge: detect user edits to server text region
  → bridge: apply diff (append suffix or replace region)
  → bridge updates own previousServerTranscript + serverTextLength
```

The session does not cache "last applied text." The bridge is the sole authority.

**Key Resolution on Activation:**
```
User gesture → intent .startSticky
  → view routes: session.startSticky()
  → session checks: keyStore.apiKey != nil?
  → if yes: proceed with Phase 2 pre-warm
  → if no: surfaceTarget = .open, showsKeyPrompt = true
  → user enters key, taps CTA
  → if key empty: open Soniox signup URL
  → if key present: keyStore.setKey(text), session retries startSticky()
  → connection attempt. If auth error: session shows error
```

No validation gate. Connect-and-see.

---

## State Ownership Map

| Concept | Owner | Type | Readers | Mutation Seam |
|---|---|---|---|---|
| Internal phase | DictationSession | stored, private | (self only) | Session commands |
| Surface target | DictationSession | stored, published | Motion, ChatView | Session commands |
| Is listening | DictationSession | stored, published | MessageInputBar | Session commands |
| Mode | DictationSession | stored, published | Motion, MessageInputBar | Session commands |
| Audio level | DictationSession | stored, published | Waveform view | Audio level callback |
| Error message | DictationSession | stored, published | MessageInputBar | Session error handlers |
| Origin session key | DictationSession | stored, private | (self + bridge) | Session lifecycle |
| Gesture phase | DictationMotion | stored | MessageInputBar, ChatView | Gesture methods |
| Raw drag Y | DictationMotion | stored | (internal) | gestureChanged |
| Surface reveal progress | DictationMotion | stored (animated) | MessageInputBar | gestureChanged, settle, commit |
| Visual offset Y | DictationMotion | stored (animated) | MessageInputBar, ChatView | gestureChanged, settle, commit |
| Pull-to-send progress | DictationMotion | **derived** | MessageInputBar | from rawDragY + thresholds |
| Pull-to-send armed | DictationMotion | **derived** | MessageInputBar | from pullToSendProgress |
| Text interaction locked | DictationMotion | **derived** | MessageInputBar | from gesturePhase |
| Surface visible | DictationMotion | **derived** | MessageInputBar, ChatView | from surfaceTarget + gesture |
| Layout freeze | DictationMotion | **derived** | ChatView | from gesturePhase |
| Settle target | DictationMotion | **derived** | (internal) | from session.surfaceTarget |
| Composer lift | DictationMotion | **derived** | ChatView | from rawDragY + origin |
| API key | SonioxKeyStore | stored | Session, Settings | setKey, verify |
| Key status | SonioxKeyStore | stored | Settings, Key prompt | setKey, verify |
| Mic visible | **View** | **derived** | MessageInputBar | from surfaceTarget + content + focus |
| Send eligible | **View** | **derived** | MessageInputBar | from isSending + canSend + connection |
| Last applied transcript | Bridge | stored | (self) | apply() |
| Server text region | Bridge | stored | (self) | apply() |

---

## How This Prevents Known Problems

### Consolidation Regressions

**R1. setListeningState early-return desync.**
`setListeningState` no longer exists. The motion model reads `session.surfaceTarget` directly. The view calls `motion.settle(to:)` on target changes, which has no early-return guard — only a deferral during active drag. After the drag ends, any deferred target is applied. The desync window is eliminated because there is no guard that discards the update.

**R2. Keyboard preservation lost on non-drag transitions.**
Session behavioral contract B9: the session never touches first responder. Surface target changes propagate through the motion model (visual) and ChatView (layout), neither of which affect keyboard state. If the keyboard is up when a timeout fires, it stays up.

**R3. Aggressive cancellation path differences.**
Motion behavioral contract B11: both `gestureEnded` and `gestureCancelled` call `teardownGesture()` — the same internal method. `isTextInteractionLocked` is derived from `gesturePhase == .dragging`; since `teardownGesture()` sets phase to `.settling` in both paths, text is unlocked identically. The only difference: `gestureEnded` computes an intent, `gestureCancelled` returns `.none`.

**R4. .finalizing widening open/desync window.**
Session behavioral contract B1: `surfaceTarget` is set immediately when the user acts. `.finalizing` is private and carries `pendingSurfaceTarget`. The motion model never sees `.finalizing` — it sees the target. There is no window where the motion model doesn't know what to settle to.

**R5. Key validation gate blocking connection.**
Session behavioral contract B8: the session checks `apiKey != nil`, not `keyStatus == .validated`. If the key is present but unverified or previously invalid, the session attempts connection anyway. Auth errors are handled like any transport error.

### Invariant Enforcement

**Inv 8: Waveform period decreases with amplitude.**
Waveform rendering contract: the view applies two separate curves. Period curve is monotonically decreasing (frequency increases) with amplitude. No asymptotic ceiling.

**Inv 10: originSessionKey restored on stream switch.**
Session behavioral contract B5/B6: originSessionKey is preserved during stream switch. Transcript is committed to the origin session. On resume in a new session, a new originSessionKey is set.

**Inv 11: Amplitude asymptotic curve.**
Waveform rendering contract: height curve is tanh/log-like, asymptotic to panel max height. No hard clipping.

**Inv 12: Period scaling with no ceiling.**
Waveform rendering contract: period curve has no asymptotic cap.

**Inv 13: Phone sleep.**
Session behavioral contract B4: idle timer managed by observing surfaceTarget. One observation, one write site.

**Inv 16: Drag from both surfaces.**
Motion behavioral contract B15: gesture recognizer covers the entire bottom composer region, including the dictation surface when open.

**Inv 17: Finalization hold on all stop paths.**
Session behavioral contract B2: every stop/pause path enters finalization hold. surfaceTarget is set immediately; finalization runs in background.

**Inv 18: No accidental walkie on reveal.**
Motion behavioral contract B12: walkie requires 124pt + 550ms hold. Normal reveal gestures don't meet the hold duration.

**Inv 19: First-attempt reliability.**
Session behavioral contract B7: retry budget of 1 with 220ms delay. First failure is transparently retried.

**Inv 21: Gesture coexistence.**
Gesture system contract: IntentLock distinguishes text editing from dictation. Cursor drag, selection handles never arm dictation. Dictation requires clear vertical dominance or non-text-field origin.

### Bug Fixes

**Transcript not inserting after stream switch.**
Session contract B5: originSessionKey lifecycle is explicit. After stream switch, transcript for the origin session is committed. On resume, a new originSessionKey is established. The bridge's safety check (originSessionKey nil → skip) never triggers under correct lifecycle.

**Dictation dies after stream switch.**
Session contract B6: stream switch stops the current stream (stop-keep), preserves surface open in paused state. User can resume in new session. No silent death.

**Idle timer not restored on dismiss.**
Session contract B4: idle timer is driven by surfaceTarget, not by scattered calls. When surfaceTarget becomes .closed (for any reason), idle timer is restored. One place, one rule.

**Amplitude clips instead of asymptotic.**
Waveform rendering contract: tanh-like curve. No hard clipping. The session provides raw audio level; the view applies the asymptotic mapping.

**Delete-reinsert.**
Bridge reconciliation: the bridge detects that the text view content in the server text region no longer matches `previousServerTranscript`. When a mismatch is detected, the bridge does not replace the region. Instead, it appends only new suffix content after the (now user-modified) region. Deleted text is never reinserted.

**Selection-replace mid-dictation.**
Bridge reconciliation: on each transcript application, the bridge checks the current selection. If the user has an active selection overlapping the server text region or at the cursor position, the new transcript content replaces the selection.

**Soniox context terms.**
Session contract B10: `SonioxStreamingConfig` includes `contextTerms: [String]`. Session receives context terms from the chat context and includes them in the initial config payload.

**SBB drag jitter.**
Motion contract B17 (extended): the scroll-to-bottom button uses a local-coordinate DragGesture, but its position shifts during dictation drag as the composer lifts and chat content adjusts. The local coordinate space redefines on each frame, causing horizontal oscillation under the thumb. Fix: the SBB's DragGesture must use a stable coordinate space (`.global` or `.named`), not local. This is the same global-coordinate discipline as B16/B17 applied to a collateral element whose position changes during composer motion.

### Feature Requests

**Walkie never times out.**
Session contract B3: timer policy is per-mode. Walkie: no timeouts.

**Plus button as drag handle.**
Motion contract B15: the gesture recognizer covers the entire input bar including plus button. Already the case; explicitly documented.

**Double spring settle for debugging.**
Motion stored state: `settleDurationMultiplier: Double = 1.0`. Set to 2.0 to slow settle. The settle spring duration and the commit-after-settle delay are both scaled by this multiplier.

---

## Acceptance Criteria

### Architecture

1. DictationSession, DictationMotion, and SonioxKeyStore exist as three separate `@Observable` types.
2. DictationSession's internal phase enum is private. No code outside the session reads it.
3. `session.surfaceTarget` is the only published indicator of whether the surface should be open or closed. Motion model and ChatView read it.
4. `motion.isSurfaceVisible` is the only answer to "is the surface currently showing?" (combines surfaceTarget with transient gesture state).
5. No type outside SonioxKeyStore stores a mutable copy of the API key or status.
6. DictationMotion holds a reference to DictationSession and reads surfaceTarget/mode directly. No push methods, no context mirrors.
7. `motion.gestureEnded()` returns a GestureEndIntent. The motion model contains zero calls to session commands.
8. ChatView reads `motion.shouldFreezeLayout` and `motion.composerLiftY` directly. No `onDictationSurfaceDragActiveChange` or `onComposerMotionOffsetChange` callbacks.
9. `isTextInteractionLocked` is computed: `gesturePhase == .dragging`. Not stored.
10. `pullToSendProgress` is computed from drag distance and thresholds. Not stored.
11. ComposeInputDictationBridge is the sole tracker of "last applied." Session has no `lastAppliedTranscriptText`.
12. Session provides `audioLevel: Float` (raw RMS). Waveform view owns all visual mapping constants and curves.
13. A single `canSendNow` predicate is used by send button, keyboard submit, and pull-to-send.

### Session Behavioral

14. `surfaceTarget` updates synchronously when user dismisses/pauses/stops — before any async finalization.
15. All stop/pause paths enter finalization hold (send finalize, send empty frame, wait for finished or 1.2s timeout).
16. Walkie mode has no inactivity or max-duration timeout.
17. Idle timer (UIApplication.isIdleTimerDisabled) is driven solely by surfaceTarget changes: .open disables, .closed restores.
18. Session checks `apiKey != nil` for activation, not `keyStatus == .validated`.
19. Phase 2 pre-warm retries once on failure (220ms delay, transparent to user).
20. Stream switch: stop-keep on origin, commit transcript, surface stays open paused, resume in new session context.
21. originSessionKey preserved across pause/resume within same session; reset on new session activation.
22. Session never touches text field first responder. Keyboard state is orthogonal to surface state.
23. SonioxStreamingConfig includes `contextTerms: [String]`.

### Motion Behavioral

24. `gestureEnded` and `gestureCancelled` call the same `teardownGesture()` method. No asymmetry in cleanup.
25. Walkie hold requires ≥ 124pt displacement AND ≥ 550ms hold duration. Normal reveal does not trigger walkie.
26. `settle(to:)` defers during active drag; applies on gesture end. No early-return guard that discards updates.
27. `settleDurationMultiplier` scales both animation and commit timing. Default 1.0, set 2.0 for debug.
28. Gesture recognizer covers entire bottom composer region including plus button and dictation surface.
29. Drag tracks thumb 1:1 with no multiplier. Global coordinate space. Transform-only movement (no layout changes).
30. Pager indicator, version label, and input bar move as one rigid unit (same transform).
31. Any interactive element whose position changes during dictation drag (e.g., scroll-to-bottom button) uses a stable coordinate space for its gesture tracking, not local coordinates.

### Waveform

32. Height curve: fast-rising, asymptotic to panel max. Normal speech fills most of panel. No hard clip.
33. Period curve: monotonic frequency increase with amplitude. No asymptotic ceiling.
34. Under reduce-motion: alpha pulse, no positional waveform animation. Reveal/dismiss still follows finger.

### Transcript

35. User deletions within the server text region are permanent: bridge detects mismatch and never reinserts.
36. Active selection during dictation: new transcript content replaces the selection.
37. Bridge checks originSessionKey on every application; nil or mismatch is a safety-net skip, not normal flow.

### Layout

38. Bottom inset commits only when `motion.shouldFreezeLayout` is false (gesturePhase == .idle).
39. Surface visibility and inset derive from the same source (session.surfaceTarget, via motion model).

---

## Risks

1. **SwiftUI observation transitivity.** DictationMotion reads `session.surfaceTarget` in computed properties. The Observation framework (Swift 5.9+) tracks access transitively across @Observable boundaries. If this doesn't work as expected, fallback: `onChange(of: session.surfaceTarget)` in the view calls `motion.settle(to:)`.

2. **Bridge mismatch detection.** The reconciliation algorithm must handle multi-byte Unicode correctly (emoji, combining characters) when comparing the server text region against the text view's actual content. UTF-16 offsets from `NSAttributedString` must be used consistently.

3. **Migration scope.** This touches ChatView, MessageInputBar, DictationCoordinator (→ Session), DictationSurfaceMotionModel (→ Motion), ComposeInputDictationBridge, SettingsManager, and introduces SonioxKeyStore. Incremental commits, each passing existing tests.
