#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <markdown-file> [more-files...]" >&2
  exit 2
fi

fail=0

for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "[mirror-gate] FAIL $f (missing file)"
    fail=1
    continue
  fi

  header=$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside {print}' "$f")
  if [[ -z "$header" ]]; then
    echo "[mirror-gate] FAIL $f (missing frontmatter)"
    fail=1
    continue
  fi

  doc_type=$(printf '%s\n' "$header" | awk -F': *' '$1=="doc_type"{print $2}' | tr -d '"')
  status=$(printf '%s\n' "$header" | awk -F': *' '$1=="status"{print $2}' | tr -d '"')
  source=$(printf '%s\n' "$header" | awk -F': *' '$1=="source_of_truth"{print $2}' | tr -d '"')

  if [[ "$doc_type" == "contributor" && "$status" == "implemented" && "$source" == "code" ]]; then
    echo "[mirror-gate] PASS $f"
  else
    echo "[mirror-gate] BLOCK $f (doc_type=$doc_type status=$status source_of_truth=$source)"
    fail=1
  fi
done

exit $fail
