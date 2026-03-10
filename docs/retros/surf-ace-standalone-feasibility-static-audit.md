# Surf Ace Standalone Extension — Static Implementation Feasibility Audit

**Date:** 2026-03-05  
**Auditor:** CLU subagent (surf-ace-standalone-audit)  
**Sources audited:**
- Spec: `/Users/mike/shared-workspace/clawline/specs/surf-ace.md`
- Plugin API: `src/plugins/types.ts`, `src/plugins/registry.ts`
- Published SDK: `dist/plugin-sdk/plugin-sdk/index.d.ts` + `dist/plugin-sdk/plugin-sdk/`
- Reference extensions: `extensions/discord/`, `extensions/clawline/`, `extensions/diffs/`
- Existing scaffold: `extensions/surf-ace/`
- Package exports: `package.json` (root)

---

## 1. Capability Matrix

For each major Surf Ace provider requirement, the exact extension-local implementation path.

| Requirement | Extension-Local Implementation Path | SDK/API Anchor |
|---|---|---|
| **mDNS discovery** | Spawn `dns-sd -B _surf-ace._tcp local.` + `dns-sd -L <instance> _surf-ace._tcp local.` and parse stdout. Uses `runtime.system.runCommandWithTimeout` from PluginRuntime. No npm package required (macOS `dns-sd` is always present). Windows requires `dns-sd.exe` from Bonjour SDK or extension can bundle `bonjour-service` npm. | `PluginRuntimeCore.system.runCommandWithTimeout` (exposed on `api.runtime`) |
| **WS client / connection manager** | Implement extension-local `SurfAceConnectionJob` using the `ws` npm package (already in openclaw monorepo `node_modules/ws`). One persistent WS client per discovered surface. Handles pair handshake, reconnect, event buffering. `createSurfAceManager` exists in the dist at `dist/plugin-sdk/clawline/surf-ace.js` but has **no published package export path** (not in `package.json` `"exports"` map) — extension cannot import it without an internal path hack. Must implement locally. | npm `ws` package; `WebSocket` from `ws` |
| **CLU tool registration** | `api.registerTool(factory, opts?)` — fully supported. Pattern established by clawline's `createSurfAceTools` and discord's tools. Tools receive `OpenClawPluginToolContext` (sessionKey, agentId, messageChannel, etc.). | `OpenClawPluginApi.registerTool` in `src/plugins/types.ts` |
| **Alert / wake routing** | `api.runtime.system.enqueueSystemEvent(text, { sessionKey })` queues an ephemeral system event for the target session (e.g. `agent:main:main`). `api.runtime.system.requestHeartbeatNow({ reason, coalesceMs })` triggers a heartbeat wake on the next poll cycle. Together these replicate Clawline's alert pipeline without any Clawline code. | `PluginRuntimeCore.system.enqueueSystemEvent`, `PluginRuntimeCore.system.requestHeartbeatNow` |
| **State persistence** | `stateDir` is provided in `OpenClawPluginServiceContext.stateDir`. Write JSON state with `writeJsonFileAtomically(path, data)` and read with `readJsonFileWithFallback(path, fallback)` — both exported from `openclaw/plugin-sdk`. | `OpenClawPluginServiceContext.stateDir`; SDK exports `writeJsonFileAtomically`, `readJsonFileWithFallback` |
| **Skills injection** | `openclaw.plugin.json` `"skills"` field already supported and already configured in the scaffold: `{ "skills": ["./skills"] }`. Skill files in `extensions/surf-ace/skills/**` are auto-loaded by core. `surf-ace-markup` skill is already scaffolded. | `openclaw.plugin.json` manifest spec |
| **Agent instruction injection** | `api.on("before_prompt_build", async () => ({ prependContext: SURF_ACE_INSTRUCTIONS }))` — typed hook that fires before each agent turn. Returns `{ prependContext?: string }`. Pattern confirmed working in `extensions/diffs/index.ts:38-40`. Implementation goes in `extensions/surf-ace/src/agent-instructions.ts` (content) + `extensions/surf-ace/index.ts` (wires the hook). | `PluginHookName: "before_prompt_build"`, `PluginHookBeforePromptBuildResult.prependContext`; `OpenClawPluginApi.on` |
| **HTTP inbound route** | Not required for the primary event path (provider is WS client, events arrive over the socket). `api.registerHttpRoute({ path, handler, auth, match })` is available if needed for secondary callbacks or admin endpoints. | `OpenClawPluginApi.registerHttpRoute` |
| **Gateway method registration** | `api.registerGatewayMethod(method, handler)` available for any gateway-exposed operations (e.g. canvas-relay integration). | `OpenClawPluginApi.registerGatewayMethod` |
| **Service lifecycle** | `api.registerService({ id, start, stop })` — `start(ctx)` receives `{ config, stateDir, logger }`. Extension starts its discovery loop and WS manager here. | `OpenClawPluginApi.registerService`, `OpenClawPluginServiceContext` |

