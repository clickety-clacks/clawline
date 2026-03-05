# T099 Coordinator Silent Diagnosis

## Scope
Investigate whether the single-flight `startObservingIfNeeded()` change causes the lifecycle coordinator to start before auth token is set (and therefore emit no phase transitions on fresh login).

## Targeted diagnostics added
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:42-44`
  - Added `[T099-COORD]` VM-tagged diagnostic print helper.
- `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:468-669`
  - Instrumented `onAppear`, `handleAuthStateChange`, `handleSceneDidBecomeActive`, `startObservingIfNeeded`, subscription setup, and both observer loops.
- `ios/Clawline/Clawline/ViewModels/ConnectionLifecycleCoordinator.swift:142-217,592-623,746-748`
  - Instrumented output subscription, token set path, start gates, `startConnecting`, and every emitted output.

## Ansible deploy/capture status
- Build: success via `XcodeBuildMCP.build_device` (scheme `Clawline`, device `63C9EE36-3EA0-580A-8DE2-9E9C50174CAC`).
- Install: success via `XcodeBuildMCP.install_app_device`.
- Launch/log capture on Ansible: blocked by device lock.
  - `xcrun devicectl device info lockState` repeatedly reported `passcodeRequired: true` from `12:55` through `12:59` PT.
  - Both `XcodeBuildMCP.launch_app_device` and `start_device_log_cap` failed with locked-device denial.

## Captured ordering evidence (simulator with same diagnostic build)
Session: `stop_sim_log_cap(34dd526b-c3c4-44fd-8b9f-f90046b65dce)`

Observed sequence:
1. `handleAuthStateChange` starts and enters startup path.
2. `sceneDidBecomeActive` and `onAppear` also call `startObservingIfNeeded`.
3. Single-flight behavior works: both later calls log `joining in-flight startup task` and do not create duplicate startup.
4. `ensureLifecycleOutputsSubscription` runs before connection start and coordinator logs `outputs subscribed replacingExisting=false`.
5. `sceneDidBecomeActive -> appDidBecomeActive` can happen before token is set; coordinator logs:
   - `appDidBecomeActive called reconnectEnabled=true tokenPresent=false`
   - `startConnecting early-return missingAuthToken`
6. After that, auth/onAppear path sets token and calls `startIfNeeded`, which immediately emits:
   - `phaseTransition idle -> connecting` and `restoreCacheRequested`.

## Conclusion
The single-flight `startObservingIfNeeded` change is **not** suppressing coordinator output.

What is true:
- There is an early foreground start attempt before token set (`appDidBecomeActive` path), but it correctly no-ops due to missing token (`ConnectionLifecycleCoordinator.startConnecting` guard at `.../ConnectionLifecycleCoordinator.swift:594-597`).
- The real connect start still occurs after token set via `handleAuthStateChange` / `onAppear` (`.../ChatViewModel.swift:529-534` and `481-484`), and transitions emit normally.

Therefore, if device shows zero phase transitions, the failure is more likely that the auth-driven start path is not being reached on that run (token not present, auth-change notification not observed, or VM instance/lifecycle mismatch), not the single-flight startup ordering itself.

## Next capture needed
When Ansible is unlocked, rerun this exact instrumented build and capture fresh-login logs to verify whether `handleAuthStateChange task after setAuthToken before startIfNeeded` appears on device. That line is the discriminator for coordinator-start path execution.
