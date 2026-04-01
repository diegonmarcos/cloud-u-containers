#!/bin/sh
# Hickory DNS init — wildcard *.app zone → Caddy IP
# All .app names resolve to Caddy. Caddy handles per-service routing.
# Runs as compose pre_hook before docker compose up
cd "$(dirname "$0")"
CONFIG_DIR="./config"
ZONES_DIR="$CONFIG_DIR/zones"
NAMED_TOML="$CONFIG_DIR/named.toml"
SUFFIX="app"
CADDY_IP="10.0.0.1"

# If zones already exist and init.sh unchanged, skip
if [ -f "$NAMED_TOML" ] && [ -d "$ZONES_DIR" ] && [ ! ./init.sh -nt "$NAMED_TOML" ]; then
  ZONE_COUNT=$(ls "$ZONES_DIR"/*.zone 2>/dev/null | wc -l)
  if [ "$ZONE_COUNT" -gt 0 ]; then
    echo "[init] zones found, init.sh unchanged — skipping"
    exit 0
  fi
fi

echo "[init] Generating wildcard *.${SUFFIX} zone..."
rm -rf "$ZONES_DIR"
mkdir -p "$ZONES_DIR"

# Remove stale Docker directory mount
if [ -d "$NAMED_TOML" ]; then
  rm -rf "$NAMED_TOML"
fi
docker compose down 2>/dev/null || true

# Resolve listen IP: check if WG interface has Caddy IP
LISTEN_IP="0.0.0.0"
if ip addr show | grep -q "$CADDY_IP"; then
  LISTEN_IP="$CADDY_IP"
  echo "[init] Listen IP: $LISTEN_IP (WG interface up)"
else
  echo "[init] WG interface not ready — binding 0.0.0.0"
fi

# Single wildcard zone: *.app → Caddy IP
cat > "$ZONES_DIR/${SUFFIX}.zone" << ZONE
\$ORIGIN ${SUFFIX}.
\$TTL 60
@    IN SOA  hickory-dns.${SUFFIX}. admin.${SUFFIX}. 1 3600 900 604800 60
@    IN NS   hickory-dns.${SUFFIX}.
@    IN A    ${CADDY_IP}
*    IN A    ${CADDY_IP}
ZONE

# Generate named.toml
cat > "$NAMED_TOML" << EOF
listen_addrs_ipv4 = ["$LISTEN_IP"]
listen_port = 53

[[zones]]
zone = "${SUFFIX}"
zone_type = "Primary"

[zones.stores]
type = "file"
zone_file_path = "/etc/zones/${SUFFIX}.zone"

[[zones]]
zone = "."
zone_type = "External"

[zones.stores]
type = "forward"
name_servers = [
  { socket_addr = "1.1.1.1:53", protocol = "tcp" },
  { socket_addr = "1.1.1.1:53", protocol = "udp" },
  { socket_addr = "8.8.8.8:53", protocol = "tcp" },
  { socket_addr = "8.8.8.8:53", protocol = "udp" }
]
EOF

echo "[init] Done — wildcard *.${SUFFIX} → ${CADDY_IP}"