---

## 2. Blocker Table

Format: Requirement | Blocker? | Evidence path | Workaround

| Requirement | Blocker? | Evidence path | Workaround |
|---|---|---|---|
| `createSurfAceManager` (full WS state machine) | ❌ NOT a blocker | `dist/plugin-sdk/clawline/surf-ace.js` exists but `package.json` exports map has NO `openclaw/clawline/*` entry — import would require internal path hack | Implement extension-local `SurfAceConnectionJob` (~350-500 lines) using `ws` npm. The `discoverImpl` parameter pattern in the existing source confirms this was always designed to be injected. |
| `discoverSurfAceScreens` (mDNS browse) | ❌ NOT a blocker | Same file, same missing export path | Extension calls `runtime.system.runCommandWithTimeout(["dns-sd", "-B", "_surf-ace._tcp", "local."])` directly — the existing core implementation does exactly this. 30-50 lines of stdout parsing. |
| `startClawlineService` (Clawline service factory) | ❌ NOT a blocker | IS exported from `openclaw/plugin-sdk` (line 198 of `plugin-sdk/index.d.ts`) | But using it would make Surf Ace depend on Clawline being configured, violating spec §2.4 invariant 14. Do not use. Extension runs its own `createSurfAceManager` equivalent. |
| Alert/wake routing without Clawline internal helpers | ❌ NOT a blocker | `PluginRuntimeCore.system.enqueueSystemEvent` + `requestHeartbeatNow` are in PluginRuntime | Confirmed in `dist/plugin-sdk/plugins/runtime/types-core.d.ts` lines 15-16. No Clawline helpers needed. |
| `before_prompt_build` for agent instruction injection | ❌ NOT a blocker | `api.on("before_prompt_build", ...)` in `OpenClawPluginApi` | Confirmed working in `extensions/diffs/index.ts`. Zero Clawline involvement. |
| Skills injection | ❌ NOT a blocker | `openclaw.plugin.json` `"skills"` field | Already in scaffold manifest. `surf-ace-markup` SKILL.md already present. |
| State persistence (stateDir) | ❌ NOT a blocker | `OpenClawPluginServiceContext.stateDir` | SDK exports `readJsonFileWithFallback`, `writeJsonFileAtomically`. |
| WS client package (`ws`) in external install | ⚠️ CONDITIONAL | `ws` is in openclaw monorepo `node_modules` — available in-monorepo, but not guaranteed in a fresh external install | Extension `package.json` must declare `ws` as a dependency. Handled at packaging/install time. Not a code-level blocker. |

**Summary:** Zero hard blockers. One conditional (ws dependency in external installs) resolved at package level.

---

## 3. Minimal Extension-Local Glue List

These are the pieces that must be written inside the extension to substitute for missing SDK convenience exports. All are feasible and bounded in scope.

### 3.1 `src/surf-ace-discovery.ts` (~60-100 lines)
mDNS browse + resolve using `dns-sd` CLI.

