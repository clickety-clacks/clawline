#!/usr/bin/env bash
set -euo pipefail

# Production-like static deploy for the Clawline web client on TARS.
# Run this from a source checkout/CI workspace; it installs only build artifacts
# into the macOS application-support service root. The service root must not be a
# git checkout.

INSTALL_ROOT="${CLAWLINE_WEB_INSTALL_ROOT:-$HOME/Library/Application Support/ClawlineWeb}"
PORT="${CLAWLINE_WEB_PORT:-4173}"
HTTPS_HOST="${CLAWLINE_WEB_HTTPS_HOST:-tars.tail4105e8.ts.net}"
HTTPS_PORT="${CLAWLINE_WEB_HTTPS_PORT:-19444}"
HTTPS_CERT="${CLAWLINE_WEB_HTTPS_CERT:-$HOME/.openclaw/workspace/certs/$HTTPS_HOST.crt}"
HTTPS_KEY="${CLAWLINE_WEB_HTTPS_KEY:-$HOME/.openclaw/workspace/certs/$HTTPS_HOST.key}"
LABEL="${CLAWLINE_WEB_LABEL:-com.clawline.web}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CADDY="${CADDY:-/opt/homebrew/bin/caddy}"
MANAGE_SERVICE="${CLAWLINE_WEB_MANAGE_SERVICE:-0}"

for arg in "$@"; do
  case "$arg" in
    --manage-service)
      MANAGE_SERVICE=1
      ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--manage-service]

Build and install Clawline web static artifacts into:
  $INSTALL_ROOT

By default this does not write, load, unload, or restart LaunchAgents.
Pass --manage-service or set CLAWLINE_WEB_MANAGE_SERVICE=1 to update and
bootstrap the user LaunchAgent.
USAGE
      exit 0
      ;;
    *)
      printf "Unknown argument: %s\n" "$arg" >&2
      exit 64
      ;;
  esac
done

npm ci
npm run build

if [[ ! -r "$HTTPS_CERT" || ! -r "$HTTPS_KEY" ]]; then
  printf "Missing HTTPS certificate or key for %s:%s\n" "$HTTPS_HOST" "$HTTPS_PORT" >&2
  printf "Expected certificate: %s\n" "$HTTPS_CERT" >&2
  printf "Expected key: %s\n" "$HTTPS_KEY" >&2
  exit 66
fi

mkdir -p "$INSTALL_ROOT/dist" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/logs"
rsync -a --delete dist/ "$INSTALL_ROOT/dist/"

cat > "$INSTALL_ROOT/Caddyfile" <<CADDYFILE
{
  auto_https disable_redirects
}

:$PORT {
  root * "$INSTALL_ROOT/dist"
  try_files {path} /index.html
  file_server
}

https://$HTTPS_HOST:$HTTPS_PORT {
  bind 0.0.0.0
  tls "$HTTPS_CERT" "$HTTPS_KEY"
  root * "$INSTALL_ROOT/dist"
  try_files {path} /index.html
  file_server
}
CADDYFILE

cat > "$INSTALL_ROOT/bin/serve.sh" <<SERVE
#!/bin/zsh
export HOME="$HOME"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
exec "$CADDY" run --config "$INSTALL_ROOT/Caddyfile" --adapter caddyfile
SERVE
chmod +x "$INSTALL_ROOT/bin/serve.sh"

if [[ "$MANAGE_SERVICE" != "1" ]]; then
  printf "Clawline web artifacts installed to %s\n" "$INSTALL_ROOT"
  printf "Service was not changed. Run %s --manage-service to update the LaunchAgent.\n" "$0"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$INSTALL_ROOT/bin/serve.sh</string></array>
  <key>WorkingDirectory</key><string>$INSTALL_ROOT</string>
  <key>StandardOutPath</key><string>$INSTALL_ROOT/logs/caddy.log</string>
  <key>StandardErrorPath</key><string>$INSTALL_ROOT/logs/caddy.log</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT"
sleep 1
curl -fsSI "http://127.0.0.1:$PORT/" >/dev/null
HTTPS_ROOT="https://$HTTPS_HOST:$HTTPS_PORT/"
VERIFY_HTML="$(mktemp -t clawline-web-https.XXXXXX.html)"
trap 'rm -f "$VERIFY_HTML"' EXIT
curl -fsS "$HTTPS_ROOT" -o "$VERIFY_HTML"
grep -q '<title>Clawline Web</title>' "$VERIFY_HTML"
JS_ASSET="$(grep -Eo 'assets/[^"]+\.js' "$VERIFY_HTML" | head -1)"
if [[ -z "$JS_ASSET" ]]; then
  printf "No JavaScript asset found in %s\n" "$HTTPS_ROOT" >&2
  exit 67
fi
curl -fsSI "$HTTPS_ROOT$JS_ASSET" >/dev/null
printf "Clawline web deployed to %s and serving on %s\n" "$INSTALL_ROOT" "$HTTPS_ROOT"
