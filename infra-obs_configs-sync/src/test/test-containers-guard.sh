#!/bin/bash
# Guards for the C3 Containers data: every container declares group+category, no overlap, Infra
# category order, and the generated JSON names exactly the containers the build.json files declare.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$(mktemp -d)"; trap 'rm -r "$OUT"' EXIT
node "$HERE/../code/containers-declared.mjs" "$ROOT" "$OUT/c.json"
node "$HERE/../code/containers-guard.mjs" "$ROOT" "$OUT/c.json"
# mutation: a stale name in the served JSON must be caught
jq '.containers += [{"name":"ghost-container"}]' "$OUT/c.json" > "$OUT/stale.json"
if node "$HERE/../code/containers-guard.mjs" "$ROOT" "$OUT/stale.json" 2>/dev/null; then echo "FAIL: stale name not caught"; exit 1; fi
# mutation: a missing container must be caught
jq '.containers |= .[1:]' "$OUT/c.json" > "$OUT/miss.json"
if node "$HERE/../code/containers-guard.mjs" "$ROOT" "$OUT/miss.json" 2>/dev/null; then echo "FAIL: missing name not caught"; exit 1; fi
echo "test-containers-guard: OK"