```typescript
// Uses runtime.system.runCommandWithTimeout
export type DiscoveryRecord = { instanceName: string; host: string; port: number; txt: Record<string, string> };

export async function discoverSurfAceScreens(
  runCmd: RunCommandFn,
  timeoutMs: number
): Promise<DiscoveryRecord[]> {
  const browse = await runCmd(["dns-sd", "-B", "_surf-ace._tcp", "local."], { timeoutMs });
  const instances = parseBrowseOutput(browse.stdout); // regex over "Add  <flags>  ... instanceName"
  const results: DiscoveryRecord[] = [];
  for (const name of instances) {
    const resolve = await runCmd(["dns-sd", "-L", name, "_surf-ace._tcp", "local."], { timeoutMs });
    const record = parseResolveOutput(resolve.stdout, name); // parse host/port/txt
    if (record) results.push(record);
  }
  return results;
}
```

Estimated: **80-120 lines** including parsers.

### 3.2 `src/surf-ace-connection.ts` (~300-450 lines)
Per-surface WS client that:
- Initiates connection to `ws://host:port/ws`
- Runs pair handshake (`pair.request` → `pair.response`)
- Maintains reconnect with exponential backoff
- Routes inbound `event.*` messages to a local buffer
- Provides `push()`, `clear()`, `snapshot()` methods over the socket
- Emits events to the alert system via `enqueueSystemEvent` + `requestHeartbeatNow`

```typescript
import WebSocket from "ws";

export class SurfAceConnectionJob {
  constructor(private params: { record: DiscoveryRecord; stateDir: string; runtime: PluginRuntime }) {}
  async start(): Promise<void> { /* connect, pair, event loop */ }
  async stop(): Promise<void> { /* close ws, clear timers */ }
  async push(params: PushParams): Promise<PushResult> { /* send content.set over ws */ }
  async clear(params: ClearParams): Promise<void> { /* send content.clear */ }
  getSnapshot(): SurfAceDiscoveredScreen | null { /* return local buffer */ }
  handleEvent(event: unknown): void { /* route to buffer + fire enqueueSystemEvent */ }
}
```

Estimated: **300-450 lines**.

### 3.3 `src/surf-ace-manager.ts` (~150-200 lines)
Orchestrator that:
- Runs the discovery loop on a timer (configurable interval, default 10s)
- Maintains a map of `{ fingerprint → SurfAceConnectionJob }`
- Exposes the `SurfAceRuntime` interface (`pair`, `push`, `clear`, `snapshot`, `watch`, `buildContextInjection`)
- Handles connection cleanup on `stop()`

Estimated: **150-200 lines**.

### 3.4 `src/surf-ace-alert.ts` (~50-80 lines)
Helper that formats surface event alerts and fires them via `enqueueSystemEvent` + `requestHeartbeatNow`.

```typescript
export function emitSurfAceAlert(params: {
  runtime: PluginRuntime;
  targetSessionKey: string;
  event: SurfAceInboundEvent;
  screen: SurfAceDiscoveredScreen;
}): void {
  runtime.system.enqueueSystemEvent(
    `Surf Ace: ${event.type} from "${screen.name}" (${screen.fingerprint})`,
    { sessionKey: targetSessionKey }
  );
  runtime.system.requestHeartbeatNow({ reason: "surf-ace-event", coalesceMs: 500 });
}
```

Estimated: **50-80 lines**.

### 3.5 `src/agent-instructions.ts` (~50-80 lines)
Static string constant (the agent instruction snippet) documenting Surf Ace event semantics, pane/tab lifecycle, and tool usage patterns. Wired in `index.ts` via `api.on("before_prompt_build", ...)`.

Estimated: **50-80 lines** of prose + wiring.

**Total glue code estimate: ~650-930 lines across 5 files.** All are well-scoped, testable, and have no external dependencies beyond `ws`.

---

## 4. Confidence Verdict

### **YES** — Surf Ace can be built as a 100% standalone OpenClaw extension with no Clawline dependency and no core patches.

**Assumptions:**
1. The `ws` npm package is declared as a dependency in `extensions/surf-ace/package.json` (or bundled). For in-monorepo builds this is already satisfied by the root `node_modules`.
2. The target platform is macOS (where `dns-sd` CLI is available). For Windows/Linux support, an additional npm-based mDNS fallback (e.g. `bonjour-service`) would be needed — this is a surface-app concern more than a provider concern, since v1 deployment is macOS-first.
3. `api.runtime.system.runCommandWithTimeout`, `enqueueSystemEvent`, and `requestHeartbeatNow` remain stable in the PluginRuntime API (they have been since at least the current release).
4. The `before_prompt_build` typed hook continues to accept `prependContext` (confirmed by types + diffs extension).

