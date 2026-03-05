# Migration Spec: Clawline and `channelRuntime` Injection (v2026.3.2)

## Goal
Adopt upstream `channelRuntime` injection pattern from `aba15763b..v2026.3.2` while preserving Clawline invariants (especially **B2**, **B3**, **B8**) and minimizing fork divergence.

## Non-Goals
- Re-architecting Clawline provider/service ownership in this collision fix.
- Changing B2/B3/B8 behavior semantics.
- Introducing new fork-only core hooks beyond what upstream already added.

## Upstream Change Summary

### 1) `src/channels/plugins/types.adapters.ts`
Upstream adds `channelRuntime?: PluginRuntime["channel"]` to `ChannelGatewayContext`.

Other interface changes in the same file (must be taken with upstream merge shape):
- `ChannelSetupAdapter.resolveAccountId` now accepts optional `input?: ChannelSetupInput`.
- `ChannelSetupAdapter.resolveBindingAccountId` added.
- `ChannelConfigAdapter.resolveAllowFrom` now allows `Array<string | number>`.
- `ChannelConfigAdapter.resolveDefaultTo` added.
- `ChannelOutboundContext.mediaLocalRoots?: readonly string[]` added.
- `ChannelDirectoryAdapter` parameter aliases introduced (typing cleanup).

### 2) `src/gateway/server-channels.ts`
Upstream adds optional `channelRuntime?: PluginRuntime["channel"]` to `ChannelManagerOptions` and passes it into `startAccount` context when provided.

### 3) `src/gateway/server.impl.ts`
Upstream now passes `channelRuntime: createPluginRuntime().channel` into `createChannelManager(...)`.

## New Pattern
External channel plugins should prefer runtime-injected helpers via `ctx.channelRuntime` (when inside `gateway.startAccount`) instead of importing internal core modules.

Type in upstream:
- `ChannelGatewayContext.channelRuntime?: PluginRuntime["channel"]`
- **Optional**, not required.

## `channelRuntime` Full Surface (`PluginRuntime["channel"]`)
From `src/plugins/runtime/types.ts`, runtime namespaces are:
- `text`: `chunkByNewline`, `chunkMarkdownText`, `chunkMarkdownTextWithMode`, `chunkText`, `chunkTextWithMode`, `resolveChunkMode`, `resolveTextChunkLimit`, `hasControlCommand`, `resolveMarkdownTableMode`, `convertMarkdownTables`
- `reply`: `dispatchReplyWithBufferedBlockDispatcher`, `createReplyDispatcherWithTyping`, `resolveEffectiveMessagesConfig`, `resolveHumanDelayConfig`, `dispatchReplyFromConfig`, `finalizeInboundContext`, `formatAgentEnvelope`, `formatInboundEnvelope`, `resolveEnvelopeFormatOptions`
- `routing`: `resolveAgentRoute`
- `pairing`: `buildPairingReply`, `readAllowFromStore`, `upsertPairingRequest`
- `media`: `fetchRemoteMedia`, `saveMediaBuffer`
- `activity`: `record`, `get`
- `session`: `resolveStorePath`, `readSessionUpdatedAt`, `recordSessionMetaFromInbound`, `recordInboundSession`, `updateLastRoute`
- `mentions`: `buildMentionRegexes`, `matchesMentionPatterns`, `matchesMentionWithExplicit`
- `reactions`: `shouldAckReaction`, `removeAckReactionAfterReply`
- `groups`: `resolveGroupPolicy`, `resolveRequireMention`
- `debounce`: `createInboundDebouncer`, `resolveInboundDebounceMs`
- `commands`: `resolveCommandAuthorizedFromAuthorizers`, `isControlCommandMessage`, `shouldComputeCommandAuthorized`, `shouldHandleTextCommands`
- Channel-specific helper groups also exist: `discord`, `slack`, `telegram`, `signal`, `imessage`, `whatsapp`, `line`

## Clawline Current State

### Extension import scan result
Command used:
- `grep -rn "from.*src/\|from.*openclaw/(?!plugin-sdk)" extensions/clawline/src/ extensions/clawline/index.ts 2>/dev/null | head -30`

Result: no non-`plugin-sdk` OpenClaw imports in Clawline extension code. Current imports are plugin-sdk + local files.

### `extensions/clawline/src/channel.ts`
- No `gateway.startAccount` implementation.
- Clawline lifecycle runs through plugin service (`extensions/clawline/index.ts -> startClawlineService(...)`).
- Therefore `ChannelGatewayContext` is currently not used by Clawline, so `channelRuntime` is not reachable there today.

### Where B2/B3/B8 live today
- B2 session routing, B3 `/alert`, and most B8 auth behavior are implemented in `src/clawline/server.ts` (core Clawline service), not in channel gateway adapter code.
- `src/clawline/server.ts` currently imports internal helpers directly (example candidates):
  - `resolveEffectiveMessagesConfig`, `resolveHumanDelayConfig`
  - `dispatchReplyFromConfig`, `finalizeInboundContext`, `createReplyDispatcherWithTyping`
  - `recordInboundSession`

