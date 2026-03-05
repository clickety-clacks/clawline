# Clawline for Mac — Specification

**Status:** Draft  
**Author:** CLU (Ideas stream)  
**Started:** 2026-03-02  
**Updated:** 2026-03-03

---

## Overview

Clawline for Mac is a native macOS multi-stream chat surface built for large displays.

Core principle: **spatial honesty** — users can see where messages are and where their next message will go.

---

## Example Mockup

- Static example (web): `http://tars.tail4105e8.ts.net:18800/www/clawline-mac-hybrid-example.html`
- Variant example (web): `http://tars.tail4105e8.ts.net:18800/www/clawline-mac-hybrid-example-v11.html`
- Current artifact stamps: `V10 STABILITY LOCKS`, `V11 LOCK QUEUE CLARITY`
- Surf Ace target: TARS Surf Ace (fingerprint `6364d5a2`)
- Intended on-screen chips in this artifact: `layout frozen while typing`, `queued promotions`

---

## Layout Architecture

### Active Columns (left ~80%)

3–4 full-height streams shown side-by-side.

Each active column:
- Full message timeline (scrollable)
- Stream header (name, state, color)
- Input-targetable

### Overflow Column (right ~20%)

Streams not in active columns are shown in a vertically scrollable overflow column.

Each overflow item:
- Has stream label
- Uses **normal Clawline bubble format** (not a separate mini bubble style)
- Includes avatars in bubbles
- Shows recent conversation slice

---

## Input System

### Shared visible input, per-stream buffers

- One rendered input UI
- Hidden by default
- Appears when a stream (active or overflow) is clicked
- Slides up from bottom to show explicit target context

### Per-stream draft isolation

Each stream keeps its own draft buffer. Switching stream focus swaps buffer content.

---

## Flynn-Specified Invariants (Must Hold)

1. **Bubble consistency invariant**  
   Overflow column uses the same bubble system as active columns. No alternate mini-bubble style.

2. **Avatar invariant**  
   Avatars are required in both active and overflow bubbles. Rationale: streams may contain multiple humans and multiple agents.

3. **Bubble geometry invariant**  
   Use design-system bubble shape and sizing:
   - Self: `border-radius: 24px 24px 4px 24px`
   - Other: `border-radius: 24px 24px 24px 4px`
   - Padding: `16px 20px`
   - Font: DM Sans, body 15px

4. **Overflow readability invariant**  
   Right column is vertically scrollable with enough content density to support scanning many streams.

5. **Input clarity invariant**  
   Input must make stream target obvious before send.

---

## Motion / Stability Policy (Anti-Jank)

Flynn concern: avoid UI reflow while reading or typing.

### Proposed default behavior

1. **Typing lock (hard lock)**  
   If user is typing in stream X, stream X cannot auto-compact or move.

2. **Reading lock (soft lock)**  
   If user is actively scrolling/reading stream X, stream X is protected from auto-compaction for a short hold window.

3. **No mid-interaction reshuffle**  
   Auto-promotion from overflow is queued while user is typing or actively reading.

4. **Batch apply only at safe points**  
   Queued promotions apply only when user is idle (no typing, no scrolling) or when user explicitly triggers “refresh layout”.

5. **Pinned-stream fallback**  
   Any stream can be pinned to permanently prevent displacement.

---

## Interaction Decisions (Default v1)

These are now set as product defaults to prevent layout shift while reading or typing.

1. **Typing stream is fixed**  
   While composing in stream X, stream X cannot be compacted, displaced, or reordered.

2. **Auto-promotion is queued, not applied live**  
   New messages in other streams do not reshuffle active columns during typing/reading. Promotions queue.

3. **Reading freeze window = 8s**  
   After the last user scroll/input in a stream, that stream remains protected for 8 seconds.

4. **Apply queued layout updates only at safe points**  
   Safe points: input dismissed, explicit stream switch, or global idle state.

5. **Manual-first promotion model**  
   Default is manual promotion from overflow. Auto-promotion is advanced opt-in.

6. **Non-disruptive urgency signal**  
   Urgent updates in non-focused streams appear as badge + subtle header pulse, not layout movement.

## Layout Stability Resolution Rules (Deterministic)

When an overflow stream receives a new message during user interaction, apply this order:

1. Build lock set:
   - hard lock: stream currently being typed into
   - soft lock: stream currently being read + streams inside 8s reading freeze window
   - pinned streams

2. If auto-promotion is OFF (default):
   - no column swap occurs
   - update unread badge + optional header pulse only

3. If auto-promotion is ON:
   - if user is typing or actively reading: enqueue promotion event, do not apply layout change
   - if user is idle: choose swap candidate from active columns excluding lock set

4. If all active columns are locked:
   - do not compact anything
   - keep event queued until next safe point

5. Safe-point flush order:
   - when input dismissed, explicit stream switch, or global idle
   - process queue newest-first, coalesce duplicates per stream

### Typing-while-promotion edge case (Flynn question)

