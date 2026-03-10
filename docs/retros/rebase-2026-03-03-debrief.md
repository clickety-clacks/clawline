# Rebase Debrief — 2026-03-03 (for Flynn)

## Context
- Upstream target merged: `v2026.3.2` (`85377a281`).
- Merge commit: `263905814`.
- Post-merge Clawline test-alignment commit: `00d2e68fa`.
- Recon baseline: `~/.openclaw/workspace/clawline-rebase-recon-2026-03-03.md` (Top 5 speed bumps section).

## 1) Major conflicts that required active refactoring (not just taking upstream)

### A) `src/config/plugin-auto-enable.ts` — upstream auto-enable refactor + Clawline policy preservation
This was a real rewrite zone.

What changed upstream:
- Auto-enable logic moved to a more structured pattern (manifest-registry driven channel->plugin mapping, unified structured channel config specs, broader provider/plugin detection).

What had to be actively reconciled for Clawline:
- Under raw upstream behavior, a configured `channels.clawline` path would be treated like auto-enable candidates and could be enabled too aggressively.
- We added explicit Clawline handling so configured Clawline is registered in plugin entries as disabled by default:
  - `plugins.entries.clawline.enabled = false`
  - change note: `"clawline configured, not enabled yet."`

Why this was real refactoring:
- This was not a one-line accept/reject merge. It required integrating Clawline-specific policy into the new upstream architecture without regressing the new manifest-driven pattern.

### B) `src/infra/outbound/message-action-params.ts` — attachment hydration pipeline reconciliation
This was another real refactor, not a pure upstream accept.

What changed upstream:
- Attachment hydration moved toward policy-driven media loading (`AttachmentMediaPolicy`), shared boolean param parsing, and unified per-action attachment handling.

What had to be actively reconciled for Clawline behavior:
- Added buffer-object compatibility normalization for `sendAttachment` (`Buffer`, `Uint8Array`, and `{type:"Buffer",data:[...]}` forms).
- Added explicit loopback SSRF allowance for `localhost`/`127.0.0.1`/`::1` media fetches so local provider workflows keep working under stricter upstream media guards.

Why this was real refactoring:
- Required adding compatibility transforms and SSRF-policy shaping inside the new upstream media-policy structure.

### C) `src/gateway/server-methods/agent.ts` — send policy in new ingress flow
This was a targeted but important behavior reconciliation.

What changed upstream:
- Handler flow moved to newer ingress path (`agentCommandFromIngress`, stronger session merge semantics, richer delivery-plan handling).

What had to be actively reconciled:
- Preserved Clawline request-channel fallback for send-policy resolution:
  - `channel: entry?.channel ?? requestChannel`
- Added targeted regression test in `src/gateway/server-methods/agent.test.ts` to prove fallback still works when stored session channel is absent.

Why this was real refactoring:
- The upstream ingestion flow changed materially; preserving this behavior required stitching the fallback into the new structure, not keeping old code.

### D) `src/plugin-sdk/index.ts` — critical export collision repair
This was not a large code restructure, but it was a high-impact merge conflict repair.

What had to be restored manually:
- `ClawlineDeliveryTarget`
- `sendClawlineOutboundMessage`
- `startClawlineService` / `ClawlineServiceHandle`

Why it matters:
- Upstream no longer has these symbols; they can disappear silently during conflict resolution unless explicitly re-added.

## 2) Upstream patterns adopted that are real improvements

1. WS auth/connect hardening split (`ws-connection` auth/context/policy/flood modules) and stricter handshake paths.
2. `run.ts` lifecycle hardening (retry loop caps, richer failover handling, copilot token refresh lifecycle).
3. `buildAllowedModelSet` explicit-allowlist trust + synthetic catalog entry behavior (cleaner than prior fork-specific fallback branching).
4. `gateway/call.ts` auth/security hardening (explicit auth enforcement, loopback/insecure path guardrails).
5. Routing/session normalization and caching (`resolve-route.ts`, `channels/session.ts`) moved to a cleaner indexed/canonicalized model.

