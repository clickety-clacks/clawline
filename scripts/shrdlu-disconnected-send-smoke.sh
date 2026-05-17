#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-$ROOT_DIR/ios/Clawline/Clawline.xcodeproj}"
SCHEME="${SCHEME:-Clawline}"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17}"
SIMULATOR_ID="${SIMULATOR_ID:-}"
BUNDLE_ID="${BUNDLE_ID:-co.clicketyclacks.Clawline}"
SHRDLU_SSH="${SHRDLU_SSH:-shrdlu}"
SHRDLU_CLU_USER="${SHRDLU_CLU_USER:-clu}"
SHRDLU_PROVIDER_URL="${SHRDLU_PROVIDER_URL:-http://shrdlu:18800}"
TEST_DEVICE_ID="${CLAWLINE_SHRDLU_TEST_DEVICE_ID:-9B794B35-6829-4B2E-9C8A-D532399B7C85}"
TEST_USER_ID="${CLAWLINE_SHRDLU_TEST_USER_ID:-clawline_ios_disconnected_send_test}"
DRAFT_TEXT="${DRAFT_TEXT:-Disconnected send smoke $(date +%s)}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/scratch/shrdlu-disconnected-send-smoke/$(date +%Y%m%d-%H%M%S)}"
RESET_SIM_KEYCHAIN="${RESET_SIM_KEYCHAIN:-1}"

mkdir -p "$ARTIFACT_DIR"

