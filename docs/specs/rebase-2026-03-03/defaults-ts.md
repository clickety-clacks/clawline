# defaults.ts migration spec (rebase to v2026.3.2)

## Scope
- Collision zone: `src/config/defaults.ts`
- Upstream target: `v2026.3.2` (`85377a281756`)
- Fork invariant to preserve: **B10** (`sonnet-4.5` and `sonnet-4.6` aliases must resolve)

## Upstream changes (aba15763b -> v2026.3.2)
Upstream rewrote significant parts of `defaults.ts` (about +101 lines) and introduced new defaulting patterns:

1. Talk config defaulting is now normalized/provider-aware.
- `applyTalkApiKey` now starts with `normalizeTalkConfig(config)`.
- It inspects the active provider via `resolveActiveTalkProviderConfig`.
- It only auto-injects resolved `ELEVENLABS_API_KEY` when the active provider is the default talk provider (`elevenlabs`) or unset.
- It uses `hasConfiguredSecretInput(...)` before writing defaults, so explicit `SecretRef` or string credentials are treated as configured and are not overwritten.
- It writes both provider-scoped key (`talk.providers[provider].apiKey`) and legacy compatibility key (`talk.apiKey`), and ensures `talk.provider` is set.

2. New explicit normalization hook.
- Added `applyTalkConfigNormalization(config)` that returns `normalizeTalkConfig(config)`.
- Upstream pattern is to normalize talk shape in config read paths, even when no API key is injected.

3. Model defaulting now infers provider/model API mode.
- Added `resolveDefaultProviderApi(...)`.
- In `applyModelDefaults`, if provider is anthropic and `provider.api` is missing, default to `"anthropic-messages"`.
- Model entries inherit `api` from provider when missing.
- This reduces implicit-mode drift between provider-level and model-level config.

4. Alias table update.
- Upstream changed `sonnet` alias target to `anthropic/claude-sonnet-4-6`.
- Alias pattern remains inline in `DEFAULT_MODEL_ALIASES` (no new registry abstraction).

5. Context-pruning defaulting adjustments.
- Primary model lookup now uses `resolveAgentModelPrimaryValue(defaults.model)` instead of reading only `defaults.model?.primary`.
- Bedrock Anthropic models are now included in cacheRetention defaulting via an explicit type guard.

## Fork-side behavior in this zone
Fork added/kept these aliases in `DEFAULT_MODEL_ALIASES`:
- `sonnet -> anthropic/claude-sonnet-4-6`
- `sonnet-4.5 -> anthropic/claude-sonnet-4-5`
- `sonnet-4.6 -> anthropic/claude-sonnet-4-6`

Required behavior: `sonnet-4.5` and `sonnet-4.6` aliases must survive regardless of upstream handling of `sonnet`.

## Conflict analysis
Primary conflict is in the alias map section plus broad file drift:
- Upstream and fork both changed `sonnet`.
- Upstream added major defaulting logic (talk normalization + SecretRef-aware checks + inferred model API propagation).

Risk if merged incorrectly:
- Silent config drift (talk API keys unexpectedly overwritten or not written where expected).
- Model/provider API mismatch for anthropic defaults.
- Alias regression impacting model resolution for OAuth users (especially when users reference shorthand aliases).

## Migration path (upstream-first, minimal divergence)
1. Use upstream `v2026.3.2` `src/config/defaults.ts` as baseline.
2. Keep upstream `sonnet` alias value as-is (`anthropic/claude-sonnet-4-6`).
3. Add only the two fork-required explicit aliases into the same upstream `DEFAULT_MODEL_ALIASES` object:
- `sonnet-4.5: "anthropic/claude-sonnet-4-5"`
- `sonnet-4.6: "anthropic/claude-sonnet-4-6"`
4. Do not fork upstream logic in:
- `applyTalkApiKey`
- `applyTalkConfigNormalization`
- `applyModelDefaults` inferred `api` behavior
- SecretRef-aware checks (`hasConfiguredSecretInput`)
5. Keep the upstream import/export shape intact so downstream call sites can adopt/retain upstream normalization flow.

This preserves B10 while minimizing divergence and adopting upstream patterns.

## SecretRef-aware path impact on our aliases
- `hasConfiguredSecretInput` affects talk credential defaulting only.
- It does **not** alter model alias resolution directly.
- Keeping this upstream logic is still mandatory, because incorrect handling here can cause silent defaults mutation in `talk`, which is high-risk and unrelated to alias needs.

## Post-merge verification
1. Diff expectation (scope discipline):
- `src/config/defaults.ts` should match upstream except the two explicit alias entries (`sonnet-4.5`, `sonnet-4.6`) if upstream still lacks them.

2. Alias checks:
- Validate that `DEFAULT_MODEL_ALIASES` contains:
  - `sonnet -> anthropic/claude-sonnet-4-6` (upstream value)
  - `sonnet-4.5 -> anthropic/claude-sonnet-4-5`
  - `sonnet-4.6 -> anthropic/claude-sonnet-4-6`

3. Model defaulting checks:
- Run `src/config/model-alias-defaults.test.ts` to ensure alias injection behavior still works.
- Ensure anthropic provider/model `api` inference tests pass (upstream-added expectations).

4. Talk defaulting checks:
- Verify config read/write paths still compile and use upstream talk-normalization-aware defaults flow.
- Manual sanity: a config with talk `apiKey` as a `SecretRef` must not be overwritten by `applyTalkApiKey`.

5. OAuth model-resolution sanity (B9/B10 safety):
- Confirm shorthand `sonnet`, `sonnet-4.5`, and `sonnet-4.6` resolve correctly in agent defaults/model selection paths used by OAuth users.

## Redundancy rule
If upstream later includes explicit `sonnet-4.6` alias key (not just `sonnet -> ...4-6`), our `sonnet-4.6` addition becomes redundant and should be dropped to minimize divergence.

As of `v2026.3.2`, upstream does **not** include explicit `sonnet-4.5` or `sonnet-4.6` keys, so both should remain fork-specific.

## Blockers
- No architectural blocker in this zone.
- Repository ref note: local ref `upstream/v2026.3.2` is absent in this checkout; this spec used tag `v2026.3.2` at commit `85377a281756`, which is the same target commit from context.
