# T099 cold relaunch trace (logout -> kill -> cold launch -> login)

## Scope
Simulator repro on `per-stream-state` with T099 logging enabled.

## Steps executed
1. Launch app in iOS Simulator.
2. Switch active stream to a non-Personal stream (`DM`).
3. Log out.
4. Kill app process.
5. Cold launch app.
6. Log in.

## Findings
- Cold launch **does read** a persisted non-Personal active session key from disk.
- Persisted key value observed on launch: `agent:main:clawline:qa_sim:dm`.
- Key existence: **exists** (`persistedActiveSessionKey_hit`).
- Immediately after that, bootstrap path falls back to default main because ordered sessions are still empty, and rewrites persisted key to main.
- Post-login landing stream is main/Personal (`agent:main:clawline:qa_sim:main`), not prior `DM`.

## Evidence
- Log file: `/tmp/t099-cold-relaunch.log`
- Post-login UI snapshot: `/tmp/t099-cold-after-login-ui.json`
  - Contains `AXUniqueId: "agent:main:clawline:qa_sim:main"` and `AXLabel: "Reconnecting"`.

### Raw log excerpt (cold launch)
```text
2026-02-27 13:28:37.188 ... [T099] active marker=handleAuthStateChange_enter ... persisted=agent:main:clawline:qa_sim:dm ... orderedCount=0
2026-02-27 13:28:37.188 ... [T099] active marker=restoreActiveSessionKeyIfNeeded_enter ... persisted=agent:main:clawline:qa_sim:dm ... orderedCount=0 ... didRestore=false
2026-02-27 13:28:37.188 ... [T099] active marker=persistedActiveSessionKey_enter ... persisted=agent:main:clawline:qa_sim:dm ...
2026-02-27 13:28:37.188 ... [T099] active marker=persistedActiveSessionKey_hit ... persisted=agent:main:clawline:qa_sim:dm ... stored=agent:main:clawline:qa_sim:dm
2026-02-27 13:28:37.188 ... [T099] active marker=restoreActiveSessionKeyIfNeeded_waitingForStored ... persisted=agent:main:clawline:qa_sim:dm ... stored=agent:main:clawline:qa_sim:dm
2026-02-27 13:28:37.188 ... [T099] active marker=ensureDefaultActiveSessionIfNeeded_engineEmpty ... persisted=agent:main:clawline:qa_sim:dm ... orderedCount=0
2026-02-27 13:28:37.189 ... [T099] active marker=persistActiveSessionKey ... persisted=agent:main:clawline:qa_sim:main ... sessionKey=agent:main:clawline:qa_sim:main
2026-02-27 13:28:37.189 ... [T099] active marker=ensureDefaultActiveSessionIfNeeded_appliedMain ... persisted=agent:main:clawline:qa_sim:main ... main=agent:main:clawline:qa_sim:main
```
