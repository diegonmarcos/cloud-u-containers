#!/bin/sh
# Hickory DNS init — fetch zones from cloud-data repo if missing
# Runs as compose pre_hook before docker compose up
cd "$(dirname "$0")"
CONFIG_DIR="./config"
ZONES_DIR="$CONFIG_DIR/zones"
NAMED_TOML="$CONFIG_DIR/named.toml"
DNS_JSON="https://raw.githubusercontent.com/diegonmarcos/cloud-data/main/cloud-data-dns-services.json"
SUFFIX="app"
LISTEN_IP="10.0.0.1"

# If zones already exist, skip
# Regenerate if: zones missing, OR init.sh is newer than named.toml (new deploy)
if [ -f "$NAMED_TOML" ] && [ -d "$ZONES_DIR" ] && [ ! ./init.sh -nt "$NAMED_TOML" ]; then
  ZONE_COUNT=$(ls "$ZONES_DIR"/*.zone 2>/dev/null | wc -l)
  if [ "$ZONE_COUNT" -gt 0 ]; then
    echo "[init] $ZONE_COUNT zones found, init.sh unchanged — skipping"
    exit 0
  fi
fi

echo "[init] Regenerating zones from cloud-data repo..."
rm -rf "$ZONES_DIR"
mkdir -p "$ZONES_DIR"

# Remove stale Docker directory mount
if [ -d "$NAMED_TOML" ]; then
  rm -rf "$NAMED_TOML"
fi
docker compose down 2>/dev/null || true

# Fetch — use Cloudflare DNS since Hickory (what we're bootstrapping) is down
REGISTRY=$(curl -sf --max-time 15 --dns-servers 1.1.1.1 "$DNS_JSON" 2>/dev/null || \
           curl -sf --max-time 15 "$DNS_JSON" 2>/dev/null || echo "")

if [ -z "$REGISTRY" ] || [ "$REGISTRY" = "{}" ]; then
  echo "[init] WARNING: fetch failed — forwarder only"
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

echo "[init] Generating zones..."

# Parse with jq, generate zone files
PAIRS="/tmp/hickory-dns-pairs.txt"
echo "$REGISTRY" | jq -r '.services | to_entries[] | select(.value.ip) | "\(.key) \(.value.ip)"' > "$PAIRS" 2>/dev/null || true
while read -r name ip; do
  [ -z "$name" ] || [ -z "$ip" ] && continue
  cat > "$ZONES_DIR/${name}.${SUFFIX}.zone" << ZONE
\$ORIGIN ${name}.${SUFFIX}.
\$TTL 60
@  IN SOA  hickory-dns.${SUFFIX}. admin.${SUFFIX}. 1 3600 900 604800 60
@  IN NS   hickory-dns.${SUFFIX}.
@  IN A    ${ip}
ZONE
done < "$PAIRS"
rm -f "$PAIRS"

# Generate named.toml
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
