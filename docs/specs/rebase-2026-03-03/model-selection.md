# model-selection.ts migration (rebase 2026-03-03)

## Scope
- Collision zone: `src/agents/model-selection.ts` (`buildAllowedModelSet` focus).
- Related alias check: `src/config/defaults.ts` (`sonnet-4.5`, `sonnet-4.6`).
- Baseline diff analyzed: `git diff aba15763b v2026.3.2 -- src/agents/model-selection.ts`.

## What changed upstream
From `aba15763b` to `v2026.3.2`, upstream changed `buildAllowedModelSet` from gated allowlisting to explicit allowlist trust:

- Before (older logic): allowlist entry was accepted only if one of:
  - CLI provider, or
  - model present in bundled catalog, or
  - provider present in `models.providers`.
- After (upstream): every explicit allowlist entry is accepted, even if not in bundled catalog.
- Upstream also adds `syntheticCatalogEntries` for missing allowlist refs so they remain visible/selectable in `/models` and fuzzy resolution flows.

Upstream also added in this file:
- `normalizeProviderIdForAuth` (auth-key normalization for provider variants).
- `findNormalizedProviderValue` / `findNormalizedProviderKey` utilities.
- richer `resolveThinkingDefault` (per-model thinking + Claude 4.6 adaptive default).
- `resolveReasoningDefault` helper (used by auto-reply reasoning default path).

## What we have in fork
Current fork `buildAllowedModelSet` includes B9 explicitly:
- `else if (normalizeProviderId(parsed.provider) === normalizeProviderId(params.defaultProvider)) { allowedKeys.add(key) }`
- This is the Anthropic OAuth default-provider fallback when catalog lacks the model and provider config is absent.

Current fork also has:
- provider key/value helpers (`findNormalizedProviderValue` / `findNormalizedProviderKey`).
- no `normalizeProviderIdForAuth` in this file right now.
- no `resolveReasoningDefault` in this file right now.
- `allowedCatalog` built only from bundled catalog (no synthetic entries).

Alias state (B10):
- `src/agents/model-selection.ts` includes `sonnet-4.5` and `sonnet-4.6` normalization.
- `src/config/defaults.ts` in fork includes `DEFAULT_MODEL_ALIASES` entries for `sonnet-4.5` and `sonnet-4.6`.
- upstream `v2026.3.2` `src/config/defaults.ts` does not include those two alias keys.

## Exact conflict
`buildAllowedModelSet` strategies conflict directly:

- Fork strategy (B9): narrow fallback only for `defaultProvider` matches.
- Upstream strategy: trust all explicit allowlist entries + synthesize catalog entries.

If we keep fork implementation, we lose upstream synthetic-catalog behavior and keep extra divergence.
If we take upstream implementation, the B9-specific branch disappears, but B9 behavior is still covered (because explicit allowlist entries are always allowed).

## Key questions answered
1. How did `buildAllowedModelSet` change? Does upstream handle defaultProvider differently?
- Yes. Upstream no longer needs a special `defaultProvider` branch; it accepts all explicit allowlist entries regardless of provider/catalog/provider-config.

2. Do `normalizeProviderIdForAuth` and provider key/value helpers subsume B9?
- `normalizeProviderIdForAuth`: no (auth-profile matching concern, not allowlist gating).
- provider key/value helpers: also no direct B9 replacement.
- B9 is subsumed by upstream’s broader explicit-allowlist trust inside `buildAllowedModelSet`.

3. Do `resolveThinkingDefault` / `resolveReasoningDefault` affect model selection for our users?
- Not for allowlist admission or `/model` key acceptance.
- They affect default thinking/reasoning behavior after model selection (auto-reply/runtime behavior), not whether `/model sonnet` is allowed.

4. Did upstream add logic that handles OAuth-default providers without explicit catalog entries?
- Yes. Explicit allowlist trust + synthetic catalog entries handles this case and more.
- B9 becomes functionally redundant if upstream logic is adopted.

5. Cleanest way to preserve B9 behavior with upstream patterns?
- Adopt upstream `buildAllowedModelSet` as-is.
- Preserve B9 via regression tests (behavioral guard), not by re-adding a fork-only conditional branch.

## Migration path
1. Rebase `src/agents/model-selection.ts` to upstream `v2026.3.2` structure for `buildAllowedModelSet`:
- keep explicit allowlist trust.
- keep synthetic catalog entries.
- do not re-introduce B9 branch unless a concrete failing test proves a gap.

2. Keep B10 aliases in both places for fork invariants:
- `src/agents/model-selection.ts` anthropic alias normalization (`sonnet-4.5`, `sonnet-4.6`).
- `src/config/defaults.ts` `DEFAULT_MODEL_ALIASES` entries for `sonnet-4.5`, `sonnet-4.6`.

3. Port/retain upstream unit coverage that proves catalog-missing allowlist entries are accepted.

## Verification
Run these checks after merge resolution:

1. Grep call sites and implementation:
```bash
rg -n "buildAllowedModelSet" src/agents/model-selection.ts src/auto-reply/reply/model-selection.ts src/auto-reply/reply/commands-models.ts src/commands/agent.ts src/agents/tools/session-status-tool.ts
```

2. Unit test for explicit allowlist trust (catalog miss still allowed):
```bash
pnpm vitest src/agents/model-selection.test.ts -t "keeps explicitly allowlisted models even when missing from bundled catalog"
```

3. Directive behavior regression for B9 (`/model sonnet` with OAuth-default provider and catalog missing sonnet-4-6):
- add/ensure an e2e case in `src/auto-reply/reply.directive.directive-behavior.lists-allowlisted-models-model-list.e2e.test.ts` with:
  - default provider anthropic,
  - allowlist contains `anthropic/claude-sonnet-4-6` (alias `sonnet`),
  - mocked catalog lacks `claude-sonnet-4-6`,
  - command `/model sonnet` succeeds and stores `provider=anthropic`, `model=claude-sonnet-4-6`.

Example run:
```bash
pnpm vitest src/auto-reply/reply.directive.directive-behavior.lists-allowlisted-models-model-list.e2e.test.ts -t "supports sonnet alias when catalog lacks sonnet-4-6"
```

## Blockers / notes
- Local ref `upstream/v2026.3.2` is not present in this checkout; used tag `v2026.3.2` for equivalent upstream snapshot.
- Current fork lacks a direct `/model sonnet` regression test for the B9 scenario; adding that test is required to lock behavior.