**Caveats:**
- `createSurfAceManager` in the dist is intentionally NOT re-exported in the public SDK interface. This is likely intentional — it's Clawline-internal. The standalone extension must implement its own. This is a known design decision (spec §2.4 rule 1: no cross-extension imports).
- The glue code (~700-900 lines) is non-trivial but is standard WS client code with no novel architecture. It mirrors what `src/clawline/surf-ace.ts` already does; the implementation can reference that source as a model without importing it.
- Skills injection is already scaffolded. Agent instruction injection is a one-liner `api.on` call.

---

## 5. OT-5 Distribution Method Recommendation

**Recommendation: Source drop-in (Option 1) for the current monorepo phase; prebuilt `.zip` artifact (Option 2) for any future out-of-tree delivery.**

### Reasoning

**Right now (in-monorepo):** `extensions/surf-ace/` already exists at the correct path. OpenClaw's extension loader discovers it automatically. TypeScript compiles as part of the monorepo build. The `ws` package is in the root `node_modules`. This is the zero-friction path and matches how every other extension (`discord`, `clawline`, `diffs`, `memory-lancedb`) is delivered today. Build + install is already handled by the monorepo toolchain. No additional packaging work needed.

**For future out-of-tree delivery:** A **prebuilt `.zip`** wins over a versioned package artifact because:
1. OpenClaw doesn't have a plugin registry yet — there's no `npm install @openclaw/surf-ace` surface.
2. A source drop-in requires the recipient to have the right toolchain (TypeScript, the openclaw monorepo setup). External installs won't have this.
3. A prebuilt zip (dist JS + `openclaw.plugin.json` + skills + `node_modules/ws`) can be dropped into any compatible OpenClaw install's `extensions/` directory without any build step.
4. Rollback = keep the old zip. Upgrade = replace directory. Verification = check `skills/surf-ace-ops/SKILL.md` and `skills/surf-ace-markup/SKILL.md` exist (spec §3073 requirement).

**Selection criteria checklist against OT-5:**
| Criterion | Source drop-in (now) | Prebuilt zip (future) |
|---|---|---|
| Works without Clawline | ✅ | ✅ |
| Requires no core patching | ✅ | ✅ |
| No external toolchain needed | ✅ (in-monorepo) | ✅ |
| Repeatable upgrades/rollback | ✅ (git) | ✅ (replace dir) |
| Verification of skills + injection | ✅ (CI can assert paths) | ✅ (include check script in zip) |

**Action:** Close OT-5 with: "Source drop-in for monorepo phase (current); prebuilt zip for any future out-of-tree distribution. No versioned package artifact until a plugin registry exists."

---

## Appendix: Key SDK/API Anchors Quick Reference

| API | Import path | What it provides |
|---|---|---|
| `api.registerTool` | `OpenClawPluginApi` | Tool factory registration |
| `api.registerService` | `OpenClawPluginApi` | Start/stop lifecycle hook |
| `api.registerHttpRoute` | `OpenClawPluginApi` | HTTP route (for optional admin endpoints) |
| `api.registerGatewayMethod` | `OpenClawPluginApi` | Gateway method registration |
| `api.on("before_prompt_build", ...)` | `OpenClawPluginApi` | Agent instruction injection |
| `api.runtime.system.enqueueSystemEvent` | `PluginRuntime` | Alert routing to target session |
| `api.runtime.system.requestHeartbeatNow` | `PluginRuntime` | Wake agent on next heartbeat |
| `api.runtime.system.runCommandWithTimeout` | `PluginRuntime` | Run `dns-sd` for mDNS discovery |
| `stateDir` (service context) | `OpenClawPluginServiceContext` | Persistent state directory |
| `readJsonFileWithFallback` | `openclaw/plugin-sdk` | State read with fallback |
| `writeJsonFileAtomically` | `openclaw/plugin-sdk` | Safe state write |
| `openclaw.plugin.json` `"skills"` field | Extension manifest | Skills auto-injection |
| `ws` npm package | Extension dependency | WS client for surface connections |
