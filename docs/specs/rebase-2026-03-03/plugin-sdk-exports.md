# Migration Spec: plugin-sdk Clawline Export Collision (v2026.3.2)

## Goal
Preserve invariant **B13** during upstream merge to `v2026.3.2` by ensuring Clawline SDK exports remain available to `extensions/clawline` while adopting upstream Plugin SDK structure with minimal divergence.

## Non-Goals
- Re-architecting Clawline service lifecycle.
- Rewriting `extensions/clawline` to a new API surface in this merge.
- Adding new core hooks beyond required Clawline export re-introduction.

## Upstream Change Summary (`aba15763b..v2026.3.2`)
Command evidence:
- `git diff aba15763b v2026.3.2 -- src/plugin-sdk/index.ts`
- `git diff --stat aba15763b v2026.3.2 -- src/plugin-sdk/index.ts`

Observed upstream delta in `src/plugin-sdk/index.ts`:
- **289 insertions, 8 deletions**.
- New shared helper exports across:
  - auth/routing/pairing helpers
  - webhook/file-lock/lifecycle guards
  - outbound/media/runtime helpers
  - secret/SSRF/security utilities
  - shared config/group-policy/status helpers
- Upstream removed fork-only Clawline exports from this file:
  - `ClawlineDeliveryTarget`
  - `sendClawlineOutboundMessage`
  - `startClawlineService` / `ClawlineServiceHandle`

Related upstream SDK packaging changes:
- `package.json` exports now include typed subpath structure for `./plugin-sdk` and additional SDK subpaths (e.g. keyed async queue).

## Fork-Only Clawline Exports and Current Locations (HEAD)
`src/plugin-sdk/index.ts` currently exports:
- Line 244: `export { ClawlineDeliveryTarget } from "../clawline/routing.js";`
- Line 469: `export { sendClawlineOutboundMessage } from "../clawline/outbound.js";`
- Line 470: `export { startClawlineService, type ClawlineServiceHandle } from "../clawline/service.js";`

What these do:
- `ClawlineDeliveryTarget` (`src/clawline/routing.ts`): canonical parse/format for `userId:sessionLabel` and conversion to session keys.
- `sendClawlineOutboundMessage` (`src/clawline/outbound.ts`): extension-facing outbound send entrypoint backed by runtime sender injection.
- `startClawlineService` + `ClawlineServiceHandle` (`src/clawline/service.ts`): starts Clawline provider service and returns stop/runtime handle used by plugin service lifecycle.

## Consumer Impact (Why this is required)
`extensions/clawline` currently imports these symbols from `openclaw/plugin-sdk`:
- `extensions/clawline/index.ts`: `startClawlineService`
- `extensions/clawline/src/channel.ts`: `ClawlineDeliveryTarget`
- `extensions/clawline/src/actions.ts`, `extensions/clawline/src/outbound.ts`, tests: `sendClawlineOutboundMessage`

If these exports are dropped during merge conflict resolution, extension build/typecheck/runtime fail.

## channelRuntime Pattern Evaluation (commit `469cd5b46`)
Upstream introduced optional `channelRuntime?: PluginRuntime["channel"]` on `ChannelGatewayContext` (via `src/channels/plugins/types.adapters.ts` and gateway wiring).

Assessment:
- This is a **better upstream pattern for external channel plugins that run in `gateway.startAccount` flows** and need shared runtime helpers.
- It **does not subsume** current Clawline exports:
  - `startClawlineService`/`ClawlineServiceHandle` are plugin service lifecycle APIs, not channel-runtime helper APIs.
  - `sendClawlineOutboundMessage` is tied to Clawline provider service sender injection, used outside `startAccount` context.
  - `ClawlineDeliveryTarget` is Clawline-specific addressing semantics.

Conclusion:
- Adopt upstream channelRuntime pattern generally where relevant, but **do not replace B13 exports in this merge**.
- Replacing them would require a larger Clawline architecture rewrite (out of scope for this collision fix).

## Migration Path (Conflict Resolution)
1. Take upstream `v2026.3.2` `src/plugin-sdk/index.ts` as base.
2. Re-add fork-only Clawline exports with minimal patching at stable anchors:
- After `export { recordInboundSession } from "../channels/session.js";`, re-add:
  - `export { ClawlineDeliveryTarget } from "../clawline/routing.js";`
- Near the bottom, after media utility export block (after `loadWebMedia`), re-add Clawline service block:
  - `export { sendClawlineOutboundMessage } from "../clawline/outbound.js";`
  - `export { startClawlineService, type ClawlineServiceHandle } from "../clawline/service.js";`
3. Keep upstream additions intact; do not remove or reorder upstream exports except for inserting these 3 lines.

## Better Home Decision
For this merge, keep exports in `src/plugin-sdk/index.ts` to preserve current extension import contract (`openclaw/plugin-sdk`) and minimize risky scope expansion.

Potential follow-up (not in this merge): introduce a dedicated Clawline SDK subpath plus compatibility re-exports if we explicitly choose to migrate extension imports later.

## Verification
Run after merge conflict resolution:

1. Export presence checks:
- `grep -n "sendClawline\|startClawline\|ClawlineDeliveryTarget\|ClawlineServiceHandle" src/plugin-sdk/index.ts`

2. Consumer import checks:
- `grep -R "from.*openclaw/plugin-sdk" -n extensions/clawline/src/ extensions/clawline/index.ts`
- Confirm files importing these symbols still compile against root SDK export.

3. Type/build gate:
- `pnpm build`

4. Optional targeted tests:
- `pnpm test extensions/clawline/src/actions.test.ts`

## Blockers / Risks
- No blocker for preserving B13 exports.
- Intractable-for-this-merge risk: fully migrating Clawline outbound/service behavior to channelRuntime would require redesign of plugin service lifecycle and outbound sender ownership; this should be treated as a separate spec.
