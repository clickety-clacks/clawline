# T121 Multi-Agent Clawline Routing Investigation

Date: 2026-03-03

Scope: provider TypeScript in `/Users/mike/src/clawdbot` + iOS client Swift in `/Users/mike/src/clawline`.

Verdict: **GAPS** for true arbitrary-agent operation across provider+iOS. Provider is mostly agent-id aware, but iOS still hardcodes `agent:main`, and provider currently ties generated stream keys to a single configured agent id.

## 1) Where `agentId` / `sessionKey` parsing assumes `agent:main` (if anywhere)

### Provider (TypeScript)
- Hardcoded default exists for global main session key:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1211` (`options.mainSessionKey?.trim() || "agent:main:main"`).
- Agent-id fallback defaults to `main` in shared routing/session helpers:
  - `/Users/mike/src/clawdbot/src/routing/session-key.ts:13` (`DEFAULT_AGENT_ID = "main"`).
  - `/Users/mike/src/clawdbot/src/routing/session-key.ts:60-63` (`resolveAgentIdFromSessionKey` falls back to `DEFAULT_AGENT_ID`).
- Clawline-specific key parsing itself is **not** hardcoded to `main`; it accepts any `agent:<id>:clawline:<user>:<suffix>`:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:610-629` (`parseClawlineUserSessionKey`).
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:644-668` (`isClawlinePersonalUserStreamSessionKey` allows any `parts[1]` agent id, validates suffix/user).

### iOS client (Swift)
Hardcoded `agent:main` assumptions are present in production code:
- `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11` (`admin = "agent:main:main"`).
- `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:12` (`clawlineDMPrefix = "agent:main:clawline:"`).
- `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:19` (`clawlineMain` constructs `agent:main:clawline:<user>:main`).
- `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:28` (`isClawlinePersonalDM` requires `parts[1] == "main"`).
- Those helpers gate behavior in UI/message rendering:
  - `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:749,757,1933,2082-2083`.
  - `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/MessagePresentation.swift:283`.

## 2) Does storage treat session keys as opaque?

### Provider stream storage (SQLite)
- Storage schema uses `sessionKey TEXT` and key-based lookups/deletes:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1687-1697` (`stream_sessions`, PK `(userId, sessionKey)`).
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:2085-2115` (select/insert/update/delete by `sessionKey`).
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:2311-2314` (delete message/event rows by `events.sessionKey`).
- But ingestion/normalization is **not fully opaque**: provider parses and canonicalizes keys before persistence:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1392-1438` (`normalizeStoredSessionKey`).
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:2288-2302` (`insertEventTx` normalizes `event.sessionKey`).
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1924-1964` (backfill migration normalizes `events.sessionKey`).

### Provider session history store (`sessions.json`)
- Session store is keyed directly by `sessionKey` string (dictionary key), no structured parsing for storage keying:
  - `/Users/mike/src/clawdbot/src/config/sessions/store.ts:837,851` (`store[sessionKey] = ...`).
  - `/Users/mike/src/clawdbot/src/config/sessions/store.ts:872,930` (`updateLastRoute` reads/writes `store[sessionKey]`).
- Clawline activity recording also writes by raw `sessionKey` key:
  - `/Users/mike/src/clawdbot/src/clawline/session-store.ts:39,59`.

### iOS local storage
- Session keys are mostly treated as opaque identifiers for routing and local cache keys:
  - Provider events pass through key untouched: `/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:668-678`.
  - Session key lists are normalized only by trim/dedupe, not parsed by format: `/Users/mike/src/clawline/ios/Clawline/Clawline/Services/ProviderChatService.swift:691-703`.
  - Stream mutation APIs use percent-encoded path component from raw key: `/Users/mike/src/clawline/ios/Clawline/Clawline/Services/StreamAPIClient.swift:98-117,164-166`.
  - Local defaults/cache keys include raw `sessionKey`: `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1686-1703,1761-1772`.

## 3) Exact code changes needed for arbitrary agent IDs

### Provider (`/Users/mike/src/clawdbot`) changes
1. Remove/avoid hardcoded fallback `"agent:main:main"` in Clawline server init.
- File: `/Users/mike/src/clawdbot/src/clawline/server.ts:1211`.
- Change: require `mainSessionKey` from service/config or derive via `resolveMainSessionKey`; avoid literal fallback.

2. Decide if stream-agent id should be independent from global main session key.
- Current behavior: all generated/seeded stream keys use one derived `mainSessionAgentId` (`buildSessionInfo`, seed/default, create stream):
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:1232,1234,1510,1520,1569,1606,1613,4057-4061`.
- If requirement is “streams may be on arbitrary/non-default agent”, add an explicit `streamAgentId` and replace these call sites to use that id.

