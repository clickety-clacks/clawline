# T099 Fresh Login Yellow Pulse (Ansible) — Live Capture

Date: 2026-02-28 (PT)
Device: Ansible `63C9EE36-3EA0-580A-8DE2-9E9C50174CAC`

## What I captured (no terminate-existing)

1. Verified app running and device unlocked at capture time:
- `xcrun devicectl device info processes --device Ansible` showed `Clawline` PID `16091`.
- `xcrun devicectl device info lockState --device Ansible` showed `passcodeRequired: false`.

2. Passive runtime capture:
- `xcrun devicectl -t 70 device process launch --console --device Ansible co.clicketyclacks.Clawline > /tmp/t099-fresh-login-yellow-live-2.log 2>&1`
- Output file: `/tmp/t099-fresh-login-yellow-live-2.log` (`4886` lines).

3. Live process logging trace (attach to running PID, no terminate):
- `xcrun xctrace record --template 'Logging' --device Ansible --attach 16091 --time-limit 20s --output scratch/t099-fresh-login-yellow-live.trace --no-prompt`
- Exported `os-log` and `os-log-arg` tables.

## Findings

### A) What state is it stuck in?
- UI symptom remains yellow pulse (reconnecting) per device report.
- In passive capture window, there are **no lifecycle/provider transition lines** at all (no `ConnectionLifecycle`, `ProviderChatService`, `phase-transition`, `auth_result`, `invalid_message`) in `/tmp/t099-fresh-login-yellow-live-2.log`.
- The capture consists almost entirely of `KBTIMING` / layout churn logs.

Interpretation: during this fresh-login window, the app is not emitting the connection lifecycle transitions needed to reach `.live` in observable logs; the UI remains in reconnecting presentation.

### B) Why it is not reaching `live`
- I could not observe an auth success/failure transition in this fresh capture because lifecycle transport logs were absent.
- This means I cannot attribute this specific run to auth rejection text (`Invalid lastMessageId` vs other) from device logs alone.

### C) Is this still stale-cursor / `invalid_message`?
- Device persisted replay cursor snapshot is currently empty (not stale):
  - `clawline.replayCursorBySession...` = `{}` from `/tmp/t099-pref.plist` (copied from device preferences).
- No `invalid_message` line appeared in this fresh passive capture.

Conclusion: from fresh-login capture evidence, this does **not** present as the same stale replay-cursor path (at least not directly observable). The blocking issue in this run is that lifecycle/auth transition logs are absent during the yellow-pulse period, so `live` is never observed.

## Evidence paths
- `/tmp/t099-fresh-login-yellow-live-2.log`
- `/tmp/t099-pref.plist`
- `/tmp/t099fresh-oslog.xml`
- `/tmp/t099fresh-oslogarg.xml`
- `/Users/mike/src/worktrees/per-stream-state/scratch/t099-fresh-login-yellow-live.trace`

## Practical next step
To get definitive root-cause text for this exact fresh-login run, we need one temporary print-level diagnostic in lifecycle transport handling (emit phase + auth failure reason + server error payload message) and recapture on-device. Current passive logs do not include those fields.
