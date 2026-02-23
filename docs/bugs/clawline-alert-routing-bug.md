# Bug: Alerts to Clawline stream session keys never deliver

## Symptom

`POST /alert` with `sessionKey: "agent:main:clawline:flynn:s_0291e346"` returns `{"ok":true}` but the message never appears in the Clawline stream. The user never sees it.

## Investigation (2026-02-22)

### What works
- Alert arrives at the Clawline provider HTTP endpoint ✅
- Session key is resolved correctly (`alert_session_key_decision valid=true action=use_provided_session_key`) ✅
- `alert_wake_start` / `alert_wake_result` fire ✅
- `enqueueAnnounce()` queues the item ✅
- `scheduleAnnounceDrain()` is called ✅

### What fails
- The announce queue drain calls `callGateway()` with the clawline session key
- The gateway rejects it: `Error: Invalid clawline session key`
- Evidence in gateway.log:
  ```
  2026-02-22T23:53:34.568Z [ws] ⇄ res ✗ agent errorCode=UNAVAILABLE errorMessage=Error: Invalid clawline session key
  2026-02-17T00:21:17.418Z [ws] ⇄ res ✗ agent errorCode=UNAVAILABLE errorMessage=Error: Invalid clawline session key
  ```
- The error may be swallowed by the drain's catch block, which just logs `announce queue drain failed` (but we see no such log, so it might be failing silently)

### Root cause hypothesis

The gateway's `agent` method validates session keys. Clawline stream session keys (`agent:main:clawline:flynn:s_*`) may not pass that validation when they come in via `callGateway()` (internal programmatic call from the provider), even though they work fine when routed through normal Clawline WebSocket message flow.

The `callGateway` path in the alert wake code:
```javascript
// plugin-sdk/index.js — sendQueuedAlert
await callGateway({
  method: "agent",
  params: {
    sessionKey: item.sessionKey,    // "agent:main:clawline:flynn:s_0291e346"
    message: item.prompt,           // "System Alert: ..."
    channel: origin?.channel,       // "clawline"
    to: origin?.to,                 // "agent:main:clawline:flynn:s_0291e346"
    deliver: true,
    idempotencyKey: randomUUID()
  },
  expectFinal: true,
  timeoutMs: 60000
});
```

### Where to look

1. **Gateway session key validation** — where does `Invalid clawline session key` get thrown? Search for that string in the gateway source. It's likely in the `agent` method handler that validates incoming session keys before starting an agent run.

2. **The validation may expect `agent:main:main` or `agent:main:clawline:<user>:dm`** format and reject the stream format (`agent:main:clawline:<user>:s_*`).

3. **Compare with working path** — when Flynn sends a message through the Clawline app, the provider routes it via WebSocket and it works. What's different about that session key validation vs the `callGateway` programmatic path?

### Affected functionality
- `notify --session <clawline-stream-key>` from eezo agents → never delivers
- `POST /alert` with clawline stream session keys → never delivers  
- Subagent auto-announce to clawline streams → likely also broken
- Only affects non-DM clawline streams (the `s_*` session keys). DM streams and `agent:main:main` may work fine.

### Test
```bash
# From eezo:
notify --session agent:main:clawline:flynn:s_0291e346 "test message"

# Or directly:
curl -X POST http://tars.tail4105e8.ts.net:18800/alert \
  -H "Content-Type: application/json" \
  -d '{"sessionKey":"agent:main:clawline:flynn:s_0291e346","message":"test"}'
```

Expected: message appears in Flynn's "Ideas" Clawline stream.
Actual: HTTP 200 returned but message never appears.
