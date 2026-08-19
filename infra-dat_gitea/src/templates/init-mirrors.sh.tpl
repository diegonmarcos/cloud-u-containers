#!/usr/bin/env bash
# Bootstrap Gitea admin + converge mirror repos
# Source: build.json .gitea.mirrors + secrets.yaml
# Run: after container is healthy (container-init calls this)
# Idempotent: safe to run multiple times
#
# PRIVATE mirrors need auth_token in the migrate payload (anonymous clone of
# a private repo yields a bare/empty mirror). Read at runtime from the
# GITHUB_MIRROR_TOKEN env var — populate it by adding a GITHUB_MIRROR_TOKEN
# key (fine-grained GitHub PAT, repo:read, scoped to the private repos) to
# a_solutions/infra-dat_gitea/src/secrets.yaml via:
#   sops a_solutions/infra-dat_gitea/src/secrets.yaml
# then re-run `build.sh build && build.sh ship` (never edit dist/ directly).
# Absent that key, each private mirror WARNs and falls back to the previous
# anonymous-clone behaviour — nothing regresses, the gap just stays visible.
set -uo pipefail
API="http://localhost:@PORT_HTTP@/api/v1"
CONTAINER="@CONTAINER_NAME@"

# Step 1: Create admin user (idempotent)
echo "-- Bootstrapping admin user --"
docker exec "$CONTAINER" gitea admin user create \
  --username "${GITEA_ADMIN_USER}" \
  --password "${GITEA_ADMIN_PASSWORD}" \
  --email "${GITEA_ADMIN_EMAIL}" \
  --admin \
  --must-change-password=false 2>&1 | grep -v "already exists" || true

# Step 2: Get or create API token
echo "-- Obtaining API token --"
TOKEN_FILE="/opt/containers/gitea/.gitea-token"
if [ -f "$TOKEN_FILE" ]; then
  TOKEN=$(cat "$TOKEN_FILE")
else
  TOKEN=$(curl -sf -X POST "$API/users/${GITEA_ADMIN_USER}/tokens" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"name":"init-mirrors","scopes":["all"]}' | jq -r '.sha1') || true
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    echo "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "  Token created and saved"
  else
    echo "  FAIL: could not create token"
    exit 1
  fi
fi

api() { curl -sf -H "Authorization: token $TOKEN" -H "Content-Type: application/json" "$@"; }

# Step 3: Ensure org exists
echo "-- Converging Gitea mirrors --"
if ! api "$API/orgs/@ORG@" >/dev/null 2>&1; then
  echo "Creating org: @ORG@"
  api -X POST "$API/orgs" -d '{"username":"@ORG@","visibility":"public"}' >/dev/null
fi

# Step 4: Ensure each mirror repo exists
@MIRROR_BLOCK@

echo "-- Done --"
