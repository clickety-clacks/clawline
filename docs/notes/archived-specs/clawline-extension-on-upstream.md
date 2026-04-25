# Clawline Extension On Upstream

Date: 2026-04-08

## Goal

This document described a transition plan for moving Clawline toward a standalone-ish extension on top of upstream OpenClaw. That path is now blocked under Flynn's current rule: if any OpenClaw core change is required, we do not do the extension. The document is retained as historical analysis, not as an active execution contract.

Flynn directive for this plan:

- Keep behavior and UX stable during the migration.
- Drive toward a Clawline extension that can eventually live outside the fork, with the likely final home at `~/clawline/extension`.
- Treat merge timing as a sequencing decision, not as a permanent constraint of the architecture.

## Decision Summary

1. The current fork remains the implementation home base during the transition.
2. The immediate target is to make Clawline run as an extension against stock upstream. Whether that happens before or after a `v2026.4.8` merge is a sequencing choice, not a hard architectural requirement.
3. `extensions/clawline/` becomes the only long-term Clawline-owned code area inside the fork. Core `src/clawline/*` is transition debt that must trend toward zero.
4. shrdlu must run **stock upstream OpenClaw** as the test base. Clawline is proven there as an extension layer, not as forked core behavior.
5. No behavioral or UX changes are allowed as part of this migration unless a separate spec explicitly authorizes them.

## Non-Goals

- Do not redesign Clawline pairing, auth, stream UX, terminal UX, or adopted-session UX.
- Do not broaden session-key formats, routing identifiers, or mobile wire contracts.
- Do not invent new Clawline-specific core APIs.
- Do not extract to `~/clawline/extension` yet.
- Do not move Clawline HTTP/WS endpoints into gateway plugin-route registration just to look "more upstream." Clawline remains a service-style extension unless a later spec changes that.
- Do not use this migration to solve separate feature work such as multi-agent routing generalization or session-ownership redesign.

## Source Set

This spec integrates the current source material that already exists in the shared workspace and adjacent Clawline notes:

- Feasibility recon:
  - `/Users/mike/src/clawline/scratch/docs-drift/docs/specs/clawline-pure-extension-feasibility.md`
- Isolation / plugin encapsulation proof:
  - `/Users/mike/shared-workspace/clawline/implementation_details/clawline-extension-isolation.md`
- Clawline invariants:
  - `/Users/mike/shared-workspace/clawline/implementation_details/clawline-invariants.md`
- Upstream core-surface memos:
  - `/Users/mike/src/clawline/scratch/docs-drift/docs/specs/rebase-2026-03-03/channel-runtime.md`
  - `/Users/mike/src/clawline/scratch/docs-drift/docs/specs/rebase-2026-03-03/plugin-http-contract.md`
  - `/Users/mike/src/clawline/scratch/docs-drift/docs/specs/rebase-2026-03-03/plugin-sdk-exports.md`
- Feature-adoption memos:
  - `/Users/mike/shared-workspace/clawline/specs/track-adopted-delivery-recon.md`
  - `/Users/mike/shared-workspace/clawline/specs/track-non-clawline-sessions.md`

Note: no file with a literal `v2026.4.8` identifier was present in the shared workspace or adjacent `~/src/clawline` notes on 2026-04-08. For this plan, the existing pure-extension feasibility recon plus the upstream surface memos are treated as the operative recon baseline.

## Upstream Proof Baseline

For this spec, `stock upstream OpenClaw` means:

- the latest tagged upstream OpenClaw release at the time the shrdlu proof is executed
- not upstream `main`
- not an arbitrary upstream commit
- not a forked runtime carrying Clawline-specific core behavior

The exact tag used for the proof run must be recorded in the implementation artifact or validation matrix.

## Target Architecture

### End-state shape

Clawline becomes a service-style extension that runs on stock upstream OpenClaw using generic upstream plugin/service/runtime surfaces.

The intended ownership boundary is:

- Upstream OpenClaw core owns:
  - generic plugin lifecycle
  - generic runtime helpers
  - generic session store and routing infrastructure
  - generic plugin HTTP support
  - generic channel runtime support
