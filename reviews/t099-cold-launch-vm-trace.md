# T099 Cold-Launch `ChatViewModel` Trace

## Scope
Cold launch on iOS Simulator with fresh app state (no prior installed app/session), then trace `ChatViewModel` creation/deallocation and verify whether both `RootView` startup task paths run.

## Method
1. Uninstall app from simulator (`simctl uninstall`) to clear prior app container state.
2. Reinstall built app.
3. Seed `provider.baseURL` in simulator defaults so authenticated path can pass `isProviderConfigured`.
4. Launch with debug-auth flags:
- env: `CLAWLINE_DEBUG_FORCE_ADMIN=1`
- arg: `--debug-force-admin`
5. Capture launch logs via XcodeBuildMCP (`launch_app_logs_sim` + `stop_sim_log_cap`).

## Evidence
### Run A (without seeded provider config)
- Result: no `ChatViewModel init` emitted (startup routed to pairing recovery path because provider config missing).

### Run B/C (fresh install + seeded provider config)
Representative log excerpt (session `40a96f87-c157-4eec-9abf-304383e6f6a7`):
- `20:21:17.197806` `RootView auth task fired auth=true provider=true hasVM=false`
- `20:21:17.197823` `RootView ensureChatViewModel enter auth=true provider=true hasVM=false`
- `20:21:17.197832` `RootView creating ChatViewModel`
- `20:21:17.198371` `ChatViewModel init id=A6C39C49-9B28-43B7-80B5-CDC56D52B517`
- `20:21:17.199206` `RootView ProgressView.task fired auth=true provider=true hasVM=true`
- `20:21:17.199223` `RootView ensureChatViewModel enter auth=true provider=true hasVM=true`

Second independent fresh run (session `5bac8330-bb78-4e5f-a5db-d17f2a0fb5fa`) also shows exactly one init:
- `20:20:23.308783` `ChatViewModel init id=CF9054A6-D63F-4397-ACBE-E4C07BBCE5B4`

`ChatViewModel deinit` lines observed in both cold-launch captures: **0**.

## Findings
1. **How many instances are created on cold authenticated launch?**
- **One** `ChatViewModel` instance per launch.

2. **Do both `RootView` task paths fire?**
- **Yes.** `RootView` authenticated task fires first and creates the VM.
- `ProgressView.task` fires immediately after, but sees `hasVM=true` and does not create another instance.

3. **Do they create separate instances?**
- **No.** Guard in `ensureChatViewModel()` (`guard chatViewModel == nil`) prevents duplicate creation.

4. **Any failure to deallocate during this cold-launch window?**
- No stale extra instance is created, so no duplicate needing deallocation appears.
- `deinit` is not observed during the short launch window for the single active VM (expected while app remains live).

## Code References
- `RootView` task paths + creation seam: `ios/Clawline/Clawline/Views/RootView.swift:44-47`, `:53-70`, `:90-101`
- `ChatViewModel` init/deinit logs: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:413`, `:454`

## Note
Temporary `RootView` trace logging was added only for this diagnosis capture and removed immediately afterward.
