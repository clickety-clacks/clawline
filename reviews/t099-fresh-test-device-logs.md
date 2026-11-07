# T099 Fresh Test-device Live-Log Capture (No Kill)

Date: 2026-02-28 (PT)
Device: Test-device `test-device-1`

## What I did
1. Confirmed app is currently running on device:
   - `xcrun devicectl device info processes --device Test-device`
   - Found `Clawline` PID `16002`.
2. Stopped all `devicectl ... launch --terminate-existing` flows.
3. Attempted **non-terminating** live attach to existing app output:
   - `xcrun devicectl device process launch --console --device Test-device co.clicketyclacks.Clawline`
4. Repeated attach attempts in a loop (no `--terminate-existing`) to avoid killing app.

## Result
- Could not stream logs from the running process because CoreDevice attach attempts consistently failed with SpringBoard lock denial:
  - `Unable to launch ... because the device was not, or could not be, unlocked`
  - `FBSOpenApplicationErrorDomain error 7 (Locked)`
- This happened even while `device info processes` showed Clawline running (`PID 16002`).

## Evidence
- Running process present:
  - `xcrun devicectl device info processes --device Test-device` -> `16002 .../Clawline.app/Clawline`
- Attach failures (no terminate):
  - `/tmp/test-device-attach-1772310156.log`
  - `/tmp/test-device-attach-1772310172.log`
  - `/tmp/test-device-attach-1772310185.log`
  - `/tmp/test-device-attach-1772310198.log`
  - `/tmp/test-device-attach-1772310211.log`
  - all contain `Locked` launch denial.

## Requested question: invalid_message payload text
- Not obtainable from this no-kill live pass because no attach stream could be established to the running process.
- Therefore I cannot confirm from this capture whether payload text is still `Invalid lastMessageId` or a different `invalid_message` message.

## Note
- Earlier relaunch-based captures (when relaunch was allowed) showed `code=invalid_message` in app logs, but did not include the payload `message` string.
