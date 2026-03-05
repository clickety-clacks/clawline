# Migration Spec: `src/agents/pi-embedded-runner/run.ts`

Date: 2026-03-03  
Owner: spec agent (collision zone: run.ts)

## Scope
Merge `src/agents/pi-embedded-runner/run.ts` from upstream `v2026.3.2` (`85377a281756`) into fork `clickety-clacks/clawdbot` while preserving Clawline invariant **B1** (parallel multi-stream ingress) and retry/failover behavior.

This spec covers only this file.

## Inputs Reviewed
- Current fork file: `HEAD:src/agents/pi-embedded-runner/run.ts`
- Upstream file: `v2026.3.2:src/agents/pi-embedded-runner/run.ts`
- Upstream delta from merge base: `git diff aba15763b v2026.3.2 -- src/agents/pi-embedded-runner/run.ts`
- Fork delta from merge base: `git diff aba15763b HEAD -- src/agents/pi-embedded-runner/run.ts`
- Context/invariants: `~/.openclaw/workspace/clawline-rebase-spec-context.md`, `/Users/mike/shared-workspace/clawline/specs/clawline-invariants.md`

Note: local ref `upstream/v2026.3.2` was not present; tag `v2026.3.2` resolves to the target commit.

## Upstream Changes (Function/Region Level)
1. Hook phases and richer hook context near model resolution
- Added/expanded early hook flow before `resolveModel()`:
  - `before_model_resolve`
  - legacy `before_agent_start` compatibility merge
- Added typed carry-through of `legacyBeforeAgentStartResult`.
- Hook context now includes `trigger` and `channelId` in addition to agent/session/workspace/provider fields.

2. Retry loop guardrails and loop-cap enforcement
- Added constants + helper:
  - `BASE_RUN_RETRY_ITERATIONS`
  - `RUN_RETRY_ITERATIONS_PER_PROFILE`
  - `MIN_RUN_RETRY_ITERATIONS`
  - `MAX_RUN_RETRY_ITERATIONS`
  - `resolveMaxRunRetryIterations(profileCandidateCount)`
- Enforced `MAX_RUN_LOOP_ITERATIONS` in the outer `while (true)` loop with explicit retry-limit error payload.

3. Copilot token refresh lifecycle
- Added `CopilotTokenState` and timer lifecycle:
  - scheduled pre-expiry refresh
  - in-flight dedupe
  - retry timer on refresh failure
  - auth-error-triggered refresh retry path
  - cleanup in `finally` via `stopCopilotRefreshTimer()`

4. Auth/failover classification hardening
- Added `resolveProfilesUnavailableReason(...)` path when all profiles are unavailable.
- Added shared `maybeMarkAuthProfileFailure(...)` helper with explicit timeout skip.
- Added timeout-handling semantics that rotate profile/model path but do **not** cooldown profile on timeout.

5. Error context and payload propagation improvements
- Added `resolveActiveErrorContext(...)` and propagated model/provider context in failover/billing formatting.
- Added explicit empty-timeout payload (avoid orphaned user turns).
- Added richer outbound result fields (`messagingToolSentMediaUrls`, `successfulCronAdds`, etc.) and `didSendViaMessagingTool` propagation into payload builder.

6. Parameter flow updates into `runEmbeddedAttempt(...)`
- Added `trigger`, `currentMessageId`, `legacyBeforeAgentStartResult`, `onReasoningEnd` flow.

7. Security/id hygiene updates
- `createCompactionDiagId()` switched to secure token generation.
- Pending tool-call id uses random hex rather than timestamp string.

## Fork-Specific Changes and Why They Must Survive
1. Lane deadlock fix / Clawline parallelism invariant
- Required invariant: keep global lane resolution as:
  - `resolveGlobalLane(params.lane)` (bare)
- Must **not** be rewritten to `resolveGlobalLane(params.lane ?? sessionLane)`.
- Reason: the fallback-to-session form can deadlock when session lane and global lane become the same queue (enqueueSession holds lane, enqueueGlobal re-enters same lane).
- Relevant fork history: `c28f81f2e` introduced `?? sessionLane`, then reverted by `54ceda14d` and `0d959a2da` to restore bare call.

2. No cross-stream global serialization
- Preserve ability for multiple Clawline streams to run concurrently (B1).
- `run.ts` must not reintroduce any process-wide mutex/serialization guard beyond lane queue semantics.

3. Retry/failover non-regression
- Existing fork already includes retry-cap and overflow guard work; upstream now has a fuller pattern.
- Merge must preserve or improve behavior (no regression in retries, failover rotation, timeout surfaces).

## Exact Conflict Regions and Merge Strategy
Use **upstream `v2026.3.2` as base pattern**, then validate the fork invariant at lane resolution.

