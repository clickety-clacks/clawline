# T099 Fresh Ansible Live-Log Capture (No Kill)

Date: 2026-02-28 (PT)
Device: Ansible `63C9EE36-3EA0-580A-8DE2-9E9C50174CAC`

## What I did
1. Confirmed app is currently running on device:
   - `xcrun devicectl device info processes --device Ansible`
   - Found `Clawline` PID `16002`.
2. Stopped all `devicectl ... launch --terminate-existing` flows.
3. Attempted **non-terminating** live attach to existing app output:
   - `xcrun devicectl device process launch --console --device Ansible co.clicketyclacks.Clawline`
4. Repeated attach attempts in a loop (no `--terminate-existing`) to avoid killing app.

## Result
- Could not stream logs from the running process because CoreDevice attach attempts consistently failed with SpringBoard lock denial:
  - `Unable to launch ... because the device was not, or could not be, unlocked`
  - `FBSOpenApplicationErrorDomain error 7 (Locked)`
- This happened even while `device info processes` showed Clawline running (`PID 16002`).

## Evidence
- Running process present:
  - `xcrun devicectl device info processes --device Ansible` -> `16002 .../Clawline.app/Clawline`
- Attach failures (no terminate):
  - `/tmp/ansible-attach-1772310156.log`
  - `/tmp/ansible-attach-1772310172.log`
  - `/tmp/ansible-attach-1772310185.log`
  - `/tmp/ansible-attach-1772310198.log`
  - `/tmp/ansible-attach-1772310211.log`
  - all contain `Locked` launch denial.

## Requested question: invalid_message payload text
- Not obtainable from this no-kill live pass because no attach stream could be established to the running process.
- Therefore I cannot confirm from this capture whether payload text is still `Invalid lastMessageId` or a different `invalid_message` message.

## Note
- Earlier relaunch-based captures (when relaunch was allowed) showed `code=invalid_message` in app logs, but did not include the payload `message` string.
