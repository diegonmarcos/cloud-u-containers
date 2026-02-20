#!/bin/sh
# Collector: reads JSON data files and generates dashboard.html
# Usage: ./collect.sh
# Outputs: ../dashboard.html
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR"
OUT="$SCRIPT_DIR/../dashboard.html"

# Require node
command -v node >/dev/null 2>&1 || { echo "ERROR: node required"; exit 1; }

node "$SCRIPT_DIR/generate-dashboard.js" \
  "$DATA_DIR/vms.json" \
  "$DATA_DIR/services.json" \
  "$DATA_DIR/security.json" \
  "$DATA_DIR/firewall.json" \
  "$DATA_DIR/docker_ports.json" \
  "$DATA_DIR/dns.json" \
  > "$OUT"

echo "Generated $OUT"
