# Clawline Extension Isolation — Non-Obvious Details

## Outbound sender bridge state must move to extension-owned — not stay in core global state
The current Clawline outbound delivery uses a single mutable sender reference registered via plugin-sdk. Post-migration, that registration state is extension-owned. This means: if the extension is reloaded or replaced, the outbound bridge state is properly scoped to the extension lifetime — not leaked into core global state that outlives the extension.

## Migration rule: only existing import edges may be rewritten to relative paths
Phase 1 may rewrite existing runtime imports from plugin-sdk to explicit `../../../../src/*` paths, but ONLY for import edges that already existed pre-migration. No new deep imports into core may be introduced as part of T141. If a new core helper is needed, that is a Gap D blocker requiring spec revision before proceeding.

## The move set is precisely defined — do not move generic shared core modules
Only move files owned by the Clawline provider runtime (service.ts, server.ts, routing.ts, outbound.ts, announce-queue.ts, attachments.ts, config.ts, domain.ts, errors.ts, gateway-client.ts, http-assets.ts, per-user-task-queue.ts, rate-limiter.ts, session-key.ts, session-store.ts, system-events.ts). Do NOT create extension-local copies of shared core helpers. If a file under `src/clawline/*` also serves as a non-Clawline shared API, stop and request spec clarification.

## Plugin-SDK Clawline-specific exports are removed post-migration
After Gap B is closed, `src/plugin-sdk/index.ts` no longer exports `ClawlineDeliveryTarget`, `sendClawlineOutboundMessage`, or `startClawlineService`. Extensions that relied on these must import from the local extension runtime instead. This is a breaking change for any external code that imported these from plugin-sdk.

## All five canonical invariants must remain stable across the migration
Session keys remain the sole routing identifiers. Session key shapes are unchanged. Mobile protocol behavior is unchanged (wire messages, sequencing, stream REST, terminal/interactive attachment). Admin vs personal channel behavior is unchanged. Clawline-specific behavior stays in extension-owned modules after migration. Any migration step that changes any of these invariants is out of scope and requires a new spec.