## Key Answers

### What is `channelRuntime` type? Optional or required?
- Type: `PluginRuntime["channel"]`.
- In `ChannelGatewayContext`, it is **optional** (`channelRuntime?`).

### Does Clawline currently import internal gateway/routing modules directly that could be replaced?
- In `extensions/clawline/**`: **No** direct private core imports found; already using `openclaw/plugin-sdk`.
- In `src/clawline/server.ts`: yes, direct internal imports exist, but this module is not currently fed via `ChannelGatewayContext`.

### What should Clawline implement in the new plugin interface?
- Nothing is strictly required; upstream is backward compatible.
- To consume `channelRuntime`, Clawline would need a `gateway.startAccount(ctx)` path (or another explicit runtime bridge).

### Can B2/B3/B8 be expressed more cleanly through `channelRuntime`?
- **B2 (session routing)**: partially. Session bookkeeping helpers could migrate to `channelRuntime.session.*` if Clawline service receives runtime injection.
- **B3 (`/alert`)**: mostly no. Alert endpoint/session selection remains Clawline-specific business logic.
- **B8 (auth customizations)**: no direct `channelRuntime` equivalent; auth remains custom Clawline code.

### What internal imports become unnecessary with full adoption?
If Clawline service eventually receives `PluginRuntime["channel"]`, likely removable imports from `src/clawline/server.ts` include:
- `../agents/identity.js` helpers used for reply config/human delay
- `../auto-reply/reply/dispatch-from-config.js`
- `../auto-reply/reply/inbound-context.js`
- `../auto-reply/reply/reply-dispatcher.js`
- `../channels/session.js`

No immediate import removals in `extensions/clawline/**` because there are no private imports there now.

## Migration Path (Maximize Adoption, Minimize Risk)

### Phase 1 (required in this rebase collision)
1. Take upstream pattern verbatim for:
- `src/channels/plugins/types.adapters.ts`
- `src/gateway/server-channels.ts`
- `src/gateway/server.impl.ts`
2. Ensure Clawline compiles unchanged with optional `channelRuntime` unused.

### Phase 2 (Clawline runtime-bridge follow-up, separate change)
Goal: make Clawline service consume runtime helpers without private imports.

Recommended approach:
1. Add explicit runtime bridge for Clawline service startup (preferred) rather than forcing a dummy `gateway.startAccount` loop.
2. Pass `PluginRuntime["channel"]` (or full `PluginRuntime`) into Clawline service entrypoint.
3. Replace direct helper imports in `src/clawline/server.ts` with runtime calls where semantically equivalent.
4. Keep Clawline-specific routing/auth logic unchanged (B2/B3/B8 behavior-preserving).

Why not a quick `channel.ts` no-op `startAccount`?
- `ChannelManager` expects `startAccount` to be long-lived; returning immediately triggers restart behavior.
- Clawline lifecycle today is service-managed; forcing gateway-lifecycle semantics here is a risky shape mismatch.

## Verification

### Merge correctness
- `git diff aba15763b upstream/v2026.3.2 -- src/channels/plugins/types.adapters.ts`
- `git diff aba15763b upstream/v2026.3.2 -- src/gateway/server-channels.ts`
- `git diff aba15763b upstream/v2026.3.2 -- src/gateway/server.impl.ts`

### Injection wiring checks
- `rg -n "channelRuntime" src/channels/plugins/types.adapters.ts src/gateway/server-channels.ts src/gateway/server.impl.ts`
- Confirm `channelRuntime?: PluginRuntime["channel"]` in `ChannelGatewayContext`.
- Confirm `createChannelManager({... channelRuntime: createPluginRuntime().channel })` wiring.

### Clawline dependency-surface checks
- `grep -rn "from.*src/\|from.*openclaw/(?!plugin-sdk)" extensions/clawline/src/ extensions/clawline/index.ts 2>/dev/null | head -30`
- Expect no private core imports in extension.

### Behavior regression checks (B2/B3/B8)
- `pnpm test src/clawline/server.test.ts`
- Specifically confirm alert routing/session-key behaviors and auth cases remain unchanged.
- Run full build gate: `pnpm build`

## Blockers / Risks
1. **Lifecycle mismatch blocker**: `channelRuntime` is only injected through `gateway.startAccount`, but Clawline is service-lifecycle driven.
2. **No service runtime channel today**: plugin service context does not currently include runtime/channelRuntime.
3. **Coverage gap in runtime helpers**: B8 auth logic is outside `channelRuntime` scope.
4. **Behavior risk if forced into gateway loop**: dummy/short-lived `startAccount` causes restart-loop semantics.

## Decision
For this collision zone, adopt upstream `channelRuntime` wiring exactly, keep Clawline behavior unchanged, and treat Clawline runtime bridge as a targeted follow-up spec/implementation.