3. Route reply identity/config by actual stream agent (from `resolvedSessionKey`) instead of fixed `mainSessionAgentId`.
- Current route object pins `agentId: mainSessionAgentId`:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:4993-4995,5390-5392`.
- That `route.agentId` drives model identity/delay config:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:5071-5075,5468-5472`.
- Change: parse `resolvedSessionKey` (`parseClawlineUserSessionKey`) and use parsed `agentId` when present.

4. Sync session transcript path by session key’s agent id, not fixed `mainSessionAgentId`.
- Current connect-time sync writes `sessionFile` with `resolveSessionTranscriptPath(..., mainSessionAgentId)`:
  - `/Users/mike/src/clawdbot/src/clawline/server.ts:4826-4831`.
- Change: derive agent id from `session.sessionKey` (or omit explicit `sessionFile` and let `recordClawlineSessionActivity` compute canonically).

### iOS (`/Users/mike/src/clawline`) changes
1. Generalize `SessionKey` helpers to accept any agent id.
- File: `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift:11-12,19,28`.
- Change: remove `agent:main` literals; parse/validate `agent:<any>:clawline:<user>:<suffix>`.

2. Remove `agent:main`-constructed fallback for main stream selection.
- File: `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1931-1934`.
- Change: prefer server-provisioned `kind == "main"` session key; avoid constructing a hardcoded agent key.

3. Update UI guards that rely on hardcoded main-agent checks.
- Files:
  - `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:749,757,2082-2083`
  - `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/MessagePresentation.swift:283`
- Change: use generalized personal-stream predicate (any agent id) or rely on `stream.kind` for built-ins.

## 4) Migration / compatibility impact on existing SQLite stream records and session history

### SQLite stream/event records (`clawline.sqlite`)
- Existing records remain valid strings; no schema migration is required just to allow a different agent id prefix:
  - schema/versioning: `/Users/mike/src/clawdbot/src/clawline/server.ts:222,1677,1974`.
- However, changing stream agent id creates compatibility side effects:
  - Built-in provisioning inserts/updates expected keys but does not remove old-key built-ins:
    - `/Users/mike/src/clawdbot/src/clawline/server.ts:1600-1666` (insert/update loop only).
  - Replay reads `payloadJson` (not `events.sessionKey`) and reuses event `sessionKey` from payload after normalization:
    - selects: `/Users/mike/src/clawdbot/src/clawline/server.ts:2259-2269`
    - replay parse path: `/Users/mike/src/clawdbot/src/clawline/server.ts:4339-4344`
  - So old messages can continue to route to old-prefixed session keys unless data is rewritten.

### Session history store (`sessions.json`)
- Session entries are keyed by raw `sessionKey`; changing prefix creates new keys, old keys remain until pruned:
  - `/Users/mike/src/clawdbot/src/config/sessions/store.ts:837,851,872,930`.

### iOS local caches/state
- No client SQLite stream DB found in iOS app code (`rg` found none under `ios/Clawline/Clawline`).
- iOS stores per-session state under sessionKey-derived defaults/cache keys; prefix changes naturally fork cache entries (old entries become stale/orphaned until cleanup):
  - `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift:1686-1703,1761-1772,2111-2163`.

### Migration requirement summary
- **Required migrations:** none for schema compatibility.
- **Data migration recommended if you want continuity under new agent-id keys (no duplicates/splits):**
  1) Rewrite `stream_sessions.sessionKey` from old prefix to new prefix.
  2) Rewrite `events.sessionKey` and message payload `sessionKey` inside `events.payloadJson` so replay and stream delete semantics stay aligned.
  3) Optionally rewrite `sessions.json` keys (`store[sessionKey]`) to keep last-route/session-history continuity on new keys.

