# Migration Spec: `src/gateway/call.ts` (v2026.3.2 rebase)

## Scope
Collision zone: `src/gateway/call.ts`

Target upstream: `v2026.3.2` (`85377a281756`)

Comparison baseline used in this spec:
- `git diff aba15763b v2026.3.2 -- src/gateway/call.ts`
- `git diff aba15763b HEAD -- src/gateway/call.ts`
- `git diff HEAD v2026.3.2 -- src/gateway/call.ts`
- `grep -R "from.*gateway/call\|require.*gateway/call" src/clawline/ extensions/clawline/`

Note: local ref `upstream/v2026.3.2` was not present in this checkout; the local tag `v2026.3.2` resolves to the same target commit.

## What Changed Upstream (Security/Auth Refactor)
Upstream made major changes in `call.ts` between `aba15763b` and `v2026.3.2` (large rewrite, auth/security-heavy):

1. Credential resolution was centralized and hardened.
- Added `resolveGatewayCredentialsFromConfig` integration and SecretRef resolution path.
- New async credential flow:
  - `resolveGatewayCredentialsWithEnv(...)`
  - `resolveGatewayCredentialsWithSecretInputs(...)` (new export)
- This adds mode-aware token/password precedence and SecretRef expansion before request execution.
- Upstream anchors (`v2026.3.2` `src/gateway/call.ts`): imports at line 21, `resolveGatewayCredentialsWithEnv` at line 340, export `resolveGatewayCredentialsWithSecretInputs` at line 493.

2. URL override auth gating got stricter.
- `ensureExplicitGatewayAuth(...)` signature changed:
  - now takes `urlOverrideSource`, `explicitAuth`, `resolvedAuth` (not just `auth`).
- Security behavior:
  - CLI URL override requires explicit CLI credentials.
  - ENV URL override only proceeds when resolved auth exists (prevents implicit token fallback to attacker-controlled endpoint).
- Upstream anchors: `ensureExplicitGatewayAuth` starts at line 91; `urlOverrideSource` flow at lines 93-116; resolved-auth enforcement wired at `callGatewayWithScopes` lines 685-693.

3. Connection target + insecure transport checks were revised.
- Local self-connection target forced to loopback in upstream pattern.
- `OPENCLAW_ALLOW_INSECURE_PRIVATE_WS=1` break-glass path added to `isSecureWebSocketUrl(...)` check.
- Error guidance expanded with remote-access recommendations and `openclaw doctor --fix` hint.
- Upstream anchors: loopback local URL path in `buildGatewayConnectionDetails` lines 143-149; break-glass flag at line 177 and check at line 181.

4. Method capability guard added.
- `requiredMethods?: string[]` added to `CallGatewayBaseOptions`.
- New `ensureGatewaySupportsRequiredMethods(...)` validates gateway Hello features before making request.
- Upstream anchors: option added at line 48; guard function at line 565; invoked in `onHelloOk` lines 641-645.

5. Scope plumbing remains least-privilege-oriented.
- Upstream keeps split entry points (`callGatewayScoped`, `callGatewayCli`, `callGatewayLeastPrivilege`, `callGateway`) and least-privilege default path for backend callers.

## What Clawline Depends On From `call.ts`
Current Clawline-specific import usage found:
- `src/clawline/server.ts` imports `callGateway` only.
- Anchor: import at `src/clawline/server.ts:55`.

Current Clawline call site:
- `src/clawline/server.ts` alert wake path calls `callGateway({ token, method: "agent", params: {...}, expectFinal: true, timeoutMs: 60_000 })`.
- It passes `params.channel` from alert origin (`origin?.channel`) and does not call helper exports like `ensureExplicitGatewayAuth` directly.
- Anchors: call at `src/clawline/server.ts:3328`, method at line 3330, channel pass-through at line 3334.

Compatibility impact:
- `callGateway(...)` remains exported and callable with existing Clawline options.
- Upstream adds optional fields (`requiredMethods`, etc.) without breaking existing Clawline call shape.

## Current Fork Divergence in This File
`git diff aba15763b HEAD -- src/gateway/call.ts` shows the fork already diverged from the old baseline, but is still missing upstream v2026.3.2 auth/secrets hardening.

