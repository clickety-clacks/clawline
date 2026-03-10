# T099 Ansible Yellow-Dot Diagnosis

## Summary
The app is not stuck because of the `startObservingIfNeeded` race. On Ansible, connection attempts never complete authentication due transport/protocol failure against the provider endpoint (`tars.tail4105e8.ts.net:18800`). The lifecycle coordinator keeps cycling `authenticating -> recovering -> connecting`, so UI stays yellow (`reconnecting`) by design.

## Evidence (device runtime logs)
Captured with:
`xcrun devicectl device process launch --device 63C9EE36-3EA0-580A-8DE2-9E9C50174CAC --terminate-existing --console co.clicketyclacks.Clawline`

Log file: `/tmp/ansible-devicectl-console.log`

1. Lifecycle starts normally and reaches authenticating:
- `/tmp/ansible-devicectl-console.log:40` `phase-transition from=idle to=connecting epoch=1`
- `/tmp/ansible-devicectl-console.log:50` `phase-transition from=connecting to=authenticating epoch=1`

2. First transport candidate (`wss://...:18800/ws`) fails TLS handshake:
- `/tmp/ansible-devicectl-console.log:94` boringssl handshake failed
- `/tmp/ansible-devicectl-console.log:98` connection failed
- `/tmp/ansible-devicectl-console.log:101` `NSURLErrorDomain Code=-1200` "A TLS error caused the secure connection to fail."
- `/tmp/ansible-devicectl-console.log:164` `WS receive loop error: A TLS error caused the secure connection to fail.`

3. Fallback candidate (`ws://...:18800/ws`) also fails before auth completes:
- `/tmp/ansible-devicectl-console.log:167` fallback to `ws://...`
- `/tmp/ansible-devicectl-console.log:195` `message-level error without messageId code=invalid_message`
- `/tmp/ansible-devicectl-console.log:196` `Socket is not connected`
- `/tmp/ansible-devicectl-console.log:197` `state -> disconnected (socket close)`

4. Coordinator enters recover loop and retries indefinitely:
- `/tmp/ansible-devicectl-console.log:199` `authenticating -> recovering epoch=1`
- `/tmp/ansible-devicectl-console.log:206` `recovering -> connecting epoch=2`
- `/tmp/ansible-devicectl-console.log:208` reconnect backoff progression
- same pattern repeats at epochs 2..5 (`:282`, `:886`, `:1038`, `:1161`, `:1230`)

5. UI remains yellow because reconnect phases map to reconnecting:
- `/tmp/ansible-devicectl-console.log:41`, `:52`, `:200`, `:207` show repeated `connectionState ... state=reconnecting`

## Code path confirming behavior
1. Transport attempt sequence is `wss` then `ws` in lifecycle mode:
- [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:531)
- [ProviderChatService.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/Services/ProviderChatService.swift:549)

2. Transport interruption during authenticating forces recovering/retry:
- [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:291)
- [ConnectionLifecycleCoordinator.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:295)

3. Reconnect phases render yellow pulse:
- [ChatViewModel.swift](/Users/mike/src/worktrees/per-stream-state/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1221)

## Root cause
Provider endpoint/protocol mismatch from Ansible runtime context:
- `wss://tars...:18800/ws` fails TLS (`-1200`, wrong TLS protocol).
- `ws://tars...:18800/ws` fallback does not successfully complete auth (server returns `invalid_message`, then socket closes).
- No successful auth result arrives, so lifecycle never reaches `.live`.

This is a transport/auth handshake failure to backend, not an observer-subscription race in the app.
