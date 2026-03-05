# T099 Device Auth Path Capture (Ansible)

## Capture context
- Device: `63C9EE36-3EA0-580A-8DE2-9E9C50174CAC` (Ansible)
- App process observed before capture: PID `16223`
- Capture method: `XcodeBuildMCP.start_device_log_cap` session `15e953d8-e3eb-4b28-9a98-dc21e8b9bafc`
- Note: this tool relaunches the app; captured logs are from relaunched process `Clawline[16238]`.

## Did `handleAuthStateChange` reach coordinator start path?
Yes.

Observed `T099-COORD` sequence on device:
1. `handleAuthStateChange enter tokenPresent=true`
2. `handleAuthStateChange task after startObservingIfNeeded before setAuthToken`
3. `coordinator ... setAuthToken called incomingNil=false`
4. `handleAuthStateChange task after seedCanonicalCursor before startIfNeeded`
5. `coordinator ... startIfNeeded called reconnectEnabled=true tokenPresent=true`
6. `coordinator ... startConnecting called reason=appForegrounded tokenPresent=true cursor=nil`
7. `coordinator ... startConnecting dispatch startAttempt epoch=1`
8. `coordinator emit output=phaseTransition(... idle -> connecting ...)`
9. `observeLifecycleTransportEvents ... payload=transportOpened`
10. `coordinator emit output=phaseTransition(... connecting -> authenticating ...)`
11. `observeLifecycleTransportEvents ... payload=authResult(success: true, replayCount: 500, historyReset: true, ...)`
12. `coordinator emit output=phaseTransition(... authenticating -> replaying ...)`
13. `coordinator emit output=replayCompleted(epoch: 1)`
14. `coordinator emit output=phaseTransition(... replaying -> live ...)`

## Conclusion
The coordinator is **not silent** on this device capture. The auth path executes fully (`setAuthToken` + `startIfNeeded` + `startConnecting`), and lifecycle transitions proceed through `connecting -> authenticating -> replaying -> live`.

This falsifies the hypothesis that single-flight observation startup is preventing coordinator start on fresh login.
