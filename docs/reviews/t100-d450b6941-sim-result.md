# T100 d450b6941 Simulator Connection Result

Date: 2026-02-27
Branch/commit: `per-stream-state` @ `d450b6941`
Workspace: `/Users/mike/src/worktrees/per-stream-state`
Simulator: `iPhone 17 (iOS 26.1)` UUID `21F3F731-1FDB-439B-A89A-3F112F7C4E0D`

## Result
PASS: app leaves yellow connecting path and reaches connected/live in simulator.

## What was run
- `XcodeBuildMCP.build_run_sim` with scheme `Clawline` on simulator UUID `21F3F731-1FDB-439B-A89A-3F112F7C4E0D`
- Log capture + filtered extraction via:
  - `xcrun simctl spawn <sim-uuid> log show --style compact --debug --info --last 10m --predicate 'process == "Clawline" && (...)'`

## Evidence (key log sequence)
- `08:53:16.245` `ConnectionLifecycle`: `from=idle to=connecting epoch=1`
- `08:53:16.467` `ConnectionLifecycle`: `from=connecting to=authenticating epoch=1`
- `08:53:16.552` `ProviderChatService`: `state -> connected (auth success)`
- `08:53:16.552` `ProviderChatService`: `Auth result received (userId: qa_sim, isAdmin: false)`
- `08:53:16.567` `ConnectionLifecycle`: `from=authenticating to=replaying epoch=1`
- `08:53:17.351` `ConnectionLifecycle`: `from=replaying to=live epoch=1`
- `08:53:17.442` `MessagePipeline`: `connectionState transition ... state=connected`

Additional evidence after transition:
- Continuous incoming messages (`incoming id=...`) are observed immediately after auth/live transition, confirming active transport and message flow.

## UI observation
- Accessibility snapshot shows chat timeline and composer rendered in active chat view (not blocked login state).
- No persistent connecting-only stall observed during this run.

## Notes
- There are transient `state=reconnecting` log entries during replay window, but the sequence converges to `live` and `connected` with message ingress.
