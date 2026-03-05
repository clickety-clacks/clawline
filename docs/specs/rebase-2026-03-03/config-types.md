# Migration Spec: Config Type System Shift (SecretRef + Modular Typing)

## Scope
Collision zone:
- `src/config/types.ts`
- `src/config/zod-schema.core.ts`
- Clawline config surfaces:
  - `src/clawline/config.ts`
  - `extensions/clawline/src/config-schema.ts`

Target upstream: `upstream/v2026.3.2` (`85377a28175695c224f6589eb5c1460841ecd65c`)

## Context/Invariant Fit
This zone is governed by the rebase philosophy in `~/.openclaw/workspace/clawline-rebase-spec-context.md`:
- minimize divergence
- prefer upstream patterns
- preserve behavior, not old implementation
- no invented core hooks

Relevant behavior invariants impacted here:
- B13 (plugin-sdk exports) is adjacent but not directly in this file set.
- Clawline auth/session behavior must remain unchanged while config typing migrates.

## Evidence Collected
Commands requested and run:
- `git diff aba15763b upstream/v2026.3.2 -- src/config/types.ts`
- `git diff aba15763b upstream/v2026.3.2 -- src/config/zod-schema.core.ts`
- `cat src/clawline/config.ts`
- `cat extensions/clawline/src/config-schema.ts`
- `git show upstream/v2026.3.2:src/config/types.clawline.ts 2>/dev/null || echo "NOT PRESENT IN UPSTREAM"`

Additional provenance checks run:
- `git show --no-patch --pretty=fuller aba15763b`
- `git merge-base --is-ancestor aba15763b upstream/v2026.3.2` => `1` (false)
- `git log --diff-filter=A --oneline -- src/config/types.clawline.ts`

## Upstream Changes (in this zone)

### 1. `src/config/types.ts` moved to modular exports
Upstream added exports:
- `types.acp.ts`
- `types.cli.ts`
- `types.secrets.ts`

Upstream removed export line:
- `types.clawline.ts`

### 2. SecretRef/SecretInput introduced in core schema
Upstream `src/config/zod-schema.core.ts` added:
- `SecretRefSchema`
- `SecretInputSchema`
- `SecretsConfigSchema`
- source-specific secret id validation rules

And migrated many credential fields from plain string to `SecretInputSchema`.

## Critical Provenance Clarification (requested)

### Did upstream have `types.clawline.ts` and drop it, or did we add it?
**Answer: in practical rebase terms, this is a fork addition and not present in target upstream.**

Concrete facts:
- `git show upstream/v2026.3.2:src/config/types.clawline.ts` => `NOT PRESENT IN UPSTREAM`
- `git log --oneline upstream/v2026.3.2 -- src/config/types.clawline.ts` => no commits
- `aba15763b` is **not** an ancestor of upstream tag (`merge-base --is-ancestor` returned false)
- `aba15763b` is a fork merge commit (`Merge origin/main into upstream-merge-2026-02-14`)

Implication:
- Seeing `types.clawline.ts` in `aba15763b` does **not** prove upstream had it.
- Migration should treat core `types.clawline.ts` wiring as fork-side divergence to remove.

## Current Fork State (Clawline config)

### What Clawline currently imports from `src/config/`
- `src/clawline/config.ts`: `import type { OpenClawConfig } from "../config/config.js"`
- `src/clawline/domain.ts`: same `OpenClawConfig` type import
- `extensions/clawline/src/config-schema.ts`: no direct import from `src/config/*`

These imports remain valid under upstream modular typing because `OpenClawConfig` remains exported from `src/config/config.ts`.

### Current credential typing in Clawline schema
`extensions/clawline/src/config-schema.ts`:
- `auth.jwtSigningKey: z.string().nullable().optional()`

So Clawline JWT key is currently plaintext-only in schema.

### Current plugin registration pattern
`extensions/clawline/src/channel.ts` already uses upstream pattern:
- `configSchema: buildChannelConfigSchema(ClawlineConfigSchema)`

No alternate registration mechanism is required by modular type split.

## Conflict Summary
1. Core type aggregation diverges from upstream (`types.clawline.ts` still exported in fork).
2. Clawline credential schema has not adopted SecretInput/SecretRef support.
3. Need to migrate without changing Clawline runtime auth behavior.

## Migration Path

### Step 1: Align core type exports to upstream modular structure
- Adopt upstream `src/config/types.ts` export list.
- Remove `export * from "./types.clawline.js"` from core aggregator.
- Add upstream modules (`types.acp.ts`, `types.cli.ts`, `types.secrets.ts`) per upstream.

### Step 2: Remove core static Clawline channel typing linkage
- Align `src/config/types.channels.ts` with upstream dynamic extension-channel pattern.
- Do not keep `channels.clawline?: ClawlineConfig` in core types.
- Keep Clawline-specific typing local to Clawline extension/runtime files.

### Step 3: Make Clawline JWT key SecretRef-aware
Adopt upstream credential pattern for Clawline secret fields:
- `channels.clawline.auth.jwtSigningKey` should accept SecretInput shape (`string | SecretRef`) plus `null`.

Recommended implementation shape (matching upstream extension style):
- add extension-local helper `secret-input.ts` for schema + normalization exports
- change `extensions/clawline/src/config-schema.ts` `jwtSigningKey` field to SecretInput-capable schema

### Step 4: Ensure runtime receives resolved string before JWT usage
`ensureJwtKey(...)` in `src/clawline/server.ts` expects `string | null`.
If SecretRef is accepted at schema level, runtime must resolve or fail clearly before `ensureJwtKey` call.

Adopt upstream secrets-runtime flow where available; otherwise block/defer SecretRef support for this field until resolver path is present.

### Step 5: No registration rewrite needed
Clawline already registers config schema through plugin channel API; modular typing does not require changing registration flow.

## Verification
1. Core parity:
- `git diff upstream/v2026.3.2 -- src/config/types.ts`
- `grep -n "types.clawline" src/config/types.ts` => no result

2. Provenance sanity:
- `git show upstream/v2026.3.2:src/config/types.clawline.ts` fails/not present

3. Clawline import stability:
- `rg -n "from \"\.\./config/config\.js\"" src/clawline/config.ts src/clawline/domain.ts`
- Typecheck/build confirms imports still valid.

4. SecretInput behavior for Clawline JWT key:
- accepts plaintext string
- accepts valid SecretRef object
- accepts null
- rejects invalid SecretRef payload

5. Runtime behavior:
- existing plaintext/null configs still work
- unresolved SecretRef fails with explicit resolution error (no silent fallback)

## Blockers / Risks
1. Secret resolver dependency:
- If secrets runtime collector/resolution is not landed in this rebase phase, do not half-adopt SecretRef in schema only.

2. Scope-control risk:
- Avoid touching unrelated gateway/auth policy (for example `gateway.auth.token` semantics) in this collision.

3. Misleading diff-base risk:
- Because `aba15763b` is fork-side, not upstream ancestor, do not infer upstream provenance from that commit alone.