Net: these reduce bespoke fork logic and improve future rebase maintainability.

## 3) Concerns / risks to review

1. **Repeat silent-drop risk in `plugin-sdk/index.ts`.**
   - Clawline exports are still outside upstream; future merges can silently remove them again.

2. **Loopback SSRF carve-out in attachment loading needs continued scrutiny.**
   - It is intentional for local workflows, but should stay narrowly scoped and reviewed for abuse surfaces.

3. **Auto-enable policy subtlety for Clawline.**
   - Keeping Clawline configured-but-disabled is deliberate, but onboarding/operator expectations should be explicit in docs and tests.

4. **Behavior shifts surfaced in tests (DM stream expectations).**
   - `src/clawline/server.test.ts` needed updates for upstream DM-scope behavior and naming (`Global DM`).
   - This indicates assumptions in Clawline tests were tighter than the actual post-merge contract.

5. **Residual test flakiness indicator.**
   - `src/secrets/resolve.test.ts` needed timeout increase (`500 -> 2000` ms) for no-output exec fallback under heavy parallel load.

## 4) Surprises

1. The biggest predicted technical landmines (`run.ts`, `model-selection.ts`, `gateway/call.ts`) ended up mergeable to upstream shape with no remaining fork delta in those files.
2. Plugin HTTP contract migration (predicted speed bump) was effectively a non-event for Clawline because Clawline does not use that registration path.
3. More real friction came from adjacent behavior seams not highlighted as top-5 blockers:
   - Clawline auto-enable semantics
   - attachment hydration compatibility + loopback media behavior
   - request-channel fallback in gateway agent send policy
4. Test-surface fragility was higher than expected around DM stream assumptions.

## 5) Recon prediction accuracy (Top 5 speed bumps)

Overall verdict: **mixed accuracy** — useful directional warning, but only partially predictive of where implementation pain actually occurred.

### Speed bump scorecard

1. **Plugin SDK export drop risk**
- Prediction: would silently drop Clawline exports.
- Actual: **materialized exactly**. We had to re-add all three Clawline exports.
- Accuracy: **High**.

2. **`src/gateway/call.ts` high-risk conflict zone**
- Prediction: likely subtle auth/connect regression risk requiring deep conflict handling.
- Actual: **did not materially materialize in final delta**; file ended at upstream parity.
- Accuracy: **Over-predicted for this merge execution**.

3. **Triple collision (`run.ts`, `model-selection.ts`, `defaults.ts`)**
- Prediction: major manual reconcile across all three.
- Actual: **partially materialized**.
  - `defaults.ts`: yes (manual alias preservation for `sonnet-4.5`/`sonnet-4.6`).
  - `run.ts` and `model-selection.ts`: upstream shape adopted cleanly with no surviving fork delta.
- Accuracy: **Partial**.

4. **Plugin HTTP contract migration**
- Prediction: required migration work.
- Actual: **did not materialize for Clawline** (Clawline doesn’t use `registerHttpHandler`/`registerHttpRoute` path).
- Accuracy: **Low for Clawline scope**.

5. **Session/routing behavior shifts**
- Prediction: could alter delivery targets and require focused validation.
- Actual: **partially materialized** as behavior/test expectation shifts (DM scope/naming) rather than a routing-code conflict.
- Accuracy: **Medium**.

### What recon missed
- The most concrete merge-work friction was in:
  - `plugin-auto-enable.ts` Clawline configured-but-disabled policy,
  - `message-action-params.ts` attachment compatibility + loopback SSRF policy,
  - `server-methods/agent.ts` request-channel send-policy fallback preservation.

These were not called out as top-priority speed bumps but required active code reconciliation.

## Final statement
The recon was directionally helpful for identifying high-churn files and protecting against silent export loss, but it overestimated some headline conflict zones and underweighted the adjacent behavioral seams that actually required hands-on refactoring. The “5 speed bumps” were **not fully accurate as a predictive set**: one hit exactly, two were partial, and two did not materially materialize in this merge.
