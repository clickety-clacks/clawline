# Surf Ace Standalone Plugin Recon

**Date:** 2026-03-04  
**Branch:** surf-ace-manual-register  
**Codebase:** `~/src/worktrees/surf-ace-manual-register`

---

## Verdict

**Fully possible as a standalone extension with no core changes required.**

All five requirements map cleanly onto existing plugin SDK primitives. A proof-of-concept pattern already exists in `extensions/clawline/index.ts` — the standalone surf-ace provider is essentially that extension with the clawline channel dependency removed.

---

## SDK Inventory

### `registerService` — Long-running background services

`OpenClawPluginService` (`dist/plugin-sdk/plugins/types.d.ts`):
```ts
type OpenClawPluginService = {
  id: string;
  start: (ctx: OpenClawPluginServiceContext) => void | Promise<void>;
  stop?: (ctx: OpenClawPluginServiceContext) => void | Promise<void>;
};

type OpenClawPluginServiceContext = {
  config: OpenClawConfig;
  workspaceDir?: string;
  stateDir: string;      // ← disk persistence path
  logger: PluginLogger;
};
```

Services are started when the gateway starts and stopped on gateway shutdown. They run for the full gateway lifetime. `phone-control` already uses this with a `setInterval`-based timer service. **Works today, no changes needed.**

### `registerTool` — Tool registration without channel dependency

`api.registerTool((ctx) => AnyAgentTool | AnyAgentTool[] | null)` accepts a factory. The factory receives `OpenClawPluginToolContext` with `sessionKey`, `messageChannel`, `agentId`, `config`, etc. **No channel required** — `llm-task` registers its tool with zero channel dependency. Tools show up in every agent session.

The factory is called per-agent-run, so the singleton-bridge pattern (service sets a module-level handle, factory reads it) is the right approach. Already proven in `extensions/clawline/src/surf-ace-runtime.ts` + `surf-ace-tools.ts`.

### `registerHttpRoute` — Static file serving / content push

```ts
api.registerHttpRoute({ path: "/surf-ace/...", handler: async (req, res) => { ... } });
```

Available on the plugin API. No blockers for optional webroot serving.

### `gateway_start` / `gateway_stop` typed hooks

```ts
api.on("gateway_start", async (event, ctx) => { /* port available here */ });
api.on("gateway_stop", async (event, ctx) => { /* cleanup */ });
```

Both are in `PluginHookName`. These fire exactly when the service lifecycle fires, so they're redundant with `registerService` — either works.

### `enqueueSystemEvent` — Waking the CLU agent

Available via `api.runtime.system.enqueueSystemEvent(text, { sessionKey })`. However: **this is already built into `createSurfAceManager`**. The core `surf-ace.ts` hardcodes `SURF_ACE_ALERT_SESSION_KEY = "agent:main:main"` and calls `enqueueSystemEvent` internally when surface activity arrives. A plugin using `createSurfAceManager` from the SDK gets this behavior automatically.

Alternatively, `callGateway` from `dist/plugin-sdk/gateway/call.d.ts` can POST to the gateway's session, which is the documented approach for plugin→agent messaging.

### `createSurfAceManager` / `discoverSurfAceScreens` — Exported from plugin-sdk

`dist/plugin-sdk/clawline/surf-ace.d.ts` exports:
- `createSurfAceManager(options: SurfAceManagerOptions): SurfAceRuntime` — the full WS connection manager
- `discoverSurfAceScreens(timeoutMs: number): Promise<DiscoveryRecord[]>` — the dns-sd discovery impl

`SurfAceManagerOptions` accepts a `discoverImpl` injection point, so custom discovery is fully injectable without touching the core. The `statePath`, `logger`, and all timing parameters are configurable.

---

## mDNS/Bonjour Discovery

The existing implementation uses `dns-sd` CLI via `runCommandWithTimeout`:
```ts
const browse = await runCommandWithTimeout(["dns-sd", "-B", "_surf-ace._tcp", "local."], ...);
```

`runCommandWithTimeout` is exposed at `api.runtime.system.runCommandWithTimeout`. However since `discoverSurfAceScreens` is exported from the plugin-sdk (bundled in the core), a plugin can just call it directly without needing runtime access. On macOS, `dns-sd` is native. On Linux, `discoverImpl` can be swapped for an Avahi-based wrapper.

**No blocker.** Node.js `child_process` is available; so are native Node.js dns-sd bindings if preferred. The `discoverImpl` injection makes it platform-portable.

---

## Existing Clawline Pattern (Already Proven)

`extensions/clawline/index.ts` is the reference implementation:

```ts
export default function register(api: OpenClawPluginApi) {
  api.registerChannel({ plugin: clawlinePlugin });           // ← channel dep
  api.registerTool((ctx) => createSurfAceTools({ context: ctx }));  // ← tools
  api.registerService({
    id: "clawline",
    start: async ({ config, logger }) => {
      serviceHandle = await startClawlineService({ config, logger });
      setClawlineSurfAceRuntime(serviceHandle?.getSurfAceRuntime() ?? null);
    },
    stop: async () => { await serviceHandle?.stop(); },
  });
}
```

