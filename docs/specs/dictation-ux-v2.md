# Dictation UX v2 — Push-Up Surface

**Status:** Draft  
**Parent:** T027 Voice Dictation  
**Date:** 2026-02-20  

## Overview

Replace the current mic-icon-in-text-field + hidden gesture activation with a **push-up dictation surface** revealed beneath the input bar. The input bar slides up to expose a compact dictation UI underneath. This gives dictation a dedicated, discoverable space without consuming any horizontal text field real estate.

## Activation

### Primary: Tap inline mic icon
- Mic icon sits **inside** the text field (right side, same as current placement).
- Tapping it slides the input bar up and reveals the dictation surface.
- The mic icon hides once the surface is open (it's redundant — the waveform replaces it).

### Secondary: Push-up gesture
- User pushes the input bar upward with their thumb.
- Natural bottom-of-screen thumb motion — pushing up a cover to reveal a mic underneath.
- Threshold-based snap: past ~60% of reveal height → snaps open; below → snaps closed.
- Works regardless of scroll position (gesture is on the input bar, not the content).

### Discoverability
- First time the user taps the mic icon: a one-time tooltip appears — **"Tip: swipe up on the bar for quick access."** Dismissed on tap. Shown once, stored in UserDefaults.

## Dictation Surface

### Layout
- Compact: ~100pt tall (minimal whitespace).
- Contains: **animated waveform** + **status text** ("Listening…" / "Paused").
- No stop button. Dismissal is swipe-down only.

### Visual treatment
- **Liquid Glass** frosted backdrop (`.glassEffect(.regular)`).
- Same z-plane as the input bar — feels like one continuous surface that got taller.
- The input bar and dictation surface share the same glass material, no visible seam.

### Waveform
- Animated bars responding to real-time audio amplitude.
- **Always reflects reality**: bars track actual mic input amplitude regardless of listening/paused state.
- **Listening state**: full brightness/opacity. Bars wiggle with speech.
- **Paused state**: dimmed (~30-40% opacity) but still amplitude-reactive. Communicates "I hear you but I'm not transcribing."
- **Silence (any state)**: bars collapse to flat line. No audio signal = no visual signal.
- Tapping the waveform toggles pause/resume.

### Status text
- Two states only: **"Listening…"** / **"Paused"**
- Positioned below the waveform.
- Subtle, secondary to the waveform visual.

## Input Bar Behavior

### Text field
- **Stays editable** while dictation is open.
- Dictated text streams into the field in real-time at the cursor position.
- User can tap into the field to reposition cursor or make corrections while dictation is active or paused.

### Keyboard
- **Stays if it was already up** when dictation opens.
- If keyboard was dismissed, it stays dismissed — dictation opens without keyboard.
- User can tap the text field to bring keyboard up while dictation is open (both coexist).

### Send button
- **Functional during dictation.**
- Tapping send fires the message. Dictation surface **stays open**.
- A new Soniox session starts immediately for the next message.
- Enables rapid-fire voice input: dictate → send → dictate → send.

### Mic icon
- Hidden while dictation surface is open (redundant with waveform).
- Reappears when dictation surface is dismissed.

## Dismissal

### Gesture: Push bar back down
- Reverse of the activation gesture — push the input bar down.
- Same threshold snap behavior.

### On dismiss
- Soniox connection **closes immediately** (clean stop).
- Any in-flight transcription is finalized and committed to the text field.
- Mic icon reappears in the text field.
- Dictation surface slides away.

## Haptic Feedback

All state transitions get haptic feedback:
- **Open**: light tap when surface snaps open.
- **Close**: light tap when surface snaps closed.
- **Pause**: subtle tap when waveform tapped to pause.
- **Resume**: subtle tap when waveform tapped to resume.

Use `UIImpactFeedbackGenerator` — light style for open/close, soft style for pause/resume.

## Platform Considerations

### iPhone
- Primary target. Push-up gesture is natural for bottom-of-screen thumb reach.
- Dictation surface sits in the home indicator / safe area region.

### iPad
- Same interaction model. Input bar may be wider — waveform centers within the surface.

### visionOS
- Push-up gesture may not translate to spatial input. Tap-to-activate via mic icon is the primary path.
- Dictation surface may need to be an expanding panel rather than a slide-up.

## Edge Cases

| Scenario | Behavior |
|---|---|
| Push up while keyboard animating | Queue gesture — apply after keyboard settles |
| Rotate device while dictating | Surface adapts to new width, dictation continues |
| Incoming call while dictating | Dictation pauses (system interruption), surface stays open |
| App backgrounds while dictating | Soniox connection closes, surface closes on return |
| Text field empty + send tapped | No-op (same as current behavior) |
| Switch streams while dictating | Dictation closes, connection ends |

## What This Replaces

- Swipe-left-to-activate gesture (conflicts with text selection).
- Swipe-right-to-deactivate gesture.
- Hold-to-dictate gesture.
- Mic icon consuming a full right column outside the text field.
- All current hidden gesture activation/deactivation patterns.

## What This Keeps

- Soniox streaming engine (unchanged).
- Real-time text insertion at cursor via `UITextView.replace(_:withText:)`.
- Token inactivity timer (15s) and max session duration (60s).
- Caustics on pairing screen (separate feature, unchanged).
- Caustics in input bar (TBD — may be replaced by this surface).
