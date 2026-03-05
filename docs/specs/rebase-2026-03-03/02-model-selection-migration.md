# model-selection.ts Migration Spec (Collision Zone)

## Scope
- File: `src/agents/model-selection.ts`
- Collision focus: `buildAllowedModelSet` and closely related model-resolution helpers affected by upstream `v2026.3.2`.
- This spec defines merge behavior only. No implementation is performed here.

## Goal
Preserve fork invariants for Anthropic OAuth users while minimizing divergence by adopting upstream `v2026.3.2` patterns wherever behavior is equivalent or better.

## Required Invariants
1. `/model sonnet` works for OAuth users without explicit `models.providers.anthropic` config.
2. `/model claude-sonnet-4-6` works for OAuth users without explicit `models.providers.anthropic` config.
3. Aliases resolve as:
   - `sonnet` -> `anthropic/claude-sonnet-4-6`
   - `sonnet-4.5` -> `anthropic/claude-sonnet-4-5`
   - `sonnet-4.6` -> `anthropic/claude-sonnet-4-6`

## Upstream Delta Summary (v2026.3.2)

### 1) Provider normalization/auth helpers
- Added broader provider normalization in `normalizeProviderId` (for example Bedrock and legacy provider aliases).
- Added `normalizeProviderIdForAuth` for auth-profile key matching.
- Added/expanded normalized provider key/value lookup helpers used by auth/profile flows.

### 2) Model ref parsing/selection helpers
- `resolveModelRefFromString` now strips trailing auth profile suffixes via `splitTrailingAuthProfile` before alias/ref resolution.
- Added `inferUniqueProviderFromConfiguredModels` for provider inference when model IDs are ambiguous.
- Added `resolveSubagentConfiguredModelSelection`, `resolveSubagentSpawnModelSelection`, and moved/shared `normalizeModelSelection` usage with newer model input handling.

### 3) `buildAllowedModelSet` behavior changed materially
Upstream moved from conditional allowlisting to explicit-allowlist trust:
- Old gated behavior (fork/current pre-merge lineage): allow only if CLI provider, in catalog, provider configured, or default-provider equality branch.
- New upstream behavior: every explicit allowlist ref is trusted directly.
- If an allowlisted ref is missing from bundled catalog, upstream synthesizes a catalog entry (`id/name/provider`) so it remains selectable/visible.

### 4) Defaults behavior expanded
- `resolveThinkingDefault` now supports per-model `params.thinking` override and adaptive default for Claude 4.6 family.
- Added `resolveReasoningDefault` helper.

## OAuth Coverage Analysis (Is fork patch still needed?)

### Fork patch intent
Fork added a `defaultProvider` equality branch in `buildAllowedModelSet` so Anthropic OAuth users could select allowlisted Anthropic models even when:
- model was missing from bundled catalog, and
- `models.providers.anthropic` was not configured.

### Upstream native behavior check
Upstream `buildAllowedModelSet` now unconditionally adds all explicit allowlist refs to `allowedKeys`, independent of catalog presence and provider config. This is stricter coverage than the fork branch and directly satisfies the OAuth use case.

Conclusion: **fork `defaultProvider` equality branch is redundant under upstream v2026.3.2 semantics and should not be re-applied by default.**

## Merge Decision for Collision Zone
1. Adopt upstream `buildAllowedModelSet` semantics as-is (explicit allowlist trust + synthetic catalog entries).
2. Do not carry forward the fork-only `defaultProvider` equality branch unless regression evidence appears post-merge.
3. Preserve upstream helper additions in this file (`normalizeProviderIdForAuth`, new selection helpers, reasoning/thinking defaults).

## Conditional Fallback (only if regression is proven)
If post-merge verification proves an OAuth regression not covered by upstream explicit-allowlist trust, reintroduce a minimal branch inside `buildAllowedModelSet` **in the raw allowlist loop**, immediately after parsing `key` and before loop end, to allow parsed refs where:
- `normalizeProviderId(parsed.provider) === normalizeProviderId(params.defaultProvider)`.

Note: this fallback should be applied only if an identified failing case cannot be resolved by keeping upstream semantics intact; otherwise avoid divergence.

## Alias Integration Plan
1. Keep upstream `ANTHROPIC_MODEL_ALIASES` entries for:
   - `sonnet-4.5` -> `claude-sonnet-4-5`
   - `sonnet-4.6` -> `claude-sonnet-4-6`
2. Ensure `sonnet` alias remains available through configured/default alias mapping (`agents.defaults.models` alias entry pointing at `anthropic/claude-sonnet-4-6`; currently sourced from defaults logic outside this collision zone).
3. Do not add ad-hoc alias logic in `model-selection.ts`; use upstream alias and allowlist pipelines.

## Post-Merge Verification

### Automated checks (required)
1. Run targeted tests for model-selection behaviors:
   - `pnpm vitest src/agents/model-selection.test.ts`
2. Ensure coverage includes/retains:
   - explicit allowlist model absent from bundled catalog is still allowed;
   - `resolveAllowedModelRef` accepts allowlisted refs absent from catalog;
   - parse normalization for `sonnet-4.5` and `sonnet-4.6`.

### Regression tests to confirm invariants
1. Add or verify a case with no `models.providers.anthropic`, allowlist containing `anthropic/claude-sonnet-4-6`, and catalog missing that model: expected allowed.
2. Add or verify `/model` resolution behavior for:
   - `sonnet`
   - `sonnet-4.5`
   - `sonnet-4.6`
   - `claude-sonnet-4-6`

### Manual smoke (if CLI harness available)
1. OAuth-style config (Anthropic auth profile, no `models.providers.anthropic`) with allowlisted Sonnet.
2. Execute model selection flow and confirm no silent rejection and expected active model key.

## Divergence Justification
No new fork-specific hook is justified in this zone if upstream explicit-allowlist trust passes verification. Keeping upstream reduces divergence and directly preserves required behavior.