Additional branch-local (uncommitted) divergence exists right now on `clawline-surface-provider`:
- `git diff -- src/gateway/call.ts` shows local edits reintroducing LAN/tailnet host selection and local insecure-ws bypass heuristics (`isLocalResolvedTarget`).
- This is not part of upstream v2026.3.2 pattern and is a pre-merge cleanup item.
- Working-tree anchors (`src/gateway/call.ts`): host selection lines 121-125, local bypass guard lines 149-150.

## Conflict Summary
Primary collision:
- Fork file is on a pre-v2026.3.2 auth model.
- Upstream file introduces new credential resolution and URL-override security semantics.

Secondary collision risk:
- The branch-local working-tree edits in `call.ts` directly conflict with upstream connection/auth posture.

## Safe Migration Path
1. Adopt upstream `src/gateway/call.ts` from `v2026.3.2` as the canonical base.
- Do not manually port old fork auth code paths.
- Keep upstream exports and signatures intact, including `resolveGatewayCredentialsWithSecretInputs` and `requiredMethods` support.

2. Preserve Clawline behavior by validating call-site compatibility, not by forking `call.ts` internals.
- Keep `src/clawline/server.ts` calling `callGateway(...)` as-is unless type break appears (none expected).
- Ensure alert wake still passes explicit `token` and `channel` in `params`.

3. Handle branch-local `call.ts` edits as cleanup.
- Remove/resolve local uncommitted `call.ts` divergence before merge resolution.
- If LAN/tailnet local-host behavior is still required, spec it separately and reintroduce only with explicit upstream-compatible justification.

4. No Clawline-specific hooks should be added to `call.ts`.
- Follow merge philosophy: preserve behavior through call-site compatibility and adjacent handler fixes, not core-file embellishment.

## Collision-Adjacent Invariant Note (High Risk)
The historical fork commit `dacc8e137` ("Gateway: use request channel in send-policy checks") does not modify `src/gateway/call.ts`; it modifies `src/gateway/server-methods/agent.ts`.

Why this matters:
- Upstream `v2026.3.2` `server-methods/agent.ts` still computes send policy with `channel: entry?.channel` (no request-channel fallback at that call site).
- Current fork branch uses `channel: entry?.channel ?? requestChannel`.
- Anchors:
  - Upstream tag: `src/gateway/server-methods/agent.ts` send-policy call at lines 424-428.
  - Current branch: `src/gateway/server-methods/agent.ts` request-channel fallback at lines 410-418.

Implication:
- Request-channel send-policy invariant is not natively covered by `call.ts` merge and must be preserved in the `server-methods/agent.ts` collision zone.
- Treat this as required cross-zone tracking so auth/routing behavior for Clawline messages does not regress.

## Verification Checklist (Post-Merge)
1. File-level parity and API checks.
- `git diff v2026.3.2 -- src/gateway/call.ts` should be empty or contain only explicitly approved minimal divergence.
- `rg "export async function callGateway\(|resolveGatewayCredentialsWithSecretInputs|requiredMethods\?:" src/gateway/call.ts`

2. Clawline import/call-site integrity.
- `grep -R "from.*gateway/call\|require.*gateway/call" src/clawline/ extensions/clawline/`
- Confirm `src/clawline/server.ts` still compiles with `callGateway` import and alert wake call.

3. Behavior smoke checks.
- Clawline `/alert` wake path still triggers gateway `agent` call with explicit token.
- Remote/local gateway connection still succeeds under expected auth modes.
- URL override without explicit creds fails with upstream guard behavior.

4. Cross-zone invariant check (send-policy channel).
- In `src/gateway/server-methods/agent.ts`, verify send-policy check still uses request channel identity fallback for Clawline-originated requests.

## Blockers / Risks
- Ref mismatch risk: `upstream/v2026.3.2` not present locally; use tag `v2026.3.2` (same target commit).
- High regression risk if local branch-only `call.ts` edits are accidentally carried into merge without explicit approval.
- Request-channel send-policy invariant is outside `call.ts`; if ignored in adjacent collision handling, Clawline auth/routing may regress despite a clean `call.ts` merge.
