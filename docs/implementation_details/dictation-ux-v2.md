# Dictation UX v2 — Non-Obvious Details

## Send button stays functional during dictation — send does NOT close the surface
Tapping send while the dictation surface is open fires the message and **keeps the surface open**. A new Soniox session starts immediately for the next message. This enables rapid-fire voice input. Code that closes the dictation surface on send is wrong.

## Keyboard state is preserved — dictation does not force keyboard dismiss or show
If the keyboard was up when dictation opens, it stays. If it was down, it stays down. The user can tap the text field to bring the keyboard up while dictation is open. Both coexist. Code that dismisses the keyboard on dictation open breaks this invariant.

## Waveform always reflects REAL audio amplitude — even in paused state (dimmed but reactive)
In paused state, bars are dimmed (~30-40% opacity) but still amplitude-reactive. A flat line means silence. Paused does not mean frozen waveform. Code that freezes waveform animation when paused is wrong.

## Token inactivity timer (15s) and max session duration (60s) from voice-dictation spec are unchanged
The UX v2 replaces gesture activation/deactivation but does NOT change the Soniox streaming engine, real-time text insertion at cursor (`UITextView.replace(_:withText:)`), token inactivity timer, or max session duration.

## Gesture threshold: fast flick can commit reveal with smaller travel
Push-up gesture uses velocity OR displacement. A fast upward flick can snap open with less travel than a slow drag. Slow drag must cross a displacement threshold. Implementing only displacement (ignoring velocity) makes the gesture feel unresponsive to quick taps.

## Inbound call while dictating: surface stays open, dictation pauses (system interruption)
App backgrounding while dictating closes the Soniox connection and closes the surface on return. An inbound call pauses dictation but the surface stays open. These are different behaviors for different interruption types.