- Clawline extension owns:
  - Clawline provider server lifecycle
  - Clawline HTTP and WebSocket endpoints
  - Clawline routing helpers
  - Clawline outbound delivery bridge
  - Clawline stream persistence rules
  - Clawline adopted-session behavior
  - Clawline static assets / web surface

### Required extension layout

During transition, the extension should be shaped so it can later move with minimal churn into `~/clawline/extension`.

The following in-fork layout is the reference target unless engineering can show an equivalent structure that preserves the same ownership boundary and future extractability:

- `extensions/clawline/index.ts`
- `extensions/clawline/src/runtime/*`
- `extensions/clawline/src/channel.ts`
- `extensions/clawline/src/actions.ts`
- `extensions/clawline/src/outbound.ts`
- `extensions/clawline/www/*` or equivalent extension-owned asset path
- extension-owned tests adjacent to the extension/runtime code

The runtime subtree must be laid out as if it will later be moved wholesale into:

- `~/clawline/extension/index.ts`
- `~/clawline/extension/src/runtime/*`
- `~/clawline/extension/src/*`

### What stays stable

The migration is an encapsulation move, not a product change. These remain stable throughout:

1. Session keys remain the sole routing identifiers.
2. Session-key shapes remain unchanged.
3. Mobile protocol behavior remains unchanged.
4. Admin vs personal channel behavior remains unchanged.
5. Track/adopt/untrack UX remains unchanged.
6. Stream REST behavior remains unchanged.
7. Terminal and interactive attachment behavior remains unchanged.
8. Pair/auth UX and auth-result/session-info semantics remain unchanged.

## Exact Remaining Seams

These are the only seams this plan recognizes as relevant to the extension transition.

### Seam A: Runtime ownership still lives in core

Current problem:

- Clawline provider runtime still lives under core `src/clawline/*`.

Required end state:

- Clawline runtime lives under `extensions/clawline/src/runtime/*`.

Files explicitly in scope for runtime relocation:

- `service.ts`
- `server.ts`
- `routing.ts`
- `outbound.ts`
- `announce-queue.ts`
- `attachments.ts`
- `config.ts`
- `domain.ts`
- `errors.ts`
- `gateway-client.ts`
- `http-assets.ts`
- `per-user-task-queue.ts`
- `rate-limiter.ts`
- `session-key.ts`
- `session-store.ts`
- `system-events.ts`

Constraint:

- Do not copy shared generic helpers into the extension. Only Clawline-owned runtime files move.

### Seam B: Clawline-specific plugin-sdk carveouts still exist

Current problem:

- `openclaw/plugin-sdk` still exports Clawline-specific symbols used by the extension:
  - `ClawlineDeliveryTarget`
  - `sendClawlineOutboundMessage`
  - `startClawlineService`
  - `ClawlineServiceHandle`

Required end state:

- The extension imports these capabilities from its local runtime, not from plugin-sdk.
- Core plugin-sdk exports become Clawline-free again.

Constraint:

- No replacement Clawline-only core SDK surface is allowed.

### Seam C: Outbound bridge ownership is still core-global

Current problem:

- Clawline outbound delivery still depends on a mutable sender bridge owned by core runtime state.

Required end state:

- Sender registration and teardown are owned by the extension runtime lifecycle.
- Reloading or replacing the extension must not leave outbound state behind in core-global memory.

### Seam D: Generic runtime-helper access is incomplete for service-style extensions

Current problem:

- Upstream now has better generic surfaces such as `channelRuntime`, plugin HTTP registration, and service lifecycle support, but service-style extensions still do not get every generic runtime helper through one clean service context.
- The remaining helper/import edges that still need explicit accounting are:
  - the final production network-helper replacement identified in the encapsulation proof (`src/gateway/net.js` -> public SSRF/runtime seam)
  - any service-context access still needed by Clawline runtime startup/shutdown code after relocation
  - any helper needed for adopted-session visibility/origin handling that is not already covered by current generic session/runtime surfaces

Required end state:

