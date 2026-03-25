#!/bin/sh
# Umami declarative setup — runs once after first deploy
# Configures admin credentials + creates website
set -e

UMAMI_URL="http://localhost:3000"

# Extract JSON field value using awk index() — no sed escaping issues
json_val() {
  echo "$1" | awk -v key="\"$2\":" '{
    i = index($0, key)
    if (i > 0) {
      rest = substr($0, i + length(key))
      if (index(rest, "\"") == 1) {
        rest = substr(rest, 2)
        j = index(rest, "\"")
        if (j > 0) print substr(rest, 1, j - 1)
      }
    }
  }'
}

echo "[umami-setup] Starting..."

# Login with default credentials (admin/umami)
echo "[umami-setup] Attempting default login..."
RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"umami"}' 2>/dev/null || echo "")
TOKEN=$(json_val "$RESP" "token")

if [ -z "$TOKEN" ]; then
  # Default login failed — try configured credentials
  echo "[umami-setup] Default login failed, trying configured credentials..."
  RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "")
  TOKEN=$(json_val "$RESP" "token")

  if [ -z "$TOKEN" ]; then
    echo "[umami-setup] ERROR: Cannot authenticate"
    exit 1
  fi
  echo "[umami-setup] Already configured, verifying website..."
else
  # Change admin password
  echo "[umami-setup] Changing admin password..."
  curl -sf "$UMAMI_URL/api/me/password" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d "{\"currentPassword\":\"umami\",\"newPassword\":\"$ADMIN_PASSWORD\"}" >/dev/null

  # Re-login with new password (username stays 'admin')
  RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" 2>/dev/null || echo "")
  TOKEN=$(json_val "$RESP" "token")
  echo "[umami-setup] Admin password updated"
fi

# Check if website exists
SITES=$(curl -sf "$UMAMI_URL/api/websites" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "")

if echo "$SITES" | grep -q "diegonmarcos.com"; then
  echo "[umami-setup] Website diegonmarcos.com already exists"
  # Extract id from the entry containing diegonmarcos.com
  SITE_ID=$(echo "$SITES" | awk '{
    s = $0
    while (1) {
      i = index(s, "\"id\":\"")
      if (i == 0) break
      s = substr(s, i + 5)
      j = index(s, "\"")
      id = substr(s, 1, j - 1)
      s = substr(s, j + 1)
      if (index(s, "diegonmarcos.com") > 0 && index(s, "diegonmarcos.com") < index(s, "\"id\":\"")) {
        print id; exit
      }
    }
  }')
  # Fallback: just grab first id if domain exists
  [ -z "$SITE_ID" ] && SITE_ID=$(json_val "$SITES" "id")
else
  echo "[umami-setup] Creating website diegonmarcos.com..."
  RESP=$(curl -sf "$UMAMI_URL/api/websites" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"name":"Diego Portfolio","domain":"diegonmarcos.com"}' 2>/dev/null || echo "")
  SITE_ID=$(json_val "$RESP" "id")
fi

# Write SITE_ID to persistent volume for declarative retrieval
echo "$SITE_ID" > /output/site_id
echo "{\"umami_site_id\":\"$SITE_ID\",\"umami_url\":\"https://analytics.diegonmarcos.com/umami\"}" > /output/analytics.json

echo ""
echo "========================================="
echo "  Umami Setup Complete"
echo "  Login:      https://analytics.diegonmarcos.com/umami"
echo "  User:       admin"
echo "  Website ID: $SITE_ID"
echo "  Config:     /output/analytics.json"
echo "========================================="
