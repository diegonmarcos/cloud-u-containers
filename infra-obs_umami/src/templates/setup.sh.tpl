#!/bin/sh
# Umami declarative setup — runs once after first deploy
# Configures admin credentials + creates website
# Idempotency: if /output/site_id exists and is non-empty, we've already run
# successfully. Exit 0 (no-op) so repeated compose-up cycles don't fail.
set -e

UMAMI_URL="http://localhost:@PORT@"
STATE_FILE="/output/site_id"

# ── Idempotency guard ─────────────────────────────────────────────
# The umami_config named volume persists /output across container recreations.
# If we already have a site_id, the job is DONE — don't try to re-auth.
# This handles the "oneshot" case declaratively: first run writes the file,
# all subsequent runs short-circuit here without touching the Umami API.
if [ -s "$STATE_FILE" ]; then
  EXISTING_ID=$(cat "$STATE_FILE")
  # ...unless the marker is the POISON value. The auth-failure path below used
  # to write the literal string "unknown" here and exit 0, which permanently
  # satisfied this guard: setup then short-circuited on every subsequent run
  # forever, so a website that was never created could never be created, and
  # every ship reported success. A marker that records "we gave up" is not
  # evidence of a completed setup — treat it as unconfigured and try again.
  if [ "$EXISTING_ID" = "unknown" ]; then
    echo "[umami-setup] state=$STATE_FILE holds the give-up marker 'unknown' — NOT treating that as configured; retrying setup."
  else
    echo "[umami-setup] Already configured (site_id=$EXISTING_ID, state=$STATE_FILE). Skipping."
    echo "[umami-setup] SUMMARY revision=${SHIP_REVISION:-unknown} outcome=already-configured site_id=$EXISTING_ID"
    exit 0
  fi
fi

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

# Escape a value for use inside a JSON string: backslash first, then double
# quote, matching what `jq -n --arg` produced. Verified char-for-char against
# jq inside the real curlimages/curl image (busybox awk supports split with an
# empty separator).
json_escape() {
  printf '%s' "$1" | awk '
    BEGIN { RS = "\0" }
    {
      n = split($0, ch, "")
      out = ""
      for (i = 1; i <= n; i++) {
        c = ch[i]
        if (c == "\\")      out = out "\\" "\\"
        else if (c == "\"") out = out "\\" "\""
        else                out = out c
      }
      printf "%s", out
    }'
}

# Build a two-field JSON object without jq. The setup container is
# curlimages/curl, which ships curl but NOT jq, so every `jq -nc` call here
# died with "jq: not found", curl posted an EMPTY body, and the empty response
# that came back was reported as outcome=auth-failed — i.e. the configured
# credentials were never actually tried. Umami therefore never got a tracking
# site created and collected nothing, while the failure named the wrong cause.
json_obj2() {
  printf '{"%s":"%s","%s":"%s"}' \
    "$1" "$(json_escape "$2")" "$3" "$(json_escape "$4")"
}

echo "[umami-setup] Starting..."

