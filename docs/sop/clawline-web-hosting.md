# Clawline Web Hosting

## Canonical Browser URL

Use this HTTPS-first URL for Surf Ace/browser panes:

```text
https://tars.tail4105e8.ts.net:19444/
```

The HTTPS listener serves the same static Clawline Web bundle as the local Caddy
backend on `http://tars.tail4105e8.ts.net:4173/`. The HTTP backend is not a
Surf Ace/iPad URL because App Transport Security requires HTTPS.

## TARS Runtime

- Install root: `/Users/mike/Library/Application Support/ClawlineWeb`
- Static bundle: `/Users/mike/Library/Application Support/ClawlineWeb/dist`
- Caddy config: `/Users/mike/Library/Application Support/ClawlineWeb/Caddyfile`
- Backend listener: `:4173`
- Canonical HTTPS listener: `https://tars.tail4105e8.ts.net:19444/`

Deploy from a source checkout with:

```bash
scripts/deploy/clawline-web-tars.sh
```

By default the deploy script installs artifacts and writes the Caddyfile without
changing LaunchAgents. Only pass `--manage-service` when the LaunchAgent change
has explicit approval.

## Route Ownership

Clawline Web is a standalone browser app service. Do not install it under
OpenClaw or serve it from the Clawline provider `/www` route on port `18800`.

Stale `19444` helper files under `/Users/mike/.openclaw/workspace/state` are not
the canonical runtime. They should point at the managed Clawline Web Caddy
service or be treated as historical notes, not as start commands.

## Semantic Verification

Verify the final HTTPS URL itself, not just the backend:

```bash
curl -kfsS -D /tmp/clawline-web-https.headers \
  https://tars.tail4105e8.ts.net:19444/ \
  -o /tmp/clawline-web-https.html
rg '<title>Clawline Web</title>' /tmp/clawline-web-https.html
JS_ASSET=$(rg -o 'assets/[^"]+\.js' /tmp/clawline-web-https.html | head -1)
curl -kfsSI "https://tars.tail4105e8.ts.net:19444/$JS_ASSET"
```