- Clawline should run using existing upstream generic surfaces where they already exist.
- If a missing generic seam truly blocks encapsulation, the follow-up change must be:
  - generic
  - upstream-shaped
  - separately specified

Constraint:

- Do not add a Clawline-specific service/runtime hook to core.
- During transition inside the fork, existing import edges may be rewritten to explicit relative core paths only if that edge already existed before the relocation. No new deep-import edges may be introduced.

### Seam E: Adopted-session origin and visibility remain extension-owned behavior

Current problem:

- Adopted non-Clawline sessions depend on provider-specific allowlisting, origin metadata, persistence rules, and route reconstruction.
- Current recon shows core routing is mostly not the blocker, but a trustworthy server-owned visibility signal may still be incomplete.

Required end state:

- Adopted-session behavior remains extension-owned.
- Native Clawline stream semantics are not broadened.
- `parseClawlineUserSessionKey()` remains strict and Clawline-native only.
- Non-Clawline adopted keys take a separate extension path built from real origin metadata.

Constraint:

- This migration does not solve session-ownership/security redesign beyond the current documented policy.
- For this phase, shrdlu proof only needs to preserve the currently supported adopted-session behavior, not broaden it.
- If a trustworthy generic visibility signal is required later, that becomes a separate generic core/session-store spec.

### Seam F: iOS/provider `agent:main` assumptions are not part of this encapsulation phase

Current problem:

- Existing notes show remaining `agent:main` assumptions in iOS and some provider defaults.

Policy for this spec:

- Treat this as a separate compatibility track, not as part of the encapsulation move.
- shrdlu extension proof should use the currently supported main-agent behavior unless a later spec explicitly broadens that requirement.

## Migration Policy

This work is a behavior-preserving encapsulation migration. The policy is strict:

1. No user-visible UX changes.
2. No wire-protocol changes.
3. No routing-identifier changes.
4. No new Clawline-only core APIs.
5. No silent policy hardening or behavioral drift.
6. No "future-proofing" additions outside the listed seams.

Behavior-preserving means all of the following stay materially identical from the iOS client's point of view:

- pairing flow
- auth flow
- reconnect/replay behavior
- stream list ordering and mutation behavior
- adopted-session tracking and untracking behavior
- send availability gating
- upload/download behavior
- terminal session behavior
- `/alert` behavior
- `/surf-ace/events` behavior

## Transition-State Policy

Intermediate states may be temporarily mixed during implementation, but only if they are short-lived and explicitly understood as migration states rather than new architecture. The desired bias is to keep the branch deployable whenever practical; if an intermediate state is knowingly non-deployable, that should be brief and local to the migration branch rather than normalized as the working mode.

## Repo And Layout Strategy

### During transition

The fork is the implementation home base.

Rules:

1. Clawline-owned code moves toward `extensions/clawline/**`.
2. Core `src/clawline/**` only shrinks; it does not gain new permanent Clawline behavior.
3. Any unavoidable core changes must be generic and upstream-appropriate.
4. The extension subtree must be organized so it can later move to `~/clawline/extension` with mostly path changes, not logic rewrites.

### Eventual destination

The likely final standalone home would have been:

- `~/clawline/extension`

That extraction should happen only after:

- stock upstream on shrdlu can run Clawline without Clawline-owned core modules
- plugin-sdk carveouts are gone
- outbound bridge ownership is extension-local
- any retained generic seams are stable enough that extraction does not immediately force another restructure

### What not to do

- Do not create a second long-lived Clawline runtime under a different ad hoc path.
- Do not split ownership between `src/clawline/*` and `extensions/clawline/src/runtime/*` indefinitely.
- Do not extract to `~/clawline/extension` before the shrdlu proof is passing.

## Execution Principles

This spec defines the destination and proof bar, not the exact engineering choreography.

Required principles:

1. Sequence however engineering judges best, but preserve the end-state contract in this spec.
2. Prefer shrinking Clawline-owned core surface over adding new permanent Clawline behavior to core.
3. Use stock upstream on shrdlu as the proof environment when the extension work is ready for validation.
4. If a blocker appears, first look for an existing generic upstream seam; only propose a new seam if the blocker is real and generic.
5. Do not treat temporary implementation convenience as permission to change user-visible behavior.

