# Surf Ace Standalone Plugin Recon v2

**Date:** 2026-03-04  
**Author:** Subagent surf-ace-standalone-recon-v2  
**Sources checked:**  
- `/Users/mike/openclaw/dist/plugin-sdk/` (most recent build, Mar 3 22:46+)  
- `/Users/mike/openclaw/src/` (source for cross-checking internal mechanics)  
- `/Users/mike/openclaw/extensions/` (bundled non-Clawline stock plugins)  
- `package.json` exports map  

---

## Verdict

**POSSIBLE WITH MINOR GAPS**

A Surf Ace surface provider can be implemented as a standalone OpenClaw extension installable on any stock OpenClaw install — *without* any dependency on Clawline. All five functional requirements can be satisfied using the official `./plugin-sdk` exports, with two small workarounds for gaps in the current SDK surface. Two one-liner additions to openclaw core would eliminate both workarounds cleanly.

---

## How Plugin Registration Works (Stock OpenClaw)

The plugin SDK entry point is `openclaw/plugin-sdk` (the only meaningful export in `package.json` other than `./plugin-sdk/account-id`).

A plugin exports an `OpenClawPluginDefinition` object (or a bare `register(api)` function). The `api: OpenClawPluginApi` object provides:

```
api.registerTool(tool, opts)          // Register CLU agent tools
api.registerService(service)          // Register long-running background service
api.registerHttpRoute({path, handler}) // Register HTTP route
api.registerHttpHandler(handler)       // Register raw HTTP handler
api.registerGatewayMethod(name, fn)    // Register gateway protocol method
api.registerCommand(cmd)               // Register /slash command
api.registerChannel(registration)      // Register messaging channel plugin
api.registerHook(events, handler)      // Register internal hook handler
api.on(hookName, handler)              // Register typed lifecycle hook
api.runtime                            // PluginRuntime (functions passed by openclaw core)
api.config                             // OpenClawConfig
api.pluginConfig                       // Plugin-specific config values
api.logger                             // Logger
```

The `PluginRuntime` object (`api.runtime`) includes:
- `system.enqueueSystemEvent` — queue text for the next agent prompt
- `system.runCommandWithTimeout` — run shell commands
- `state.resolveStateDir` — get state directory
- `config.loadConfig` / `config.writeConfigFile`
- Full channel provider methods (discord, slack, telegram, whatsapp, etc.)

---

## Requirement-by-Requirement Analysis

### 1. mDNS/Bonjour Discovery of `_surf-ace._tcp`

**SDK support:** None. OpenClaw has `src/infra/bonjour.ts` / `src/infra/bonjour-ciao.ts` internally (using the `@homebridge/ciao` library), but these are **not exported** from `./plugin-sdk`.

**Gap level:** Minor (no core change needed)

**Workaround:** The plugin adds its own mDNS dependency, e.g.:
- `@homebridge/ciao` (same lib openclaw uses internally)
- `bonjour-service` (lighter, pure JS)
- `mdns` (mature, C++ bindings)

All are standard npm packages. The plugin's `registerService` background task does the mDNS browsing. No openclaw core change needed.

---

### 2. Long-Running Background WS Connection Manager

**SDK support:** ✅ Fully covered by `registerService`.

```ts
api.registerService({
  id: 'surf-ace',
  start: async (ctx) => {
    // ctx.config, ctx.stateDir, ctx.logger, ctx.workspaceDir available
    // Start mDNS browser, maintain WS map, reconnect loop, etc.
    // ctx is OpenClawPluginServiceContext
  },
  stop: async (ctx) => {
    // Clean up connections
  },
});
```

The service `start` callback runs when the gateway starts. It's long-lived (no timeout). The service runs in the same Node.js process as openclaw.

**Important note:** The service closes over `api` from the outer `register(api)` scope. This means `api.runtime.system.enqueueSystemEvent`, `api.logger`, and `api.config` are all accessible inside the service callbacks even though `OpenClawPluginServiceContext` only provides `config`, `stateDir`, `workspaceDir`, `logger`.

**Gap level:** None

---

### 3. Register CLU Tools Without Being a Channel Plugin

**SDK support:** ✅ Fully covered by `registerTool`.

