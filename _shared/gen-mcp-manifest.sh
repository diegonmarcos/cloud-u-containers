#!/usr/bin/env bash
# gen-mcp-manifest.sh — emit the declared MCP endpoint list as JSON.
#
# Source of truth: every solution's build.json that declares a streaming proxy
# on the MCP hub (proxy.primary.streaming + parent_domain, or a container-level
# proxy.streaming on that parent_domain). Output: _shared/mcp-manifest.json,
# consumed by cloud-infra's caddy generator (cloud-data-config-derive.ts) to set
# each endpoint's access. No hand-maintained MCP list: add a build.json
# declaration and re-run.
#
# Access policy (url-scheme.md): every MCP is PUBLIC with TOKEN auth — reachable
# off-mesh only with a valid Authelia-issued bearer token (WG peers pass
# straight through); never mesh-only. Encoded once here, below.
#
# Usage: gen-mcp-manifest.sh [--check]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/_shared/mcp-manifest.json"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
cd "$ROOT"
for f in */build.json; do
  case "$f" in z_archive/*|_*) continue ;; esac
  jq -c --arg dir "$(dirname "$f")" '
    def ep($n; $p; $src): select($p.streaming == true and ($p.base_path // "") != "" and $p.parent_domain == "mcp.diegonmarcos.com")
      | {name: $n, folder: $dir, base_path: $p.base_path, parent_domain: $p.parent_domain, source: $src};
    ( ep(.name; (.proxy.primary // {}); "proxy.primary") ),
    ( .name as $svc | (.containers // {}) | to_entries[]
        | ep(($svc + (if .key=="app" then "" else "-" + .key end)); (.value.proxy // {}); "containers." + .key) )
  ' "$f"
done | jq -s '
  # a container-level entry repeating the primary base_path is the same endpoint
  (group_by(.base_path) | map(.[0])) as $eps
  | {
    _generated_by: "_shared/gen-mcp-manifest.sh",
    _doc: "GENERATED. Declared MCP endpoints on the MCP hub, from each solution build.json. Do not edit; change the build.json and re-run the generator.",
    schema: "mcp-manifest/v1",
    access: "token",
    mcps: ($eps | map(. + {auth: "token", public: true}) | sort_by(.base_path))
  }' > "$tmp"
if [ "${1:-}" = "--check" ]; then
  cmp -s "$tmp" "$OUT" || { echo "mcp-manifest.json is stale; run $0" >&2; exit 1; }
  echo "mcp-manifest.json up to date"; exit 0
fi
cp "$tmp" "$OUT"; echo "wrote $OUT ($(jq '.mcps|length' "$OUT") MCPs)"