log() {
  printf '[shrdlu-disconnected-send] %s\n' "$*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

remote_clu() {
  ssh "$SHRDLU_SSH" "sudo -n -iu $SHRDLU_CLU_USER bash -lc '$*'"
}

remote_prepare_device_and_token() {
  ssh "$SHRDLU_SSH" \
    "sudo -n -iu $SHRDLU_CLU_USER env TEST_DEVICE_ID='$TEST_DEVICE_ID' TEST_USER_ID='$TEST_USER_ID' python3 -" <<'PY'
import base64
import hashlib
import hmac
import json
import os
import pathlib
import time

state = pathlib.Path("/home/clu/.openclaw/clawline")
device_id = os.environ["TEST_DEVICE_ID"]
user_id = os.environ["TEST_USER_ID"]
now_ms = int(time.time() * 1000)

def read_json(path, fallback):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return fallback

def write_json(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)

allowlist_path = state / "allowlist.json"
denylist_path = state / "denylist.json"
allowlist = read_json(allowlist_path, {"version": 1, "entries": []})
denylist = read_json(denylist_path, [])

entries = allowlist.setdefault("entries", [])
entry = next((item for item in entries if item.get("deviceId") == device_id), None)
if entry is None:
    entry = {
        "deviceId": device_id,
        "claimedName": "clawline ios disconnected-send smoke",
        "deviceInfo": {"platform": "iOS", "model": "simulator integration smoke"},
        "requestedAt": now_ms,
        "createdAt": now_ms,
    }
    entries.append(entry)
entry.update({
    "userId": user_id,
    "isAdmin": False,
    "tokenDelivered": True,
})
write_json(allowlist_path, allowlist)

if isinstance(denylist, dict):
    deny_entries = denylist.get("entries", [])
    denylist["entries"] = [item for item in deny_entries if item.get("deviceId") != device_id]
    write_json(denylist_path, denylist)
elif isinstance(denylist, list):
    write_json(denylist_path, [item for item in denylist if item.get("deviceId") != device_id])

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")

key = (state / "jwt.key").read_text().strip().encode("utf-8")
header = {"alg": "HS256", "typ": "JWT"}
payload = {
    "sub": user_id,
    "deviceId": device_id,
    "isAdmin": False,
    "iat": int(time.time()),
    "exp": int(time.time()) + 3600,
}
signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}.{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
signature = hmac.new(key, signing_input.encode("ascii"), hashlib.sha256).digest()
print(f"{signing_input}.{b64url(signature)}")
PY
}

remote_cleanup_device() {
  ssh "$SHRDLU_SSH" \
    "sudo -n -iu $SHRDLU_CLU_USER env TEST_DEVICE_ID='$TEST_DEVICE_ID' python3 -" <<'PY' >/dev/null 2>&1 || true
import json
import os
import pathlib

state = pathlib.Path("/home/clu/.openclaw/clawline")
device_id = os.environ["TEST_DEVICE_ID"]

def read_json(path, fallback):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return fallback

def write_json(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(path)

allowlist_path = state / "allowlist.json"
denylist_path = state / "denylist.json"
allowlist = read_json(allowlist_path, {"version": 1, "entries": []})
allowlist["entries"] = [
    item for item in allowlist.get("entries", [])
    if item.get("deviceId") != device_id
]
write_json(allowlist_path, allowlist)

denylist = read_json(denylist_path, [])
if isinstance(denylist, dict):
    denylist["entries"] = [
        item for item in denylist.get("entries", [])
        if item.get("deviceId") != device_id
    ]
    write_json(denylist_path, denylist)
elif isinstance(denylist, list):
    write_json(denylist_path, [
        item for item in denylist
        if item.get("deviceId") != device_id
    ])
PY
}

cleanup() {
  remote_cleanup_device
}
trap cleanup EXIT

resolve_simulator_id() {
  if [[ -n "$SIMULATOR_ID" ]]; then
    printf '%s\n' "$SIMULATOR_ID"
    return
  fi
  local devices
  devices="$(xcrun simctl list devices available)"
  SIMCTL_DEVICES="$devices" python3 - "$SIMULATOR_NAME" <<'PY'
import os
import re
import sys

name = sys.argv[1]
for line in os.environ["SIMCTL_DEVICES"].splitlines():
    if f"{name} (" not in line:
        continue
    match = re.search(r"\(([0-9A-F-]{36})\)", line)
    if match:
        print(match.group(1))
        break
PY
}

remote_ws_connections() {
  ssh "$SHRDLU_SSH" "sudo -n ss -H -tnp state established '( sport = :18800 )' 2>/dev/null || true" |
    awk '{ print $3 " " $4 }' |
    sort
}

extract_new_peers() {
  local before="$1"
  local after="$2"
  local new_count
  new_count="$(comm -13 "$before" "$after" | wc -l | tr -d ' ')"
  [[ "$new_count" -ge 1 ]] || return 1
  comm -13 "$before" "$after" | awk '{ print $2 }'
}

force_tcp_disconnect() {
  local peer="$1"
  local peer_ip="${peer%:*}"
  local peer_port="${peer##*:}"
  [[ -n "$peer_ip" && -n "$peer_port" && "$peer_ip" != "$peer_port" ]] || {
    fail "could not parse peer address '$peer'"
  }
  log "Forcing TCP close for shrdlu:18800 peer $peer_ip:$peer_port"
  ssh "$SHRDLU_SSH" "sudo -n ss -K dst '$peer_ip' dport = :'$peer_port' sport = :18800 >/dev/null"
}

wait_for_snapshot_contains() {
  local needle="$1"
  local label="$2"
  local timeout="${3:-45}"
  try_wait_for_snapshot_contains "$needle" "$label" "$timeout" || {
    fail "timed out waiting for '$needle' in UI snapshot ($ARTIFACT_DIR/snapshot-${label}.txt)"
  }
}

try_wait_for_snapshot_contains() {
  local needle="$1"
  local label="$2"
  local timeout="${3:-45}"
  local deadline=$((SECONDS + timeout))
  local snapshot="$ARTIFACT_DIR/snapshot-${label}.txt"
  while (( SECONDS < deadline )); do
    xcodebuildmcp ui-automation snapshot-ui --simulator-id "$SIMULATOR_ID" >"$snapshot" 2>&1 || true
    if grep -Fq "$needle" "$snapshot"; then
      log "Observed $label"
      return 0
    fi
    sleep 1
  done
  return 1
}

snapshot_has() {
  local needle="$1"
  local label="$2"
  local snapshot="$ARTIFACT_DIR/snapshot-${label}.txt"
  xcodebuildmcp ui-automation snapshot-ui --simulator-id "$SIMULATOR_ID" >"$snapshot" 2>&1 || true
  grep -Fq "$needle" "$snapshot"
}

complete_pairing_flow() {
  log "Completing first-run pairing flow for temporary shrdlu test device"
  xcodebuildmcp ui-automation tap --simulator-id "$SIMULATOR_ID" --id "pairing_name_input" --post-delay 0.5
  xcodebuildmcp ui-automation type-text --simulator-id "$SIMULATOR_ID" --text "clawline ios smoke"
  xcodebuildmcp ui-automation tap --simulator-id "$SIMULATOR_ID" --id "pairing_name_submit" --post-delay 1
  xcodebuildmcp ui-automation tap --simulator-id "$SIMULATOR_ID" --id "pairing_address_input" --post-delay 0.5
  xcodebuildmcp ui-automation type-text --simulator-id "$SIMULATOR_ID" --text "shrdlu:18800"
  xcodebuildmcp ui-automation tap --simulator-id "$SIMULATOR_ID" --id "pairing_address_submit" --post-delay 1
}

wait_for_non_green_send_affordance() {
  local deadline=$((SECONDS + 45))
  local snapshot="$ARTIFACT_DIR/snapshot-disconnected.txt"
  while (( SECONDS < deadline )); do
    xcodebuildmcp ui-automation snapshot-ui --simulator-id "$SIMULATOR_ID" >"$snapshot" 2>&1 || true
    if grep -Fq "Reconnecting" "$snapshot" || grep -Fq "Disconnected. Tap to reconnect." "$snapshot"; then
      if grep -Fq "Send message" "$snapshot"; then
        fail "send affordance still exposes connected Send message label after disconnect ($snapshot)"
      fi
      log "Send affordance is non-green/reconnecting/disconnected"
      return 0
    fi
    sleep 1
  done
  fail "send affordance did not become reconnecting/disconnected ($snapshot)"
}

SIMULATOR_ID="$(resolve_simulator_id)"
[[ -n "$SIMULATOR_ID" ]] || fail "could not resolve simulator '$SIMULATOR_NAME'"
log "Using simulator $SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 1

log "Checking shrdlu provider health"
ssh "$SHRDLU_SSH" "curl -fsS http://127.0.0.1:18800/version >/dev/null"
TOKEN="$(remote_prepare_device_and_token)"
[[ -n "$TOKEN" ]] || fail "failed to create shrdlu test token"

before_connections="$ARTIFACT_DIR/ws-before.txt"
after_connections="$ARTIFACT_DIR/ws-after.txt"
remote_ws_connections >"$before_connections"

log "Building Clawline for simulator"
xcodebuildmcp simulator build \
  --project-path "$PROJECT_PATH" \
  --scheme "$SCHEME" \
  --simulator-id "$SIMULATOR_ID" \
  --use-latest-os

app_path_output="$ARTIFACT_DIR/app-path.json"
xcodebuildmcp simulator get-app-path \
  --project-path "$PROJECT_PATH" \
  --scheme "$SCHEME" \
  --platform "iOS Simulator" \
  --simulator-id "$SIMULATOR_ID" \
  --use-latest-os \
  --output json >"$app_path_output"
APP_PATH="$(python3 - "$app_path_output" <<'PY'
import json, re, sys
text = json.load(open(sys.argv[1]))["content"][0]["text"]
match = re.search(r": (/.*?\.app)", text)
print(match.group(1) if match else "")
PY
)"
[[ -d "$APP_PATH" ]] || fail "could not resolve built app path from $app_path_output"

log "Installing and launching Clawline against shrdlu"
xcodebuildmcp simulator boot --simulator-id "$SIMULATOR_ID" >/dev/null
xcodebuildmcp simulator install --simulator-id "$SIMULATOR_ID" --app-path "$APP_PATH"
xcrun simctl terminate "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true
if [[ "$RESET_SIM_KEYCHAIN" == "1" ]]; then
  xcrun simctl keychain "$SIMULATOR_ID" reset
fi
xcrun simctl spawn "$SIMULATOR_ID" defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl spawn "$SIMULATOR_ID" defaults write "$BUNDLE_ID" auth.token "$TOKEN"
xcrun simctl spawn "$SIMULATOR_ID" defaults write "$BUNDLE_ID" auth.userId "$TEST_USER_ID"
xcrun simctl spawn "$SIMULATOR_ID" defaults write "$BUNDLE_ID" auth.isAdmin -bool false
xcrun simctl spawn "$SIMULATOR_ID" defaults write "$BUNDLE_ID" clawline.deviceId "$TEST_DEVICE_ID"
xcrun simctl spawn "$SIMULATOR_ID" defaults write "$BUNDLE_ID" provider.baseURL "$SHRDLU_PROVIDER_URL"
SIMCTL_CHILD_CLAWLINE_DEVICE_ID="$TEST_DEVICE_ID" \
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" >/dev/null

if ! try_wait_for_snapshot_contains "Send message" "connected-send-affordance-initial" 10; then
  if snapshot_has "Connect to get started" "pairing-visible"; then
    complete_pairing_flow
  fi
fi
wait_for_snapshot_contains "Send message" "connected-send-affordance"
remote_ws_connections >"$after_connections"
peers="$(extract_new_peers "$before_connections" "$after_connections" || true)"
[[ -n "$peers" ]] || {
  log "Before connections:"
  cat "$before_connections"
  log "After connections:"
  cat "$after_connections"
  fail "expected at least one new shrdlu:18800 connection"
}

xcodebuildmcp ui-automation tap --simulator-id "$SIMULATOR_ID" --id "prompt_input" --post-delay 0.5
xcodebuildmcp ui-automation type-text --simulator-id "$SIMULATOR_ID" --text "$DRAFT_TEXT"
wait_for_snapshot_contains "Send message" "draft-ready-send-affordance"

remote_ws_connections >"$after_connections"
peers="$(extract_new_peers "$before_connections" "$after_connections" || true)"
[[ -n "$peers" ]] || fail "expected at least one active shrdlu:18800 connection before disconnect"
log "Forcing TCP close for active shrdlu peers: $(printf '%s' "$peers" | tr '\n' ' ')"
for peer in $peers; do
  [[ -n "$peer" ]] || continue
  force_tcp_disconnect "$peer"
done
wait_for_non_green_send_affordance

xcodebuildmcp simulator screenshot --simulator-id "$SIMULATOR_ID" --return-format path >"$ARTIFACT_DIR/final-screenshot.txt" 2>&1 || true
log "PASS. Artifacts: $ARTIFACT_DIR"
