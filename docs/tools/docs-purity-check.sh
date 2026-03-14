#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/Users/mike/shared-workspace/clawline}"
cd "$ROOT"

TARGETS=( *.md specs/*.md )
DENY_PATHS_FILE=".docs-purity-deny-paths.txt"
DENY_FILES_FILE=".docs-purity-deny-files.txt"
ALLOW_EXCEPTIONS_FILE=".docs-purity-allow-exceptions.txt"

fail=0

[[ -f "$DENY_PATHS_FILE" ]] || { echo "[docs-purity] missing $DENY_PATHS_FILE"; exit 1; }
[[ -f "$DENY_FILES_FILE" ]] || { echo "[docs-purity] missing $DENY_FILES_FILE"; exit 1; }
[[ -f "$ALLOW_EXCEPTIONS_FILE" ]] || { echo "[docs-purity] missing $ALLOW_EXCEPTIONS_FILE"; exit 1; }

# Build grep exclude args from allowlist
EXCLUDES=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  EXCLUDES+=("--exclude=$f")
done < "$ALLOW_EXCEPTIONS_FILE"

# Build regex from deny-path list
DENY_REGEX=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  if [[ -z "$DENY_REGEX" ]]; then
    DENY_REGEX="$(printf '%s' "$p" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  else
    DENY_REGEX+="|$(printf '%s' "$p" | sed 's/[.[\*^$()+?{|]/\\&/g')"
  fi
done < "$DENY_PATHS_FILE"

echo "[docs-purity] checking forbidden path references..."
if grep -RInE "$DENY_REGEX" "${EXCLUDES[@]}" -- ${TARGETS[@]} >/tmp/docs_purity_forbidden.txt 2>/dev/null; then
  echo "[docs-purity] FAIL: forbidden references found"
  cat /tmp/docs_purity_forbidden.txt
  fail=1
else
  echo "[docs-purity] ok"
fi

echo "[docs-purity] checking disallowed docs are absent..."
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ -e "$f" ]]; then
    echo "[docs-purity] FAIL: disallowed doc present: $f"
    fail=1
  fi
done < "$DENY_FILES_FILE"

if [[ $fail -eq 0 ]]; then
  echo "[docs-purity] PASS"
else
  exit 1
fi