## shrdlu Test-Base Plan

shrdlu is the reality check for this migration.

### Test-base rule

The shrdlu environment must be:

- stock upstream OpenClaw core
- plus Clawline as an extension layer under test

It must **not** be:

- forked core with Clawline carveouts hidden inside it
- a pre-merged `v2026.4.8` fork standing in for upstream

### What shrdlu must prove

At minimum, the following must work against stock upstream:

1. Clawline service startup and shutdown
2. Pairing
3. Auth
4. Message send and reply delivery
5. Replay / reconnect
6. Stream list, create, rename, delete
7. Upload and download
8. Terminal session behavior
9. `/alert`
10. `/surf-ace/events`
11. Track/adopt/untrack flow
12. Send path for adopted sessions using their original origin metadata, limited to the currently supported adopted-session behavior

### Blocker handling on shrdlu

If something fails on shrdlu:

1. identify the exact missing seam
2. classify it as:
   - already covered by Phases 2 or 3
   - resolvable with existing upstream generic surfaces
   - requiring a new generic seam spec
3. stop there

Do **not** patch stock upstream on shrdlu with Clawline-specific escape hatches.

## Validation Method

Every shrdlu proof run must produce a validation artifact that records:

- the exact upstream release tag used as the proof baseline
- the exact Clawline extension revision under test
- validation mode for each proof item and acceptance criterion (`automated`, `scripted smoke`, or `manual check`)
- pass/fail result
- notes for any deferred item or explicitly out-of-scope behavior

At minimum, the validation artifact must map each of the shrdlu proof items and each acceptance criterion below to a concrete validation mode. Engineering may choose the specific test harnesses and scripts.

## Acceptance Criteria

This migration is ready for Flynn verification only when all of the following are true:

1. Clawline runtime ownership has moved from `src/clawline/*` to `extensions/clawline/src/runtime/*`.
2. `extensions/clawline/**` no longer depends on Clawline-specific plugin-sdk exports.
3. Outbound sender bridge ownership is extension-local, not core-global.
4. No new Clawline-specific core APIs were added.
5. Any remaining core touch points are generic and upstream-shaped.
6. stock upstream on shrdlu can boot and run the Clawline extension through the parity matrix above.
7. Pair/auth/stream/adopt/send/terminal behavior remains materially unchanged from current Clawline UX.
8. Session-key routing invariants remain intact.
9. The extension subtree is laid out so it can later move to `~/clawline/extension` without another architecture rewrite.

## Spec Maintenance Notes

- `clawline-invariants.md` currently reflects a pre-migration state in which certain Clawline-specific plugin-sdk carveouts are still documented as required. When Seam B is actually closed, that invariants document must be updated to match the new post-migration truth.
- Any stale path references to the invariants source should be corrected to the canonical shared-workspace location before implementation handoff.

## Sequencing Guidance

This spec does not require one fixed implementation order. It supports any sequencing that preserves the invariants and meets the acceptance criteria.

Likely near-term work:
- move Clawline-owned runtime toward `extensions/clawline/src/runtime/*`
- remove dependence on Clawline-specific plugin-sdk carveouts
- localize outbound bridge ownership
- prepare a stock-upstream shrdlu proof when the extension work is ready

Likely later work:
- extract the extension subtree to `~/clawline/extension`
- revisit upstream merge timing after the extension boundary is proven
- upstream any truly generic seams discovered during proof

## Open Questions

1. What exact packaging mechanism should shrdlu use to layer the Clawline extension onto stock upstream during the proof phase: copied subtree, workspace dependency, or symlinked extension checkout?
2. If Phase 4 uncovers a real blocker around service-context runtime access, what is the narrowest generic upstream-shaped seam that solves it without recreating a Clawline carveout?

## Implementation Handoff

- Implement this as a pure encapsulation program, not as merge cleanup.
- Treat shrdlu stock upstream as the source of truth for whether the extension boundary is real.
- If implementation pressure starts pushing new permanent Clawline code back into core, stop and revise the spec instead of improvising.
