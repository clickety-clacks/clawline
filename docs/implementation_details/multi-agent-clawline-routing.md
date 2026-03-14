# Multi-Agent Clawline Routing Investigation — Non-Obvious Details

## iOS hardcodes `agent:main` in multiple places — exact locations
These are the production code hardcodes that must be generalized before arbitrary agent IDs work:
- `SessionKey.admin = "agent:main:main"` — hardcoded literal
- `SessionKey.clawlineDMPrefix = "agent:main:clawline:"` — hardcoded prefix
- `SessionKey.clawlineMain(userId:)` constructs `"agent:main:clawline:\(userId):main"`
- `SessionKey.isClawlinePersonalDM` requires `parts[1] == "main"` — hardcoded check

These gate UI/rendering behavior in `ChatViewModel` at lines 749, 757, 1933, 2082-2083 and in `MessagePresentation.swift` at line 283. Reading the routing code alone doesn't reveal that these UI checks depend on the hardcoded agent ID.

## Provider parses session keys but still binds routing to `mainSessionAgentId`
Clawline key parsing (`parseClawlineUserSessionKey`) correctly accepts any agent ID in `parts[1]`. But the runtime routes reply identity/delays via `mainSessionAgentId` (a config-time constant), not by the actual parsed agent ID from `resolvedSessionKey`. This means: stream creation/naming logic accepts arbitrary agent IDs, but reply behavior and transcript path are always pinned to the main agent. The two behaviors look consistent in code but diverge in practice with non-main agents.

## Changing stream agent ID prefix creates orphaned data without migration
Changing the agent ID prefix in stream keys creates new keys; old keys remain in SQLite (`stream_sessions`, `events`) and `sessions.json` until pruned. Old messages continue routing to old-prefixed keys unless data is rewritten. If you change agent IDs in-place without migration, you get split history (some messages on old key, new messages on new key).

## iOS local caches use sessionKey-derived defaults keys — prefix changes fork cache entries
iOS stores per-session state under sessionKey-derived defaults/cache keys. A prefix change naturally forks the cache: old entries become stale but harmless. No schema migration needed — old entries are orphaned, not conflicting.

## Provider `normalizeStoredSessionKey` means storage is NOT fully opaque
Incoming session keys are normalized/canonicalized before persistence (`normalizeStoredSessionKey` in server.ts:1392). Ingestion is not opaque — the provider parses and may modify keys on write. Code that expects raw pass-through of session keys will be surprised by this normalization.
