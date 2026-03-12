# Clawline Extension Isolation (T141)

## Goal
Implement Clawline extension isolation by closing the three feasibility gaps with Clawline-only changes:
- Gap A: move Clawline runtime ownership from `src/clawline/*` into `extensions/clawline/src/runtime/*`
- Gap B: remove Clawline-specific `openclaw/plugin-sdk` carveouts from extension code
- Gap C: transfer outbound delivery bridge ownership from core-global state to extension runtime

## Non-Goals
- Gap D (new generic service-context/runtime-helper APIs) is out of scope.
- No protocol redesign, no new routing identifiers, no stream lifecycle redesign.
- No behavior changes to admin/personal channel semantics.
- No new generic core plugin APIs.

## Canonical Invariants (must stay stable)
1. Session keys remain the sole routing identifiers.
2. Session-key shapes remain unchanged (`agent:<agentId>:main` and `agent:<agentId>:clawline:<userId>:<suffix>`).
3. Mobile protocol behavior remains stable (wire messages, sequencing, stream REST contract, terminal and interactive attachment behavior).
4. Admin vs personal channel behavior remains unchanged.
5. Clawline-specific behavior remains isolated to extension-owned modules after migration.

## Baseline (pre-change)
- Extension starts provider via `startClawlineService` from plugin-sdk.
- Extension outbound/actions send via `sendClawlineOutboundMessage` from plugin-sdk.
- Extension threading parses targets with `ClawlineDeliveryTarget` from plugin-sdk.
- Provider runtime and outbound sender bridge live under core `src/clawline/*`.

## Target End State
- Runtime source of truth is `extensions/clawline/src/runtime/*`.
- Extension code imports Clawline runtime modules locally (no Clawline-specific plugin-sdk imports).
- Outbound sender bridge state is extension-owned.
- `src/plugin-sdk/index.ts` no longer exports Clawline-specific carveouts.
- Core `src/clawline/*` runtime implementation is removed.

## Migration Plan

### Phase 0: Contract lock
- Use this spec as implementation contract.
- Keep scope to gaps A/B/C only.

Gate:
- Spec accepted as implementation source of truth.

### Phase 1: Runtime relocation (Gap A)
- Move Clawline runtime implementation files from `src/clawline/*` to `extensions/clawline/src/runtime/*` (including utilities and tests).
- Preserve logic, constants, error messages, and default values.
- Perform mechanical import rewrites only:
  - intra-runtime imports become local relative imports
  - core shared dependencies are rewritten to explicit `../../../../src/*` style paths from new runtime location

Gate:
- Runtime test suite in new location passes.
- No behavior diffs introduced intentionally.

### Phase 2: Internalize plugin-sdk carveouts (Gap B)
- Replace extension imports of these plugin-sdk carveouts:
  - `startClawlineService`
  - `sendClawlineOutboundMessage`
  - `ClawlineDeliveryTarget`
- Extension `index.ts`, `channel.ts`, `actions.ts`, `outbound.ts`, and related tests switch to extension-local runtime imports.

Gate:
- Extension Clawline tests pass (`actions`, `channel`, `surf-ace-tools`, schema tests).
- Clawline behavior parity remains intact.

### Phase 3: Outbound bridge ownership + cleanup (Gap C)
- Keep sender registration lifecycle in extension runtime service start/stop.
- Remove Clawline carveout exports from `src/plugin-sdk/index.ts`.
- Delete obsolete core `src/clawline/*` implementation once no references remain.

Gate:
- No remaining imports reference core `src/clawline/*`.
- Outbound flows still succeed through extension-owned sender bridge.

### Phase 4: Final verification
- Run targeted Clawline and extension tests again.
- Run repository build gate (`pnpm build`).

Gate:
- Build succeeds and all selected tests pass.

## Risks and Mitigations
1. Import path breakage during move
- Mitigation: mechanical move first, run tests immediately, keep logic untouched.

2. Hidden protocol drift in server runtime
- Mitigation: preserve runtime code as-is; rely on existing server/runtime tests.

3. Session-key routing regressions
- Mitigation: keep routing/session modules unchanged in behavior; validate via runtime tests.

4. Outbound bridge regressions
- Mitigation: preserve start/stop sender registration semantics and extension action/outbound tests.

5. Over-coupling to core internals
- Mitigation: accepted in T141 because Gap D is out of scope; avoid introducing any additional coupling beyond migrated runtime needs.

## Acceptance Checks
1. `extensions/clawline` no longer imports Clawline carveouts from `openclaw/plugin-sdk`.
2. `src/plugin-sdk/index.ts` no longer exports Clawline carveouts.
3. Clawline runtime implementation resides under `extensions/clawline/src/runtime/*`.
4. Outbound delivery bridge ownership is extension runtime-owned.
5. Session-key and mobile protocol behavior remain stable by existing tests.
6. `pnpm build` passes after migration.

## Implementation Handoff
- Implement phases in order, running tests between phases.
- Do not implement Gap D or extra architecture changes.
- If a blocker requires Gap D behavior, stop and request clarification.

---

## Appendix: Preserved Notes

### From: specs/clawline-pure-extension-feasibility.md

**Clawline pure-extension feasibility: YES (0.79 confidence), but not flip-ready without bounded migration.**

**Exact core gaps blocking pure-extension parity:**

Gap A: Clawline runtime lives in core, not extension.
- Core service bootstrap still in `src/clawline/service.ts`
- Core provider server still in `src/clawline/server.ts`
- Extension (`extensions/clawline/index.ts`) starts the core service rather than owning its own engine

Gap B: Clawline-specific plugin-sdk carveouts remain.
- `ClawlineDeliveryTarget` and `sendClawlineOutboundMessage` exported from `src/plugin-sdk/index.ts`
- Extension depends directly on these from `channel.ts`, `outbound.ts`, `index.ts`

**Migration path:** Phase 1 — move core Clawline engine into extension; Phase 2 — generalize plugin-sdk surface and remove Clawline-specific carveouts. Keep session-key invariants and mobile protocol behavior stable throughout.

---

### Preserved from deleted non-core doc: clawline-extension-consolidation.md

**Skills that belong in `extensions/clawline/` (not upstream `skills/`):**
`clawline-alert-overlay`, `clawline-allowlist`, `clawline-gateway-ops`, `clawline-media`, `clawline-pairing` — all are fork-only contributions.

**Missing skill:** No skill exists for the `webRootPath` feature (serves static files at `/www`).

**Device management consolidation needed:** `allowlist` and `pairing` skills should be merged into one `device-management` skill.

**Agent guidance files** (`~/.openclaw/workspace/AGENTS.md`, `(local agent guidance file, not part of core docs)` in `src/clawline/`) should move into `extensions/clawline/` alongside code.
