# T099 landing fix verification

## Code change
- Updated `ensureDefaultActiveSessionIfNeeded()` to avoid defaulting/persisting main when stream ordering has not loaded yet.
- File/line: `ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1923-1929`
  - Added guard:
    - `guard !orderedSessionKeys.isEmpty else { ... return }`
  - This blocks premature `setEngineActiveSessionKey(main)` while ordering is empty.

## Repro executed (simulator, T099 logging active)
Flow run exactly as requested:
1. Launch app on iOS simulator
2. Switch to non-Personal stream (`DM`)
3. Log out
4. Kill app process
5. Cold launch
6. Log in

Artifacts:
- Cold-launch log trace: `/tmp/t099-fix-repro.log`
- Numbered copy: `/tmp/t099-fix-repro-numbered.log`
- Final UI snapshot after cold login: `/tmp/t099-fix-cold-final-ui.json`

## Result
- **PASS**: cold relaunch/login lands on prior stream (`DM`), not Personal.
- UI evidence:
  - `/tmp/t099-fix-cold-final-ui.json` contains:
    - `AXUniqueId: "agent:main:clawline:qa_sim:dm"`
    - `AXLabel: "DM"`

## Cold-launch trace findings
- Persisted active key at cold launch is `...:dm`:
  - `/tmp/t099-fix-repro-numbered.log:6`
- Persisted read hits `stored=...:dm`:
  - `/tmp/t099-fix-repro-numbered.log:9`
- Restore applies `...:dm` (not main):
  - `/tmp/t099-fix-repro-numbered.log:11`
- Persist write stays `...:dm`:
  - `/tmp/t099-fix-repro-numbered.log:10`
- Connection proceeds and reaches connected:
  - `/tmp/t099-fix-repro-numbered.log:136`

## Raw log excerpt (cold launch through first render)
```text
2026-02-27 13:52:56.672 ... [T099] active marker=handleAuthStateChange_enter ... persisted=agent:main:clawline:qa_sim:dm ... orderedCount=0 ...
2026-02-27 13:52:56.674 ... [T099] active marker=persistedActiveSessionKey_hit ... stored=agent:main:clawline:qa_sim:dm
2026-02-27 13:52:56.674 ... [T099] active marker=persistActiveSessionKey ... sessionKey=agent:main:clawline:qa_sim:dm
2026-02-27 13:52:56.674 ... [T099] active marker=restoreActiveSessionKeyIfNeeded_applied ... ui=agent:main:clawline:qa_sim:dm ...
2026-02-27 13:52:57.842 ... [T099] provisioning marker=transitionConnectionState_enter state=connected ...
```
