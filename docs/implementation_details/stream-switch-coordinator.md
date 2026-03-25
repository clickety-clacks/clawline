# Stream Switch UI/Engine Separation — Non-Obvious Details

## Why two keys — what breaks with one
With a single `activeSessionKey`, expensive engine activation (cache restore, snapshot apply, layout) runs on the main actor during the pager transition animation — blocking the animation and causing jank. The split is not a premature optimization; it's the fix for a measured regression. The UI key updates immediately; the engine key gates behind debounce + epoch validation.

## Epoch counter increment and candidate scheduling are atomic within one synchronous turn
Steps 1-5 of the switch flow execute synchronously on `@MainActor` with no suspension points. The epoch increment and candidate scheduling are atomic within that turn. If this were async, a second intent could arrive and observe an inconsistent epoch state.

## Pager-swipe path vs programmatic path: different debounce behavior
- Pager swipe: wait for pager settle signal, then debounce 500ms before engine commit.
- Programmatic: no debounce, immediate engine commit through the **same** commit seam.
Both paths go through the single commit seam — the difference is only whether the debounce wait runs. Programmatic code that tries to bypass the seam and write `engineActiveSessionKey` directly is a boundary violation.

## `uiSwitchEpoch` cancels stale activations — rapidly flip through streams leaves only last one active
Any delayed engine-activation task captures the epoch at scheduling time. Commit is allowed only when `capturedEpoch == currentEpoch`. Rapid flip-through activates only the final settled stream for engine work. This prevents expensive activations for streams the user just passed through.

## Target stream removed before engine commit — revalidate, don't assume
At commit time, the target must be revalidated against `orderedSessionKeys`. If missing, drop the candidate and keep current `engineActiveSessionKey`. The UI key reconciles to nearest valid key. Not checking this means committing an engine activation for a deleted stream.

## Toast+spinner must remain visible until engine activation finishes for unvisited streams
Toast duration is `max(minimumToastDuration, actualEngineActivationDuration)`. The message page may be empty until engine activation materializes first data. This is expected — the toast+spinner covers the empty state. Hiding the toast before engine completion exposes an empty page.

## `ChatView.onChangehook` — watch `engineActiveSessionKey` for engine listeners, `uiSelectedSessionKey` for UI
The `ChatView.onChange` hook for the active key change must distinguish which key drives which listener. Engine listeners (layout coordinator binding, etc.) must watch `engineActiveSessionKey`. UI listeners (stream toast name, placeholder) must watch `uiSelectedSessionKey`. Binding the wrong key to the wrong listener either causes stale UI or premature expensive work.