```ts
api.registerTool({
  name: 'surf_ace_list',
  description: 'List connected Surf Ace surfaces.',
  parameters: { /* JSON schema */ },
  execute: async (params, ctx) => {
    // ctx: OpenClawPluginToolContext
    // ctx.config, ctx.sessionKey, ctx.agentId, ctx.workspaceDir, etc.
    return { result: [...surfaces] };
  }
}, { optional: false });
```

The `OpenClawPluginToolContext` passed to tool `execute` callbacks includes `sessionKey` — which is used for the wake gap workaround (see Requirement 4).

Tools are registered independently of channels. `registerTool` and `registerChannel` are orthogonal. No channel plugin is required.

**Gap level:** None

---

### 4. Wake / Message the CLU Agent on Surface Activity

**SDK support:** Partial — two-step mechanism, second step has a gap.

**Step 1 — Queue agent text:** `api.runtime.system.enqueueSystemEvent(text, { sessionKey })` is available. When called, it prepends `text` to the next agent prompt for that session. This is how Discord/WhatsApp/Telegram channel monitors notify the agent of activity.

**Step 2 — Trigger immediate agent wake:** `requestHeartbeatNow(opts)` exists in `dist/plugin-sdk/infra/heartbeat-wake.d.ts` but is **NOT exported** from `./plugin-sdk` in `package.json`. Attempting to import it as `openclaw/dist/plugin-sdk/infra/heartbeat-wake.js` would fail with `ERR_PACKAGE_PATH_NOT_EXPORTED` (Node.js ESM enforces the exports map).

**Without `requestHeartbeatNow`:** Events queue correctly but the agent won't be woken until the next heartbeat tick (typically ~30 seconds on an active session).

**Gap level:** Moderate — events are delivered, but with up to ~30s latency

**Workaround options (pick one):**

**Option A — HTTP self-call to gateway hooks (works but messy):**  
Use `api.on('gateway_start', evt => port = evt.port)` to learn the gateway port. When surface activity arrives, POST to `http://localhost:{port}/hooks` with the hooks token from `api.config.hooks.token`. This triggers a `wake` action which calls both `enqueueSystemEvent` + `requestHeartbeatNow` internally. Requires `hooks.enabled: true` and a token in config.

**Option B — Accept the heartbeat latency:**  
For non-realtime notification use cases (e.g., "surface content changed, agent should read on next turn"), enqueue the system event and rely on the next natural heartbeat. Acceptable if the surface activity doesn't require sub-second agent response.

**Recommended fix (1-line core change):** Add `requestHeartbeatNow` to `PluginRuntime.system`:

```diff
// src/plugins/runtime/types.ts
 system: {
   enqueueSystemEvent: EnqueueSystemEvent;
+  requestHeartbeatNow: typeof import("../../infra/heartbeat-wake.js").requestHeartbeatNow;
   runCommandWithTimeout: RunCommandWithTimeout;
   formatNativeDependencyHint: FormatNativeDependencyHint;
 };
```

And wire it in `src/plugins/runtime/index.ts`. No behavioral risk — it's additive only.

**Sub-gap: Session key for `enqueueSystemEvent`:**  
`enqueueSystemEvent(text, { sessionKey })` requires a session key. `resolveMainSessionKeyFromConfig()` is not exported from `./plugin-sdk`. However:

1. The formula is simple: `agent:${agentId}:${mainKey}` where `agentId` defaults to `'main'` and `mainKey` defaults to `'main'` for standard installs.
2. The tool `execute` ctx includes `ctx.sessionKey`, so the service can capture it on first tool invocation.
3. **Cleanest option**: Export `resolveMainSessionKey(cfg)` from `./plugin-sdk` (takes config, no side effects).

```diff
// dist/plugin-sdk/plugin-sdk/index.d.ts
+export { resolveMainSessionKey } from "../config/sessions/main-session.js";
```

---

### 5. Persist State to Disk

**SDK support:** ✅ Fully covered.

Two exported utilities:
```ts
import { readJsonFileWithFallback, writeJsonFileAtomically } from "openclaw/plugin-sdk";
```

Plus the service context provides `ctx.stateDir` (the global OpenClaw state directory, e.g. `~/.openclaw/state`). The plugin can use `path.join(ctx.stateDir, 'surf-ace', 'surfaces.json')` for its state files.

For SQLite-backed state (if desired for surface content blobs), the plugin brings its own `better-sqlite3` dep — no core support needed.

**Gap level:** None

