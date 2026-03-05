# T099 Post-Cursor-Fix Yellow Reconnect Diagnosis (Ansible)

## Scope
Determine whether Ansible yellow-pulse-on-reconnect after stream switch is the same stale-cursor/`invalid_message` issue or a new failure.

## Live capture attempt (right now)

### Attempt 1: XcodeBuildMCP device log capture
- `start_device_log_cap` started session `de78d5c2-1b79-4129-81d0-c89b7305c73c`, then `stop_device_log_cap` returned:
  - `Connection was invalidated`
  - `Transport error: The peer is no longer reachable`
- No usable app log lines were returned.

### Attempt 2: CoreDevice/devicectl direct console attach
- `xcrun devicectl list devices` showed Ansible unavailable via CoreDevice long identifier path.
- Retried with Ansible USB UDID from `xctrace` (`00008150-001559941A88401C`) and console launch:
  - `xcrun devicectl ... process launch --console ... co.clicketyclacks.Clawline`
  - failed with `RequestDenied / Locked` (device locked), so no runtime stream available.

## Most recent available Ansible runtime evidence
Using the last successfully captured Ansible console log (`/tmp/ansible-devicectl-console.log`, timestamp ~`2026-02-28 10:42:54 -0800`):

- Lifecycle reaches auth phase:
  - `ConnectionLifecycle ... phase-transition from=connecting to=authenticating epoch=5`
- Then service receives auth-window protocol error:
  - `ProviderChatService ... message-level error without messageId code=invalid_message`
- Immediately followed by socket close + lifecycle recovery:
  - `WS receive loop error ... Socket is not connected`
  - `ConnectionLifecycle ... phase-transition from=authenticating to=recovering epoch=5`
- UI remains yellow/reconnecting as a result of repeated recovering cycle.

## Conclusion
- Based on the latest available runtime evidence, this is **not a new UI-only failure**; it is the **same auth/reconnect failure family** (`invalid_message` during auth window followed by transport close and recovering).
- I could **not** collect fresh post-fix live logs right now because Ansible was unreachable/locked during capture attempts, so I cannot yet prove whether the exact post-fix failing payload is still `Invalid lastMessageId` or a different `invalid_message` reason.

## Immediate next step to make this definitive
- Unlock Ansible and keep it awake; then rerun console capture during one stream-switch reconnect attempt and inspect the server error payload message string.
  - If payload message is still `Invalid lastMessageId`, the fix path is not being exercised as expected.
  - If payload message differs, this is a related-but-distinct `invalid_message` path and needs message-specific handling.
