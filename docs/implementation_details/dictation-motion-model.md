# Dictation Motion Model — Non-Obvious Details

## Text input lock must unlock on ALL exit paths including cancellation
Invariant 5: text interaction lock while gesture is active must ALWAYS unlock on gesture end including cancellation/abandonment. Both `gestureEnded` and `gestureCancelled` must call the same teardown path. No code path may skip teardown. Skipping unlock on cancellation causes permanent text input lock — a regression that is hard to reproduce because it requires a system gesture interruption.

## Inset commits are forbidden during drag or animation
Invariant 2: bottom inset commits only on settled state. Never during drag, never during animation. A layout feedback loop occurs if inset changes during drag — the view movement changes the keyboard/safe-area geometry, which triggers another inset change, which moves the view again. The safeguard: inset mutation is deferred to `commitSettledState` after spring completion callback.

## `settledSurface` is the ONE signal for both open/closed state AND committed inset
Two separate signals (gesture flags + layout callbacks) for surface open state can disagree. The spec requires a single `settledSurface` enum as the sole source of truth for both whether the surface is considered open/closed AND what bottom inset is committed. Splitting these into two signals produces divergence that is extremely hard to diagnose.

## Inactivity timeout resets on Soniox token receipt — NOT audio amplitude
Invariant 9: audio level events do not reset the inactivity timer. Only Soniox token receipt events reset it. If this is implemented wrong (resetting on audio amplitude), the timer will never fire while the user is speaking quietly but producing no recognized tokens — silently preventing timeout.

## `originSessionKey` must be restored on resume after stream switch
Invariant 10: on resume from paused after a stream switch, `originSessionKey` must be restored. A nil or mismatched `originSessionKey` causes `applyTranscriptIfNeeded` to drop updates silently — the transcription runs but nothing appears in the text field.

## Pull-to-send is the SAME gesture continuum — one model, one threshold axis
Invariant 6: pull-to-send is not a separate gesture with competing animation. It is one continuous threshold axis: collapse intent → reveal → send. Having two competing sources for pull-to-send arming (e.g., gesture handler AND a separate recognizer) causes flapping and duplicate UI copies.

## Walkie-talkie origin context captured ONCE at gesture begin — not inferred later
Walkie-from-closed vs sticky-open context is captured at gesture begin (`originAtGestureStart`, walkie hold status). It must NOT be inferred later from scattered state. The product rule for send outcome (collapse vs remain open) changed multiple times; the spec requires locking it and capturing it upfront.

## All stop/pause paths must enter finalization hold FIRST
Every path that stops or pauses dictation (walkie release, pull-to-send, tap pause, send tap, dismiss, timeout) MUST enter a `finalizing` hold and wait for Soniox `finished` event OR a bounded timeout (500ms–1s). Never execute the pending action before the final token window completes. Skipping this truncates transcriptions — the last words spoken are dropped.

## Phone sleep must be disabled during active dictation and ALWAYS restored
`UIApplication.shared.isIdleTimerDisabled = true` on active dictation entry. Must be restored to `false` on every stop/collapse/dismiss path. This must be centralized in one lifecycle seam to prevent leaked disabled state (screen never sleeping after dictation stops).

## Waveform period and amplitude use intentionally different mapping curves
Invariant 8/12: amplitude uses a fast-rising asymptotic curve (tanh/log-like) so normal speech fills most of the panel height and loud speech approaches but never clips. Period/frequency uses a different curve without an asymptotic ceiling — frequency continues increasing at high amplitude. Implementing both with the same curve produces wrong visual behavior (either amplitude clips or frequency saturates too early).

## Pager indicator (stream dots) is motion-coupled to the input bar as one rigid unit
Invariant 14: pager indicator moves exactly with the input bar during drag and settle — no independent pager motion. Any implementation that updates pager indicator position separately from input bar creates visible drift or lag during the gesture.

## First dictation attempt must not accidentally trigger walkie mode
Invariant 18: a normal push-up reveal gesture during first dictation attempt must not enter walkie-talkie mode unless explicit hold intent is met. Cold-start audio/connection issues that self-resolve on retry must be retried internally, not surfaced as immediate errors (invariant 19).