The surf-ace tools are gated by `isClawlineToolContext(ctx)` — they only appear in clawline sessions. This is the **only** coupling to clawline that needs to change for a standalone provider.

---

## Recommended Implementation Path

### Standalone `extensions/surf-ace-provider/index.ts`

```ts
import path from "node:path";
import type { OpenClawPluginApi, OpenClawPluginService } from "openclaw/plugin-sdk";
import { createSurfAceManager, discoverSurfAceScreens, emptyPluginConfigSchema } from "openclaw/plugin-sdk";
import { createSurfAceTools } from "./src/tools.js";

let runtime: ReturnType<typeof createSurfAceManager> | null = null;

const surfAceService: OpenClawPluginService = {
  id: "surf-ace-provider",
  start: async ({ stateDir, logger }) => {
    runtime = createSurfAceManager({
      statePath: path.join(stateDir, "surf-ace-screens.json"),
      discoverImpl: discoverSurfAceScreens,   // ← uses dns-sd CLI
      logger,
    });
    await runtime.start();
  },
  stop: async () => {
    await runtime?.stop();
    runtime = null;
  },
};

export default function register(api: OpenClawPluginApi) {
  api.registerTool((ctx) => {
    if (!runtime) return null;
    return createSurfAceTools({ runtime, context: ctx });
  });
  api.registerService(surfAceService);
}
```

### `extensions/surf-ace-provider/openclaw.plugin.json`

```json
{
  "id": "surf-ace-provider",
  "name": "Surf Ace Provider",
  "description": "mDNS surface discovery + WS connection manager. Registers surf_ace_* tools.",
  "configSchema": { "type": "object", "additionalProperties": false, "properties": {} }
}
```

### Tools (`src/tools.ts`)

Copy `extensions/clawline/src/surf-ace-tools.ts` with one change: **remove** the `isClawlineToolContext` gate. Tools should be available in all sessions, not just clawline sessions. Pass `runtime` directly instead of `requireClawlineSurfAceRuntime()`.

---

## Gaps / Notes

| Item | Status | Detail |
|------|--------|--------|
| Background service lifecycle | ✅ Fully supported | `registerService` start/stop in gateway |
| Tool registration (no channel dep) | ✅ Fully supported | `registerTool` factory, proven by `llm-task` |
| mDNS discovery | ✅ Works | `discoverSurfAceScreens` exported from SDK, uses `dns-sd` CLI |
| WS connection manager | ✅ Works | `createSurfAceManager` exported from SDK, full reconnect logic included |
| Wake CLU agent on surface activity | ✅ Built into core | Hardcoded `enqueueSystemEvent("agent:main:main")` in `createSurfAceManager` |
| State persistence | ✅ Works | `stateDir` in service context, plain `fs.writeFile` |
| Static file serving | ✅ Works | `registerHttpRoute` on plugin API |
| Manifest `service` field | ⚠️ Not needed | `registerService` call is sufficient; no manifest field required |
| Cross-session tool availability | ⚠️ Minor tweak | Remove `isClawlineToolContext` gate from tool factory |
| Linux mDNS | ⚠️ Platform gap | `dns-sd` is macOS-native; Linux needs Avahi wrapper via `discoverImpl` injection |
| Core changes required | ❌ None | Zero |

---

## Hard Blockers

**None.** The plugin SDK supports every required capability. The pattern is proven by the existing `extensions/clawline/index.ts` implementation. The standalone surf-ace provider is a refactor, not a new feature.

---

## What the "surf-ace-manual-register" Branch Already Has

- `extensions/surf-ace/openclaw.plugin.json` — skeleton manifest (id + skills only, no JS entry)
- `extensions/clawline/src/surf-ace-runtime.ts` — singleton bridge pattern
- `extensions/clawline/src/surf-ace-tools.ts` — complete tool definitions for all 5 tools
- `dist/plugin-sdk/clawline/surf-ace.d.ts` — `createSurfAceManager` + `discoverSurfAceScreens` exported
- `dist/plugin-sdk/plugins/types.d.ts` — `OpenClawPluginService`, `registerService` all present

The gap is purely wiring: connect a new `extensions/surf-ace-provider/index.ts` that stands up the manager as a service, without depending on the clawline channel being enabled.

---

## Recommended Next Step

1. Create `extensions/surf-ace-provider/` with the structure above
2. Port `surf-ace-tools.ts` from clawline extension, remove clawline session gate
3. Register the plugin in user config: add `surf-ace-provider` to plugin list
4. Verify `surf_ace_list` appears in agent tool inventory without clawline enabled

Estimated implementation: 1–2 hours for an impl agent. No spec agent needed — design is fully resolved.
