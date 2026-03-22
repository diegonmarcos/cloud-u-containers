#!/bin/sh
# Hickory DNS init — fetch zones from C3 API if missing
# Runs as compose pre_hook before docker compose up
set -e
cd "$(dirname "$0")"
CONFIG_DIR="./config"
ZONES_DIR="$CONFIG_DIR/zones"
NAMED_TOML="$CONFIG_DIR/named.toml"
REPO_RAW="https://raw.githubusercontent.com/diegonmarcos/cloud/main/cloud-data/cloud-data-dns-services.json"
C3_API="https://api.diegonmarcos.com/c3-api"
SUFFIX="app"
LISTEN_IP="10.0.0.1"

# If zones already exist, skip
if [ -f "$NAMED_TOML" ] && [ -d "$ZONES_DIR" ]; then
  ZONE_COUNT=$(ls "$ZONES_DIR"/*.zone 2>/dev/null | wc -l)
  if [ "$ZONE_COUNT" -gt 0 ]; then
    echo "[init] $ZONE_COUNT zones found — skipping C3 API fetch"
    exit 0
  fi
fi

echo "[init] Zones missing — fetching DNS registry from C3 API..."
mkdir -p "$ZONES_DIR"

# We're bootstrapping Hickory DNS — system DNS (10.0.0.1) may be down.
# Use sudo to temporarily swap resolv.conf to Cloudflare.
SUDO=""
for p in /usr/bin/sudo /run/wrappers/bin/sudo /usr/local/bin/sudo; do
  [ -x "$p" ] && SUDO="$p" && break
done

if [ -n "$SUDO" ]; then
  $SUDO cp /etc/resolv.conf /tmp/resolv.conf.bak 2>/dev/null || true
  printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" | $SUDO tee /etc/resolv.conf >/dev/null 2>/dev/null || true
fi

REGISTRY=$(curl -sf --max-time 15 "$REPO_RAW" 2>/dev/null || echo "")
if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "{}" ]; then
  REGISTRY=$(curl -sf --max-time 10 "$C3_API/dns-registry" 2>/dev/null || echo "")
fi

# Restore original resolv.conf
if [ -n "$SUDO" ] && [ -f /tmp/resolv.conf.bak ]; then
  $SUDO cp /tmp/resolv.conf.bak /etc/resolv.conf 2>/dev/null || true
fi
if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "{}" ]; then
  echo "[init] WARNING: C3 API unreachable — forwarder only"
  cat > "$NAMED_TOML" << 'EOF'
listen_addrs_ipv4 = ["10.0.0.1"]
listen_port = 53
[[zones]]
zone = "."
zone_type = "External"
[zones.stores]
type = "forward"
name_servers = [
  { socket_addr = "1.1.1.1:53", protocol = "udp" },
  { socket_addr = "8.8.8.8:53", protocol = "udp" }
]
EOF
  exit 0
fi

echo "[init] Generating zones from registry..."

# Generate zone files
echo "$REGISTRY" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for name, info in data.get('services', {}).items():
    ip = info.get('ip', '')
    if not ip: continue
    with open(sys.argv[1] + '/' + name + '.${SUFFIX}.zone', 'w') as f:
        f.write('\$ORIGIN ' + name + '.${SUFFIX}.\n\$TTL 60\n')
        f.write('@  IN SOA  hickory-dns.${SUFFIX}. admin.${SUFFIX}. 1 3600 900 604800 60\n')
        f.write('@  IN NS   hickory-dns.${SUFFIX}.\n')
        f.write('@  IN A    ' + ip + '\n')
    print(f'  {name}.${SUFFIX} -> {ip}')
" "$ZONES_DIR" 2>&1 || echo "[init] WARNING: python3 parse failed"

# Generate named.toml from zone files
{
  echo "listen_addrs_ipv4 = [\"$LISTEN_IP\"]"
  echo "listen_port = 53"
  echo ""
  for zf in "$ZONES_DIR"/*.zone; do
    [ -f "$zf" ] || continue
    ZONE_NAME=$(basename "$zf" .zone)
    echo "[[zones]]"
    echo "zone = \"$ZONE_NAME\""
    echo "zone_type = \"Primary\""
    echo ""
    echo "[zones.stores]"
    echo "type = \"file\""
    echo "zone_file_path = \"/etc/zones/$ZONE_NAME.zone\""
    echo ""
  done
  echo "[[zones]]"
  echo "zone = \".\""
  echo "zone_type = \"External\""
  echo ""
  echo "[zones.stores]"
  echo "type = \"forward\""
  echo "name_servers = ["
  echo "  { socket_addr = \"1.1.1.1:53\", protocol = \"tcp\" },"
  echo "  { socket_addr = \"1.1.1.1:53\", protocol = \"udp\" },"
  echo "  { socket_addr = \"8.8.8.8:53\", protocol = \"tcp\" },"
  echo "  { socket_addr = \"8.8.8.8:53\", protocol = \"udp\" }"
  echo "]"
} > "$NAMED_TOML"

ZONE_COUNT=$(ls "$ZONES_DIR"/*.zone 2>/dev/null | wc -l)
echo "[init] Done — $ZONE_COUNT zones generated"
