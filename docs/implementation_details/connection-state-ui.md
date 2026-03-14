# Connection State UI — Non-Obvious Details

## No heartbeat / "unresponsive" state — intentional product decision
The chat transport has no liveness detection beyond socket close events (no ping-based dead-socket detector, no "last message age" check). A synthetic "unresponsive" heuristic was considered and rejected because it risks false positives during valid long responses. The UI is strictly 3-state: connected/reconnecting/disconnected. Do not add an "unresponsive" state.

## `.connected` vs `.reconnecting` vs `.failed(Error)` mapping — `.failed` maps to disconnected presentation
Both `.disconnected` and `.failed(Error)` show the same red send-button-with-reload-icon presentation. They are not differentiated in UI. Failed is not a special user-visible state.

## `errorBanner` dismissible red bar is REMOVED
The dismissible red error banner is gone. Connection state lives exclusively in the send button variant. Any code re-adding a connection error banner is reverting the design.

## Resend creates a NEW outgoing bubble — removes the failed bubble
Resend is not a retry of the same bubble. It removes the failed bubble and creates a new outgoing bubble. This is consistent with the message-stream-seam's "retry is new attempt at tail" invariant.

## Terminal path has its own sendPing loop (15s) — separate from chat send-button state
`TerminalSessionService` has a separate ping mechanism that is terminal-specific. Terminal connection state does not drive the chat send-button state. These are independent.