---

### 6. Optionally Serve Static Files via Webroot

**SDK support:** Partial — HTTP routing is available, static serving utility is not.

`api.registerHttpRoute({ path: '/surf-ace', handler })` registers a route on the gateway HTTP server. The plugin implements its own static file handler:

```ts
import fs from 'node:fs';
import path from 'node:path';
import { createReadStream } from 'node:fs';

api.registerHttpRoute({
  path: '/surf-ace',
  handler: async (req, res) => {
    // Resolve file from webroot, stream it
    const webrootPath = ctx.pluginConfig?.webroot as string;
    // ... ~30 lines of standard Node.js static serving
  }
});
```

Note: Clawline's webroot feature (in `src/clawline/server.ts`) is a full-featured implementation with symlink resolution, directory listing, etc. The standalone plugin would write a simpler equivalent (trivial, ~30 lines).

**Gap level:** Minor (trivial to implement, no core change needed)

---

## Summary Table

| Requirement | Stock SDK Support | Gap | Workaround |
|---|---|---|---|
| mDNS/Bonjour discovery | ❌ Not exported | Minor | Add `bonjour-service` npm dep |
| Long-running WS manager | ✅ `registerService` | None | — |
| CLU tools without channel | ✅ `registerTool` | None | — |
| Wake agent on activity — queue | ✅ `runtime.system.enqueueSystemEvent` | None | — |
| Wake agent on activity — trigger | ❌ `requestHeartbeatNow` not exported | Moderate | HTTP self-call to hooks, or accept ~30s latency |
| Session key for enqueue | ❌ `resolveMainSessionKey` not exported | Minor | Capture from tool ctx, or formula from config |
| Persist state | ✅ `writeJsonFileAtomically` + `stateDir` | None | — |
| Static file serving | ⚠️ `registerHttpRoute` available, no utility | Minor | Implement ~30-line handler |

---

## Recommended Path

### Minimal path (no core changes)

1. Build the plugin as a standalone npm package with `openclaw.plugin.json`
2. Add `@homebridge/ciao` or `bonjour-service` as a dependency for mDNS
3. Use `registerService` for WS manager + mDNS browser
4. Use `registerTool` for `surf_ace_list`, `surf_ace_push`, `surf_ace_clear`, `surf_ace_read`
5. Capture `sessionKey` from tool context on first invocation; store in module-level ref
6. On surface push activity: call `api.runtime.system.enqueueSystemEvent(text, { sessionKey })` — events queue for next heartbeat
7. For static serving: implement simple handler in `registerHttpRoute`
8. Accept ~30s max latency for agent wake (or add hooks self-call if unacceptable)

**Deliverable:** Fully functional, installable via `npm install surf-ace-provider` on any stock OpenClaw install.

### Clean path (2 small core additions to openclaw)

PR 1: Add `requestHeartbeatNow` to `PluginRuntime.system` (2 lines in types, 1 line in runtime index)  
PR 2: Export `resolveMainSessionKey(cfg)` from `./plugin-sdk` (1 line in plugin-sdk index)

After these two additions:
- No internal API workarounds
- No heartbeat latency
- Clean, forward-compatible implementation

---

## What Is NOT Needed

- ❌ No dependency on Clawline or any Clawline types/exports
- ❌ No channel plugin registration (`registerChannel` not needed)
- ❌ No messaging infrastructure (the tools are standalone agent tools, not channel commands)
- ❌ No changes to how openclaw loads plugins (standard discovery via `openclaw.plugin.json` and npm install)

---

## Confidence

High. All conclusions are based on direct inspection of:
- `dist/plugin-sdk/plugin-sdk/index.d.ts` — official exported surface
- `dist/plugin-sdk/plugins/types.d.ts` — full `OpenClawPluginApi` type
- `dist/plugin-sdk/plugins/runtime/types.d.ts` — full `PluginRuntime` type
- `package.json` exports map — what's importable
- `extensions/device-pair/index.ts` — stock plugin using `registerCommand`
- `extensions/memory-lancedb/index.ts` — stock plugin using `registerTool`, `registerService`, `api.on()`
- `src/infra/system-events.ts` — how `enqueueSystemEvent` works
- `src/infra/heartbeat-wake.ts` — how `requestHeartbeatNow` works and why it's needed
- `src/plugins/services.ts` — how service context is constructed
