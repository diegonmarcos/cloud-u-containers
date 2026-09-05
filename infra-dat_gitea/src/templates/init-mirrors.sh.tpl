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

# ── Per-repo outcome accounting ───────────────────────────────────────
# Every mirror used to be provisioned as
#   api -X POST ... && echo "  OK <repo>" || echo "  FAIL <repo>"
# which prints FAIL and exits 0. Twenty-nine repos could fail to migrate and
# this script still reported success — the same silent-skip class that left
# four declared mail accounts non-existent for a day while the MX accepted
# their mail. Counts live in FILES rather than shell variables because a
# variable incremented inside a pipeline or command-substitution subshell is
# discarded on subshell exit, which is exactly how a loop counts failures and
# then reports none.
TALLY_DIR=$(mktemp -d /tmp/.gitea-init-mirrors-tally.XXXXXX)
trap 'rm -rf "$TALLY_DIR"' EXIT
tally()       { echo "$2" >> "$TALLY_DIR/$1"; }
tally_count() { _c=$(cat "$TALLY_DIR/$1" 2>/dev/null | wc -l | tr -d ' '); echo "${_c:-0}"; }

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
# The create used to discard its exit status (no `set -e` in this script), so a
# failure here was invisible — and it is not survivable: every repo below is
# created under this org, so all 29 would then fail one by one.
echo "-- Converging Gitea mirrors --"
if ! api "$API/orgs/@ORG@" >/dev/null 2>&1; then
  echo "Creating org: @ORG@"
  if ! api -X POST "$API/orgs" -d '{"username":"@ORG@","visibility":"public"}' >/dev/null; then
    echo "  FAIL: could not create org @ORG@ — no mirror can be created without it" >&2
    exit 1
  fi
fi

# Step 4: Ensure each mirror repo exists
@MIRROR_BLOCK@

# ── Verdict ───────────────────────────────────────────────────────────
# One machine-readable line, then the exit code.
#
# `degraded` is reported but NOT fatal: a private repo with no
# GITHUB_MIRROR_TOKEN yields an empty mirror, which is a known, documented gap
# with a known remedy (add the key to secrets.yaml). Failing on it would block
# every Gitea ship on a PAT nobody has generated yet — a policy change, not a
# bug fix. It is counted and named so the gap stays visible instead of scrolling
# past as one WARN among 29 lines.
MIRRORS_CREATED=$(tally_count mirrors_created)
MIRRORS_EXISTS=$(tally_count mirrors_exists)
MIRRORS_FAILED=$(tally_count mirrors_failed)
MIRRORS_DEGRADED=$(tally_count mirrors_degraded)
echo "[init-mirrors] SUMMARY revision=${SHIP_REVISION:-unknown} org=@ORG@ mirrors_created=$MIRRORS_CREATED mirrors_exists=$MIRRORS_EXISTS mirrors_failed=$MIRRORS_FAILED mirrors_degraded=$MIRRORS_DEGRADED"

if [ "$MIRRORS_FAILED" -gt 0 ]; then
  echo "[init-mirrors] FAILED: $MIRRORS_FAILED mirror(s) did not converge:" >&2
  sed 's|^|[init-mirrors]   |' "$TALLY_DIR/mirrors_failed" >&2
  exit 1
fi
if [ "$((MIRRORS_CREATED + MIRRORS_EXISTS))" = 0 ]; then
  # A converge that converged nothing is not a success.
  echo "[init-mirrors] FAILED: not one mirror exists or was created — this script ran but did nothing" >&2
  exit 1
fi

echo "-- Done --"
