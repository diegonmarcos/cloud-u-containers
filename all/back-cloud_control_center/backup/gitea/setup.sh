#!/bin/bash
# Setup Gitea and create mirror repos
# Run on flex VM after docker-compose up

set -e

GITEA_URL="http://localhost:3000"
GITEA_USER="diego"
GITEA_PASS="ogeid2B@"
GITHUB_USER="diegonmarcos"

# Wait for Gitea to be ready
echo "Waiting for Gitea..."
until curl -s "$GITEA_URL" > /dev/null; do
    sleep 2
done

echo "Gitea is up!"

# Create admin user (first run only)
docker exec gitea gitea admin user create \
    --username "$GITEA_USER" \
    --password "$GITEA_PASS" \
    --email "me@diegonmarcos.com" \
    --admin 2>/dev/null || echo "User already exists"

# Get API token
TOKEN=$(curl -s -X POST "$GITEA_URL/api/v1/users/$GITEA_USER/tokens" \
    -u "$GITEA_USER:$GITEA_PASS" \
    -H "Content-Type: application/json" \
    -d '{"name":"backup-script","scopes":["repo"]}' | jq -r '.sha1')

if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
    echo "Using existing token or password auth"
    AUTH="-u $GITEA_USER:$GITEA_PASS"
else
    echo "Token created: $TOKEN"
    AUTH="-H \"Authorization: token $TOKEN\""
fi

# Repos to mirror from GitHub
REPOS=(
    "cloud"
    "front"
    "unix"
    "vault"
)

echo ""
echo "Creating mirror repos..."
for repo in "${REPOS[@]}"; do
    echo "  Mirroring: $repo"

    curl -s -X POST "$GITEA_URL/api/v1/repos/migrate" \
        -u "$GITEA_USER:$GITEA_PASS" \
        -H "Content-Type: application/json" \
        -d "{
            \"clone_addr\": \"https://github.com/$GITHUB_USER/$repo.git\",
            \"repo_name\": \"$repo\",
            \"mirror\": true,
            \"mirror_interval\": \"1h\",
            \"private\": true
        }" 2>/dev/null || echo "    (already exists or error)"
done

echo ""
echo "=== Gitea Setup Complete ==="
echo ""
echo "Web UI:  http://144.24.196.72:3000"
echo "SSH:     ssh://git@144.24.196.72:2222"
echo "User:    $GITEA_USER"
echo ""
echo "Mirrors will sync every hour automatically."
