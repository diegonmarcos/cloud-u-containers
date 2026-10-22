#!/usr/bin/env bash
# CI driver for the geo-fence guard (#1102): fetch the pinned country database (checksum
# verified), build a Caddy with the same plugins as the edge image, run the guard.
# Needs: nix, go, jq, curl, python3. EDGE_JSON = cloud-infra 1_cloud-configs/dist/build-caddy-edge.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
J="$ROOT/_shared/geo-fence.json"
OUT="${RUNNER_TEMP:-/tmp}/geo-fence-ci"; mkdir -p "$OUT"
curl -fsSL "$(jq -r .db.url "$J")" -o "$OUT/country.mmdb.gz"
echo "$(jq -r .db.sha256 "$J")  $OUT/country.mmdb.gz" | sha256sum -c -
gunzip -c "$OUT/country.mmdb.gz" > "$OUT/country.mmdb"
export PATH="$PATH:$(go env GOPATH)/bin"
command -v xcaddy >/dev/null || go install github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.4
xcaddy build \
  --with github.com/mholt/caddy-l4 \
  --with github.com/mholt/caddy-ratelimit \
  --with github.com/caddy-dns/cloudflare \
  --with "$(jq -r .db.module "$J")" \
  --output "$OUT/caddy"
CADDY="$OUT/caddy" GEO_DB_FILE="$OUT/country.mmdb" bash "$ROOT/_shared/test/geo-fence-guard.sh"
