# Plugin HTTP registration contract migration (rebase-2026-03-03)

## Scope
- Upstream contract change studied from:
  - `src/plugins/types.ts` (`aba15763b..v2026.3.2`)
  - `src/plugins/registry.ts` (`aba15763b..v2026.3.2`)
  - `src/gateway/server/plugins-http.ts` (`aba15763b..v2026.3.2`)
- Clawline usage check performed in:
  - `src/clawline/`
  - `extensions/clawline/`

## Old API vs New API

### Old API (pre-`v2026.3.2`)
```ts
registerHttpHandler(handler: (req, res) => Promise<boolean> | boolean): void
registerHttpRoute(params: { path: string; handler: (req, res) => Promise<void> | void }): void
```

### New API (`v2026.3.2`)
```ts
type OpenClawPluginHttpRouteAuth = "gateway" | "plugin";
type OpenClawPluginHttpRouteMatch = "exact" | "prefix";

type OpenClawPluginHttpRouteHandler = (
  req: IncomingMessage,
  res: ServerResponse,
) => Promise<boolean | void> | boolean | void;

type OpenClawPluginHttpRouteParams = {
  path: string;
  handler: OpenClawPluginHttpRouteHandler;
  auth: OpenClawPluginHttpRouteAuth;
  match?: OpenClawPluginHttpRouteMatch; // default: "exact"
  replaceExisting?: boolean; // default: false
};

registerHttpRoute(params: OpenClawPluginHttpRouteParams): void
```

## Field semantics
- `path`: normalized to leading `/` at registration time.
- `auth` (required):
  - `"gateway"`: gateway bearer auth is enforced before route handler runs.
  - `"plugin"`: no gateway bearer auth by default; plugin route owns auth decisions.
- `match`:
  - `"exact"` (default): exact canonical path match.
  - `"prefix"`: subtree/prefix match.
- `replaceExisting`:
  - false/missing: duplicate (`path` + `match`) rejected.
  - true: replacement only allowed for the same plugin owner; cross-plugin replacement rejected.
- handler return value:
  - `false` => fall through to next matching plugin route.
  - any other return (`true` or `void`) => treated as handled.

## Auth behavior details (`gateway` vs `plugin`)
- Gateway request pipeline computes matching plugin route(s), then enforces auth for:
  - routes configured as `auth: "gateway"`, and
  - protected path space (`/api/channels`), and
  - malformed/decode-overflow paths (fail-closed behavior).
- Therefore, even a route marked `auth: "plugin"` is still gateway-auth enforced if it is in protected plugin path space (`/api/channels...`) or path canonicalization is suspicious.

## Route precedence behavior now
- Core built-in HTTP handlers run first (hooks/tools/slack/openresponses/openai/canvas).
- Plugin HTTP routes run next.
- Control UI avatar + SPA catch-all run after plugin routes.
- Gateway probes (`/health`, `/healthz`, `/ready`, `/readyz`) run later and are only reached if no earlier stage handled the request.
- Within plugin routes:
  - exact matches before prefix matches,
  - longer paths before shorter paths,
  - handler can opt into fallthrough by returning `false`.

## Clawline HTTP surface and migration impact

### Key finding
`src/clawline` and `extensions/clawline` currently do **not** call `registerHttpHandler` or `registerHttpRoute`.

Clawline HTTP + WS endpoints are served by Clawline's own provider server (`src/clawline/server.ts`), not the plugin gateway route registry.

### Current Clawline endpoints (non-plugin-route mechanism)
- `GET /version` (public)
- `POST /upload` (Clawline bearer/JWT via `authenticateHttpRequest`)
- `GET /download/:assetId` (Clawline bearer/JWT via `authenticateHttpRequest`)
- `GET|POST /api/streams` (Clawline bearer/JWT)
- `PATCH|DELETE /api/streams/:sessionKey` (Clawline bearer/JWT)
- `GET|HEAD /www/**` static files (public webroot with path/symlink hardening)
- `POST /alert` (no gateway bearer; validates payload + session key)
- `POST /surf-ace/events/:screenId` (no gateway bearer)
- WebSocket upgrade endpoints:
  - `/ws` (pair/auth message protocol)
  - `/ws/terminal` (terminal auth message protocol with token validation)

### Complete migration for Clawline registrations
- **Required code migration for Clawline due this API change: none.**
- There are no Clawline-side `registerHttpHandler(...)` calls to convert.
- There are no Clawline-side `registerHttpRoute(...)` calls missing `auth`.

### If/when Clawline endpoints are moved into gateway plugin routing
Use the new call shape and explicit `auth`:
```ts
api.registerHttpRoute({
  path: "/alert",
  auth: "plugin",
  match: "exact",
  handler: handleAlert,
});

api.registerHttpRoute({
  path: "/www",
  auth: "plugin",
  match: "prefix",
  handler: handleWebRoot,
});
```
- Endpoints intended to remain channel/protected in `/api/channels/...` should use `auth: "gateway"`.
- WebSocket upgrade endpoints (`/ws`, `/ws/terminal`) are not handled by `registerHttpRoute`; they require explicit upgrade handling.

## Verification plan

### Compilation
1. Rebase/merge to upstream `v2026.3.2`.
2. Run:
```bash
pnpm build
```
3. Assert no TypeScript errors mentioning removed `registerHttpHandler` in Clawline paths.

### Static usage check
```bash
rg -n "registerHttpHandler|registerHttpRoute" src/clawline extensions/clawline
```
Expected: no hits in current Clawline code.

### Route reachability/regression checks
- Clawline provider endpoint behavior:
```bash
pnpm vitest src/clawline/server.test.ts -t "/alert"
pnpm vitest src/clawline/server.test.ts -t "/www"
pnpm vitest src/clawline/server.test.ts -t "terminal"
```
- Upstream plugin-route auth + precedence behavior:
```bash
pnpm vitest src/gateway/server/plugins-http.test.ts src/gateway/server.plugin-http-auth.test.ts
```

## Blockers
- No Clawline-specific blocker found for this contract migration.
- Operational note: upstream ref in the prompt appears as `upstream/v2026.3.2`; local repos commonly have this as tag `v2026.3.2` (no `upstream/` prefix). Use whichever exists locally.