## Phase Plan (Implementation-Ready)

Checkpoint status: **GAPS (final for investigation)**.

### Phase 1 - Provider key-source hardening
Execution order:
1. Remove literal fallback and always source canonical main session key from config/service.
2. Keep Clawline stream key parsing/building agent-id aware as-is.

Per-file checklist:
- [ ] `/Users/mike/src/clawdbot/src/clawline/server.ts`
  - Replace `"agent:main:main"` fallback at `:1211` with required/config-derived key.
- [ ] `/Users/mike/src/clawdbot/src/clawline/service.ts`
  - Confirm `resolveMainSessionKey(...)`/`resolveAgentIdFromSessionKey(...)` feed provider init (`:29-40`).

Validation tests:
- [ ] Provider unit: start server with non-main main session key (for example `agent:streams:main`) and verify auth/session provisioning still works.
- [ ] Add/extend tests in `/Users/mike/src/clawdbot/src/clawline/server.test.ts` for non-main `mainSessionKey` boot behavior.

### Phase 2 - Provider routing semantics for arbitrary stream agent IDs
Execution order:
1. Decide source of stream agent id (`mainSessionAgentId` vs explicit `streamAgentId`).
2. Make routing/identity/transcript paths use session-key agent id where required.

Per-file checklist:
- [ ] `/Users/mike/src/clawdbot/src/clawline/server.ts`
  - Update stream key generation call sites (`:1232,1234,1510,1520,1569,1606,1613,4057-4061`).
  - Route reply identity by resolved stream agent instead of fixed `mainSessionAgentId` (`:4993-4995,5071-5075,5390-5392,5468-5472`).
  - Ensure transcript/session-file sync uses session-key agent (`:4826-4831`).

Validation tests:
- [ ] Provider unit/integration in `/Users/mike/src/clawdbot/src/clawline/server.test.ts`:
  - Create/rename/delete custom stream where key prefix is non-main agent.
  - Inbound message with `payload.sessionKey = agent:streams:clawline:<user>:s_xxx` dispatches under `streams` identity.
  - Replay still returns messages scoped to expected stream keys.

### Phase 3 - iOS de-hardcode `agent:main`
Execution order:
1. Generalize `SessionKey` parser/builders.
2. Replace hardcoded fallback main key construction with server-provisioned stream selection.
3. Update stream protections and terminal gating predicates.

Per-file checklist:
- [ ] `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/SessionKey.swift`
  - Remove `agent:main` literals (`:11-12,19,28`) and support `agent:<any>`.
- [ ] `/Users/mike/src/clawline/ios/Clawline/Clawline/ViewModels/ChatViewModel.swift`
  - Remove hardcoded constructed fallback (`:1931-1934`) and align guards (`:749,757,2082-2083`).
- [ ] `/Users/mike/src/clawline/ios/Clawline/Clawline/Models/MessagePresentation.swift`
  - Keep terminal gating aligned with generalized personal-stream predicate (`:283`).

Validation tests:
- [ ] iOS unit tests in `/Users/mike/src/clawline/ios/Clawline/ClawlineTests/ChatViewModelTests.swift` and `/Users/mike/src/clawline/ios/Clawline/ClawlineTests/ProviderServiceTests.swift`:
  - Session keys with `agent:streams` are accepted/routed.
  - Built-in stream rename/delete protections still apply by kind/predicate.

### Phase 4 - Migration and compatibility pass
Execution order:
1. Ship without schema migration.
2. Optionally provide one-time data rewrite for continuity if agent-id prefix changes in-place.

Per-file checklist:
- [ ] `/Users/mike/src/clawdbot/src/clawline/server.ts`
  - If continuity required, add targeted rewrite path for old->new prefixes in `stream_sessions`, `events.sessionKey`, and `events.payloadJson.sessionKey`.
- [ ] `/Users/mike/src/clawdbot/src/config/sessions/store.ts`
  - Optional utility to rewrite `sessions.json` keys to new prefix.

Validation tests:
- [ ] Migration dry-run checks (SQLite): count rows by old/new prefix before and after rewrite.
- [ ] Replay and stream-delete regression checks on migrated data.
- [ ] iOS local cache sanity: old keys remain harmless; new keys populate fresh state.