# Login with default credentials (admin/umami)
echo "[umami-setup] Attempting default login..."
RESP=$(curl -sf "$UMAMI_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"umami"}' 2>/dev/null || echo "")
TOKEN=$(json_val "$RESP" "token")

if [ -z "$TOKEN" ]; then
  # Default login failed — try configured credentials.
  # Body built via json_obj2 so an ADMIN_PASSWORD containing " or \ doesn't
  # break JSON. Never shell-interpolate secrets into JSON strings.
  echo "[umami-setup] Default login failed, trying configured credentials..."
  RESP=$(json_obj2 username admin password "$ADMIN_PASSWORD" \
    | curl -sf "$UMAMI_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null || echo "")
  TOKEN=$(json_val "$RESP" "token")

  if [ -z "$TOKEN" ]; then
    # Neither default nor configured password works. "Admin likely exists with
    # an external password" was a GUESS, and the code acted on it by writing
    # a "done" marker and exiting 0 — so an Umami that was simply not up yet,
    # or a password that never got injected, was recorded as a completed setup
    # forever and shipped green. We genuinely cannot tell those apart from
    # here, and the honest answer to "I could not authenticate" is a failure,
    # not a marker. No poison marker is written: the next run gets to try
    # again with whatever the operator fixed.
    echo "[umami-setup] ERROR: cannot authenticate with the default OR the configured password." >&2
    echo "[umami-setup]   → either Umami is not ready, or ADMIN_PASSWORD does not match the admin account." >&2
    echo "[umami-setup]   → NOT writing a 'done' marker; that is what made this state permanent and invisible." >&2
    echo "[umami-setup] SUMMARY revision=${SHIP_REVISION:-unknown} outcome=auth-failed site_id= configured=0"
    exit 1
  fi
  echo "[umami-setup] Already configured, verifying website..."
else
  # Change admin password — body via json_obj2 (JSON-safe).
  echo "[umami-setup] Changing admin password..."
  json_obj2 currentPassword umami newPassword "$ADMIN_PASSWORD" \
    | curl -sf "$UMAMI_URL/api/me/password" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d @- >/dev/null

  # Re-login with new password (username stays 'admin')
  RESP=$(json_obj2 username admin password "$ADMIN_PASSWORD" \
    | curl -sf "$UMAMI_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d @- 2>/dev/null || echo "")
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

# Write SITE_ID to persistent volume for declarative retrieval.
# An empty SITE_ID means the lookup found nothing and the create returned
# nothing — writing that would leave an empty marker (which the -s guard above
# correctly ignores) plus an analytics.json advertising a website id of "".
# Fail instead: this script exists to produce a site id.
if [ -z "$SITE_ID" ]; then
  echo "[umami-setup] ERROR: no website id — neither found nor created for diegonmarcos.com." >&2
  echo "[umami-setup] SUMMARY revision=${SHIP_REVISION:-unknown} outcome=no-site-id site_id= configured=0"
  exit 1
fi

# ── Verify the site exists before recording it ─────────────────────
# A durable marker that points at a website Umami does not serve back is
# exactly the hollow "configured but nothing collected" state this job
# exists to prevent. Re-fetch the site by id and confirm the API returns
# it before we write a record claiming setup is complete.
# The Authorization header here carried the literal string "Bearer ***" —
# a log line with GitHub secret-masking applied, pasted back into the source
# when this verification step was written (d2b1f13e). Umami answered 401 to
# it every time, curl -sf therefore exited non-zero, VERIFY came back empty
# and the grep below could NEVER match. The step could not pass, so setup
# exited 1 on every run and the marker was never written, while auth had in
# fact succeeded and the website had existed since 2026-03-17
# (site_id 937cbde7-..., 1131 events recorded, newest 2026-09-24 13:07Z).
# A verifier that cannot pass reports the subject broken forever: #396 read
# as "no tracking site has ever existed" when the truth was one masked token.
VERIFY=$(curl -sf "$UMAMI_URL/api/websites/$SITE_ID" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null || echo "")
if ! printf '%s' "$VERIFY" | grep -q "$SITE_ID"; then
  echo "[umami-setup] ERROR: site_id=$SITE_ID not confirmed by the API — NOT writing a configured marker." >&2
  echo "[umami-setup] SUMMARY revision=${SHIP_REVISION:-unknown} outcome=site-unverified site_id=$SITE_ID configured=0"
  exit 1
fi
echo "[umami-setup] Site verified via the API: $SITE_ID"

echo "$SITE_ID" > /output/site_id
echo "{\"umami_site_id\":\"$SITE_ID\",\"umami_url\":\"https://@DOMAIN@\"}" > /output/analytics.json

echo ""
echo "========================================="
echo "  Umami Setup Complete"
echo "  Login:      https://@DOMAIN@"
echo "  User:       admin"
echo "  Website ID: $SITE_ID"
echo "  Config:     /output/analytics.json"
echo "========================================="
echo "[umami-setup] SUMMARY revision=${SHIP_REVISION:-unknown} outcome=configured site_id=$SITE_ID configured=1"
