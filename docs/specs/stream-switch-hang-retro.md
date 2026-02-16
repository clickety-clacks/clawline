# T082 Architecture Retro: Stream Switch Hang

Date: 2026-02-15
Issue: picker-based stream switch caused app interaction lockup (cursor still blinking)
Related fix: `ios/Clawline/Clawline/Views/Chat/StreamManagerSheet.swift`

## 1. Stream-switch transition control paths

There are 5 distinct control paths that can change `activeSessionKey`:

1. User swipe on paged `TabView` -> `streamBinding.set` -> `selectStream(...)` (`ChatView.swift`).
2. User picker row tap in `StreamManagerSheet` -> `onSelectStream(...)` callback -> `selectStream(...)` (`StreamManagerSheet.swift` + `ChatView.swift`).
3. Stream creation success auto-selects the new stream (`ChatViewModel.createStream`).
4. Startup restore selects persisted stream if present (`ChatViewModel.restoreActiveSessionKeyIfNeeded`).
5. Active-stream deletion falls back to main/first available stream (`ChatViewModel.applyStreamDeletion`).

Only path #2 also mutates popover presentation state in the same tap callback (`isPresented = false`).

## 2. Why the synchronous picker tap could hang interactions

Before fix, picker row tap did two high-impact mutations in one synchronous turn:

1. stream selection mutation (`onSelectStream` -> `viewModel.setActiveSessionKey`), and
2. popover dismissal mutation (`isPresented = false`).

Both trigger broad UI transaction work (view tree updates, list updates, layout coordinator activity, diffable snapshot churn). Running them in the same tap turn can produce re-entrant presentation/update contention where interaction appears frozen even though RunLoop is alive (cursor blink continues).

This was not a classic lock deadlock (`NSLock`/semaphore wait). It was UI-state transaction contention caused by coupling presentation teardown with model navigation mutation in one synchronous callback.

## 3. Isolated or systemic?

Audit result in this codebase:

- `isPresented = false` writes in chat views: only `StreamManagerSheet` row-selection path.
- No other stream-switch path combines popover dismissal + session mutation in the same synchronous closure.
- Swipe switching path (`TabView` binding) does not involve popover dismissal.

Conclusion: the concrete trigger is picker-path specific, but the architectural smell (mixing presentation-state mutation and navigation/model mutation in one event turn) is general and should be treated as a boundary rule.

## 4. Right boundary to prevent recurrence

Boundary/invariant:

- Presentation lifecycle state (`isPresented`, `dismiss()`) and navigation/model state (`activeSessionKey`) must not be mutated in the same synchronous UI callback.
- Ordered handoff rule: close/dismiss first, then mutate session/navigation state on the next main-actor turn.

Applied fix follows this boundary:

- In `StreamManagerSheet`, row tap now dismisses first (`isPresented = false`) and defers `onSelectStream(...)` using `Task { @MainActor in await Task.yield(); ... }`.

## 5. Follow-ups

1. Add a focused UI test for picker-based stream switching under active keyboard/input to guard this ordering invariant.
2. Add a short comment-level guideline in stream/presentation code paths: "never co-mutate presentation and stream selection synchronously."
3. Remove remaining temporary `KBTIMING` logs in chat flow files as separate cleanup.