If user is typing in stream X and stream Y gets a new message that would normally promote Y:
- X stays fixed in place
- Y promotion is queued
- another unlocked stream (if any) becomes candidate later at safe point
- if none unlocked, no displacement occurs until locks clear

### Reading-shift prevention

A stream visible in active columns cannot auto-compact while user is reading it (active scroll/focus + freeze window). This prevents text from moving under the user’s eyes.

## Remaining Open Questions

1. Should the reading freeze window be user-configurable or fixed?
2. Should we add a visible "layout frozen" chip while typing?
3. In full-screen mode, should we allow a per-stream "lock column" control beyond pinning?

---

## Activity & State Signals

- `idle` (muted)
- `thinking` (sage pulse)
- `streaming` (terracotta activity)
- unread badges per stream

---

## Keyboard

- `Cmd-1..4` focus active columns
- `Cmd-[` / `Cmd-]` move focus left/right
- `Escape` dismiss input, preserve draft
- `Return` send
- `Shift-Return` newline

---

## Acceptance Criteria (Must Pass)

1. Overflow card bubbles are visually identical to active-column bubbles (same radius, padding, typography, avatar/header structure).
2. While typing in stream X, no event can move/compact/reorder X.
3. While reading stream X (active scroll + 8s freeze), no event can compact X.
4. New messages in other streams during locks produce badges/pulses only; layout changes are deferred.
5. Deferred promotions flush only at safe points and never displace pinned streams.
6. Drafts remain isolated per stream when focus changes.
7. Right overflow remains scrollable with enough cards to exceed viewport height.

## Reference Logic (Implementation Sketch)

```swift
func onIncomingMessage(streamY: StreamID) {
  updateUnread(streamY)

  guard autoPromotionEnabled else {
    pulseHeader(streamY)
    return
  }

  let lockSet = hardTypingLock
    .union(readingLocksWithin8s)
    .union(pinnedStreams)

  if userIsTyping || userIsActivelyReading {
    enqueuePromotion(streamY)
    pulseHeader(streamY)
    return
  }

  if let candidate = leastRecentActiveColumn(excluding: lockSet) {
    promote(streamY, swappingOut: candidate)
  } else {
    enqueuePromotion(streamY)
  }
}

func flushQueuedPromotionsAtSafePoint() {
  // safe points: input dismissed, explicit stream switch, global idle
  for stream in coalescedQueueNewestFirst() {
    attemptPromotion(stream)
  }
}
```

## Interaction State Model

- **Idle**: no typing, no active reading gesture. Queued promotions may flush.
- **Typing**: hard-lock focused stream; no compaction/reorder of that stream.
- **Reading**: soft-lock actively read stream + 8s freeze tail.
- **Frozen**: UI may show `layout frozen` indicator while lock conditions are active.

Transitions:
- `Idle -> Typing`: focus input in a stream.
- `Typing -> Idle`: send, dismiss, or blur input.
- `Idle -> Reading`: user scrolls/interacts with timeline.
- `Reading -> Idle`: no interaction for 8s.

Guarantee: no layout displacement during `Typing` or `Reading` states.

## Validation Scenarios (for QA + adversarial review)

1. **Typing lock under pressure**
   - Start typing in Personal.
   - Receive bursts in 3 overflow streams.
   - Expected: Personal stays fixed; overflow badges update; no column displacement.

2. **Reading protection**
   - Scroll midway through Dictation and pause.
   - Receive message in overflow stream that would otherwise auto-promote.
   - Expected: Dictation remains active and stable for at least 8s; promotion queued.

3. **Safe-point flush**
   - During active typing, accumulate 4 queued promotions.
   - Dismiss input.
   - Expected: queue flushes newest-first with duplicate coalescing; pinned/locked streams not displaced.

4. **All-columns-locked case**
   - Pin two columns, type in one, read in one.
   - Receive high activity in overflow.
   - Expected: no compaction/displacement; queue persists; user sees urgency signals only.

5. **Draft isolation**
   - Type unique drafts in 4 streams and switch rapidly.
   - Expected: each stream restores exact draft text, cursor, and newline state.

## Platform Notes

- macOS 14+
- Native SwiftUI (not Catalyst)
- Shared networking/model layer with iOS app

---

## History

- 2026-03-02 — Initial draft from battlestation UX brainstorm
- 2026-03-03 — Added Flynn invariants (bubble consistency, avatars in overflow), anti-jank policy, and open questions around promotion/compaction while typing/reading
- 2026-03-03 — Promoted anti-jank open questions into default interaction decisions (fixed typing stream, queued promotion, 8s reading freeze, manual-first promotion)
- 2026-03-03 — Added deterministic layout-stability rules and explicit typing/promotion edge-case resolution
- 2026-03-03 — Added concrete acceptance criteria for bubble invariants, lock behavior, deferred promotions, and overflow scroll density
- 2026-03-03 — Added explicit QA/adversarial validation scenarios for typing lock, reading lock, safe-point flush, all-locked columns, and draft isolation
- 2026-03-03 — Pinned mockup reference to artifact stamp `V10 STABILITY LOCKS` and visible stability chips
