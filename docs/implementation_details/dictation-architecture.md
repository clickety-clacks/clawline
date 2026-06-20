# Dictation Architecture — Non-Obvious Details

## `.finalizing` state is internal and NEVER published to UI
The session's internal lifecycle has a `.finalizing(pendingSurfaceTarget:)` variant, but this is a private phase. Nothing outside `DictationSession` reads it. The surface target pending after finalization is carried in the enum variant so intent is never ambiguous. **Why:** if `.finalizing` leaked into the UI contract, there would be a window where the motion model doesn't know whether to settle open or closed.

## `surfaceTarget` is published IMMEDIATELY on intent — before finalization completes
When the user swipes down to dismiss, the session immediately publishes `surfaceTarget = .closed` while entering `.finalizing(pendingSurfaceTarget: .closed)` internally. The motion model sees `.closed` and animates the surface shut. Finalization happens invisibly in the background. This decoupling prevents the UI from hanging in an ambiguous state while waiting for final tokens.

## The session has two faces — callers only see the external contract
The motion model and views see only the external published contract (`surfaceTarget`, `isListening`, `mode`, `errorMessage`, `audioLevel`, `showsKeyPrompt`). All internal lifecycle state (retries, finalization, timer internals, audio capture instance, Soniox client) is invisible outside the session. This is intentional isolation — callers that reach inside the session's lifecycle break the encapsulation and create undiagnosable bugs.

## `originSessionKey` is owned by DictationSession — not motion or view
The session stores which session was active when dictation was activated. On pause/resume within the same session key, it persists. On stream switch while paused, the coordinator must call `updateSessionKey(_:)` and the session handles transcript routing. A nil `originSessionKey` silently drops transcripts (see motion model spec invariant 10).

## Commands are the ONLY mutation seam — no direct property writes from outside
`startSticky()`, `startWalkie()`, `pause()`, `resume()`, `dismiss()`, `sendTapped()` etc. are the only valid entry points. Views and the motion model do not write session properties directly. The session decides all internal state transitions from command inputs.

## `walkieOrigin` is stored inside DictationSession — not motion model
The `walkieOrigin: WalkieOrigin?` enum (`.pushHold` vs `.pausedHold`) is session-internal state, captured at walkie start and cleared on stop. The motion model reads `mode` (which is derived) but does not own the origin distinction. This is important for send-outcome routing: walkie-from-closed collapses after send, walkie-from-paused stays open.