1. Queue/lane bootstrap (`runEmbeddedPiAgent` prologue)
- Conflict risk: historical fork edits around lane fallback.
- Merge action:
  - Keep upstream structure.
  - Enforce exact call: `const globalLane = resolveGlobalLane(params.lane);`
  - Reject any `?? sessionLane` fallback.

2. Pre-model hooks block (provider/model override)
- Conflict risk: fork has a reduced hook context and no typed legacy result handoff.
- Merge action:
  - Adopt upstream hook flow and context fields (`trigger`, `channelId`).
  - Keep legacy + new hook precedence exactly upstream.
  - Pass `legacyBeforeAgentStartResult` into `runEmbeddedAttempt(...)` as upstream does.

3. Auth fallback config + failover reasoning
- Conflict risk: fork uses simple `fallbacks.length` check and simpler all-cooldown reason.
- Merge action:
  - Adopt upstream `hasConfiguredModelFallbacks(...)` and `resolveProfilesUnavailableReason(...)` path.

4. Copilot lifecycle block
- Conflict risk: absent in fork, large upstream insertion near auth/profile flow.
- Merge action:
  - Adopt upstream `CopilotTokenState`, refresh scheduling, auth-error refresh retry, and `finally` cleanup.
  - Keep callsites (`maybeRefreshCopilotForAuthError`) in prompt-error and assistant-error paths.

5. Retry loop + timeout/profile cooldown semantics
- Conflict risk: fork marks timeout failures directly; upstream skips timeout cooldown via helper.
- Merge action:
  - Adopt upstream helper-based failure marking (`maybeMarkAuthProfileFailure` skip timeout).
  - Keep upstream loop cap logic and retry-limit return path.
  - Keep upstream timeout rotation comments/behavior (rotate but do not poison profile cooldown on timeout).

6. `runEmbeddedAttempt(...)` args and output propagation
- Conflict risk: fork argument list is missing upstream fields in some branches.
- Merge action:
  - Adopt upstream argument set (`trigger`, `currentMessageId`, `legacyBeforeAgentStartResult`, `onReasoningEnd`).
  - Adopt upstream payload-builder/result propagation including `didSendViaMessagingTool` handoff.

7. ID generation hygiene
- Conflict risk: fork uses timestamp-based `call_${Date.now()}`.
- Merge action:
  - Adopt upstream random-hex id generation.

## Post-Merge Verification (Exact Checks)
Run these checks after conflict resolution:

1. Lane/deadlock invariant
```bash
rg -n "resolveGlobalLane\\(params\\.lane\\)" src/agents/pi-embedded-runner/run.ts
rg -n "resolveGlobalLane\\(params\\.lane \?\? sessionLane\\)" src/agents/pi-embedded-runner/run.ts
```
Expected:
- first grep: exactly one match
- second grep: zero matches

2. No new global serialization guard in `run.ts`
```bash
rg -n "mutex|serialize|global.*lock|single[-_ ]flight" src/agents/pi-embedded-runner/run.ts
```
Manual check any hit is intentional; no new global run mutex should exist.

3. Hook phases/context/handoff present
```bash
rg -n "before_model_resolve|before_agent_start|runBeforeModelResolve|runBeforeAgentStart|legacyBeforeAgentStartResult|trigger: params.trigger|channelId:" src/agents/pi-embedded-runner/run.ts
```

4. Retry guardrails present
```bash
rg -n "resolveMaxRunRetryIterations|MAX_RUN_LOOP_ITERATIONS|run-retry-limit|Exceeded retry limit" src/agents/pi-embedded-runner/run.ts
```

5. Copilot refresh lifecycle present and cleaned up
```bash
rg -n "CopilotTokenState|refreshCopilotToken|scheduleCopilotRefresh|maybeRefreshCopilotForAuthError|stopCopilotRefreshTimer" src/agents/pi-embedded-runner/run.ts
```

6. Timeout cooldown semantics preserved (skip cooldown for timeout)
```bash
rg -n "reason === \"timeout\"|Skip cooldown for timeouts|timed out\. Trying next account" src/agents/pi-embedded-runner/run.ts
```

7. Attempt arg and payload propagation
```bash
rg -n "currentMessageId|legacyBeforeAgentStartResult|didSendViaMessagingTool|messagingToolSentMediaUrls|successfulCronAdds" src/agents/pi-embedded-runner/run.ts
```

8. Build/type gate
```bash
pnpm build
```
(Required by repo build gate before any push.)

## Intractable/Blocker Assessment
No intractable blocker identified for this file.

The required Clawline behavior (B1 + bare `resolveGlobalLane(params.lane)` + no retry/failover regression) is compatible with upstream `v2026.3.2` patterns in this file, provided merge resolution follows the lane invariant checks above.
