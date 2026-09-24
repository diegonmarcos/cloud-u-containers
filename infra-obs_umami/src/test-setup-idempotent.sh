#!/bin/sh
# Test: umami-setup is idempotent when /output/site_id already exists.
# Runs setup.sh twice in a temp sandbox and verifies:
#   - First call: writes the marker file (simulated, since there's no Umami API here)
#   - Second call: short-circuits with exit 0 and the "Already configured" message
#
# Usage: ./test-setup-idempotent.sh
# Expected: exits 0 on success, non-zero on failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# dist layout v2 (2026-04): setup.sh lives under dist/configs/
# Keep legacy dist/setup.sh as a fallback for older builds.
if   [ -f "$SCRIPT_DIR/../dist/configs/setup.sh" ]; then
    DIST_SETUP="$SCRIPT_DIR/../dist/configs/setup.sh"
elif [ -f "$SCRIPT_DIR/../dist/setup.sh" ]; then
    DIST_SETUP="$SCRIPT_DIR/../dist/setup.sh"
else
    echo "FAIL: no dist setup.sh found — run build.sh build first"
    exit 2
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Simulate the /output named volume with a temp dir. Pre-seed the marker file
# the way a successful first run would.
mkdir -p "$TMPDIR/output"
echo "fake-site-id-abc123" > "$TMPDIR/output/site_id"

# Run setup.sh with STATE_FILE pointing into our temp output dir, bypassing the
# hardcoded /output path by patching on the fly. Simpler: rewrite /output → tmp.
PATCHED="$TMPDIR/setup.sh"
sed "s|/output|$TMPDIR/output|g" "$DIST_SETUP" > "$PATCHED"
chmod +x "$PATCHED"

echo "[test] Running setup.sh with pre-existing marker..."
OUT=$(sh "$PATCHED" 2>&1)
RC=$?

echo "$OUT"

if [ "$RC" -ne 0 ]; then
    echo "FAIL: expected exit 0 when marker exists, got $RC"
    exit 1
fi

if ! echo "$OUT" | grep -q "Already configured"; then
    echo "FAIL: expected 'Already configured' message, got:"
    echo "$OUT"
    exit 1
fi

if ! echo "$OUT" | grep -q "fake-site-id-abc123"; then
    echo "FAIL: expected existing site_id to be echoed"
    exit 1
fi

# Second invariant: with empty state file, guard must NOT trigger.
: > "$TMPDIR/output/site_id"
OUT2=$(sh "$PATCHED" 2>&1 | head -5 || true)
if echo "$OUT2" | grep -q "Already configured"; then
    echo "FAIL: empty state file must not trigger idempotency guard"
    exit 1
fi

# Third invariant: the give-up marker must NOT satisfy the guard. The auth
# failure path used to write the literal "unknown" here and exit 0, which
# made setup short-circuit forever on a site that was never created — and
# every ship reported success.
echo "unknown" > "$TMPDIR/output/site_id"
OUT3=$(sh "$PATCHED" 2>&1 | head -5 || true)
if echo "$OUT3" | grep -q "Already configured"; then
    echo "FAIL: 'unknown' give-up marker must not satisfy the idempotency guard"
    echo "$OUT3"
    exit 1
fi

echo ""
echo "PASS: idempotency guard works correctly"

# ── Fourth invariant: no masked credential literal anywhere ─────────────
# #396: the site-verification step shipped with the header
#     -H "Authorization: Bearer ***"
# — a log line with GitHub's secret masking applied, pasted back into the
# source. Umami answered 401, `curl -sf` exited non-zero, the response was
# empty, and the grep that follows could never match. The verifier could not
# pass, so setup exited 1 on every single run and never wrote the marker,
# while authentication had in fact succeeded and the tracking website had
# existed since 2026-03-17 with events still arriving. #396 was therefore
# read as "no tracking site has ever existed" for months.
#
# Masking renders as three or more asterisks. Any run of them inside the
# built script is a secret that was round-tripped through a log, and such a
# value is never a working credential. Asserted against the BUILT artifact,
# because that is the file the container executes.
# Comment lines are exempt: this file documents the defect by quoting it.
CODE_ONLY=$(grep -vE '^[[:space:]]*#' "$DIST_SETUP")
if printf '%s\n' "$CODE_ONLY" | grep -qE '\*\*\*+'; then
    echo "FAIL: masked-secret literal (***) present in $DIST_SETUP:"
    printf '%s\n' "$CODE_ONLY" | grep -nE '\*\*\*+'
    echo "  A value that came back out of a masked log is not a credential."
    exit 1
fi

# Fifth invariant: every Authorization header uses the token variable.
# Narrower than the asterisk rule above and it survives a different typo —
# a hardcoded token, a stale constant, an empty header. The only legitimate
# bearer value in this script is $TOKEN, obtained from /api/auth/login.
BAD_AUTH=$(grep -n 'Authorization: Bearer' "$DIST_SETUP" \
           | grep -v 'Authorization: Bearer \$TOKEN' || true)
if [ -n "$BAD_AUTH" ]; then
    echo "FAIL: Authorization header not using \$TOKEN in $DIST_SETUP:"
    echo "$BAD_AUTH"
    exit 1
fi

# Sixth invariant: the verification call is actually authenticated. A verify
# step is the last gate before the durable marker is written; if its request
# carries no Authorization header at all it 401s and fails closed forever,
# which is the same outcome as the masked token, reached a different way.
if ! grep -A3 'api/websites/\$SITE_ID' "$DIST_SETUP" | grep -q 'Authorization: Bearer \$TOKEN'; then
    echo "FAIL: the site-verification request to /api/websites/\$SITE_ID"
    echo "      does not carry 'Authorization: Bearer \$TOKEN' within 3 lines."
    echo "      Unauthenticated, it 401s and the marker is never written."
    exit 1
fi

echo "PASS: no masked credential literal, all bearer headers use \$TOKEN,"
echo "      and the site-verification call is authenticated"
