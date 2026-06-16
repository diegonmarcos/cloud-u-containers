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

echo ""
echo "PASS: idempotency guard works correctly"
