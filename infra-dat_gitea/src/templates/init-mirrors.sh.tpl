#!/usr/bin/env bash
# Bootstrap Gitea admin + converge mirror repos
# Source: build.json .gitea.mirrors + .gitea.mirror_policy.exclude + secrets.yaml
# Run: automatically, as the ship engine's compose post-hook — declared in
#      build.json .compose.post_hook = "configs/init-mirrors.sh". The engine
#      wipes <DEPLOY_PATH>/.posthook-receipt, runs this script, and writes a
#      revision-scoped token there only if it exits 0, so a hook that did not
#      run cannot report green. The header used to claim "container-init calls
#      this"; nothing did. No systemd unit, cron entry, compose hook or ship
#      step referenced it, the deploy only COPIED it, and the mirror set only
#      ever moved when somebody ran it by hand.
# Idempotent: safe to run multiple times
#
# PRIVATE mirrors need auth_token in the migrate payload (anonymous clone of
# a private repo yields a bare/empty mirror). Read at runtime from the
# GITHUB_MIRROR_TOKEN env var — populate it by adding a GITHUB_MIRROR_TOKEN
# key (fine-grained GitHub PAT, contents:read, scoped to the mirrored repos)
# to a_solutions/infra-dat_gitea/src/secrets.yaml via:
#   sops a_solutions/infra-dat_gitea/src/secrets.yaml
# then re-run `build.sh build && build.sh ship` (never edit dist/ directly).
# Absent that key, each private mirror WARNs and falls back to the previous
# anonymous-clone behaviour — nothing regresses, the gap just stays visible.
# That token is offered ONLY to the repos in the migrate block below, which is
# the derived inventory MINUS mirror_policy.exclude, and excluded repos are
# actively DELETED from Gitea by step 3.5 before any migrate is attempted —
# so adding it cannot sweep an excluded repo in through an orphan mirror.
set -uo pipefail
API="http://localhost:@PORT_HTTP@/api/v1"
CONTAINER="@CONTAINER_NAME@"

# ── Secrets ───────────────────────────────────────────────────────────
# Sourced, not inherited. The post-hook is invoked as
#   cd <DEPLOY_PATH> && ./configs/init-mirrors.sh
# with no environment of its own, so GITEA_ADMIN_* (and the optional
# GITHUB_MIRROR_TOKEN) have to be read from the dotenv the same deploy just
# wrote one directory up. Missing values are fatal here rather than three
# steps later as an opaque 401 from the token endpoint.
SECRETS_ENV="$(cd "$(dirname "$0")/.." && pwd)/.secrets"
if [ -f "$SECRETS_ENV" ]; then
  set -a; . "$SECRETS_ENV"; set +a
fi
for _required in GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL; do
  eval "_required_value=\${$_required:-}"
  if [ -z "$_required_value" ]; then
    echo "[init-mirrors] FAILED: $_required is unset (looked in $SECRETS_ENV)" >&2
    exit 1
  fi
done

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

# Step 3: Ensure the mirror OWNER exists
# The create used to discard its exit status (no `set -e` in this script), so a
# failure here was invisible — and it is not survivable: every repo below is
# created under this owner, so all 29 would then fail one by one.
#
# The owner may be a USER or an ORG, and here it is a user: @ORG@ is the same
# name as GITEA_ADMIN_USER created in step 1, so `GET /orgs/@ORG@` answers 404
# and `POST /orgs` then fails on the username collision. Checking only the org
# endpoint therefore turned a healthy instance into a hard `exit 1` before a
# single mirror was attempted — which is why 14 declared mirrors, among them
# cloud-u-containers, were silently absent while 17 pre-existing ones kept
# syncing. `/users/<name>` is checked first because that is what this deployment
# actually is; the org branch stays for a fresh instance where neither exists.
echo "-- Converging Gitea mirrors --"
if api "$API/users/@ORG@" >/dev/null 2>&1; then
  echo "Owner @ORG@ exists (user)"
elif api "$API/orgs/@ORG@" >/dev/null 2>&1; then
  echo "Owner @ORG@ exists (org)"
else
  echo "Creating org: @ORG@"
  if ! api -X POST "$API/orgs" -d '{"username":"@ORG@","visibility":"public"}' >/dev/null; then
    echo "  FAIL: could not create owner @ORG@ — no mirror can be created without it" >&2
    exit 1
  fi
fi

# Step 3.5: Enforce mirror_policy.exclude by REMOVAL, not just by omission
# The exclusion used to be applied only in the deriver, which drops the repo
# from the migrate block below — i.e. it prevented CREATION and nothing else.
# `diego/cloud-vault` was mirrored before the exclusion existed and simply
# stayed, so the credential store had a mirror in Gitea for months while the
# policy declaring it must not read as satisfied. It was harmless only because
# it was empty (private upstream, no GITHUB_MIRROR_TOKEN, anonymous clone) —
# and the WARN below actively instructs an operator to add that token, which
# is what would have started filling it.
#
# A policy that only guards creation silently fails after any manual action,
# and there was proof of exactly that. So the exclusion is now converged like
# everything else: present → deleted, absent → nothing. This runs BEFORE any
# migrate, so the excluded set is gone before a token is ever offered.
echo "-- Enforcing mirror_policy.exclude --"
@EXCLUDE_BLOCK@
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
MIRRORS_REMOVED=$(tally_count mirrors_removed)
MIRRORS_REMOVE_FAILED=$(tally_count mirrors_remove_failed)
echo "[init-mirrors] SUMMARY revision=${SHIP_REVISION:-unknown} org=@ORG@ mirrors_created=$MIRRORS_CREATED mirrors_exists=$MIRRORS_EXISTS mirrors_failed=$MIRRORS_FAILED mirrors_degraded=$MIRRORS_DEGRADED mirrors_removed=$MIRRORS_REMOVED mirrors_remove_failed=$MIRRORS_REMOVE_FAILED"

# An excluded repo that is still present is the exact failure this step exists
# to prevent, so it is fatal — unlike `degraded`, there is no missing PAT to
# wait on and no policy question to settle.
if [ "$MIRRORS_REMOVE_FAILED" -gt 0 ]; then
  echo "[init-mirrors] FAILED: $MIRRORS_REMOVE_FAILED excluded repo(s) still exist in Gitea:" >&2
  sed 's|^|[init-mirrors]   |' "$TALLY_DIR/mirrors_remove_failed" >&2
  exit 1
fi
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
