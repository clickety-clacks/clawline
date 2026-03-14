#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-/Users/mike/shared-workspace/clawline}"
cd "$ROOT"
python3 - <<'PY'
import hashlib,glob
files=sorted(glob.glob('*.md')+glob.glob('specs/*.md'))
h=hashlib.sha256()
for p in files:
    with open(p,'rb') as f:
        h.update(p.encode()+b'\0')
        h.update(f.read())
print(h.hexdigest())
PY
