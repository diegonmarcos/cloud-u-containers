#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ Test: verify build.sh build emits parsers.conf + fluent-bit.conf ║
# ║ as REGULAR FILES (not directories). This is the regression guard ║
# ║ for the H3 bug where docker compose up auto-created the mount    ║
# ║ target paths as directories because the flake never wrote them.  ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Usage: ./build.sh build && src/test-build.sh
# Exit code: 0 = all pass, 1 = any check failed

set -eu

SERVICE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$SERVICE_DIR/dist"

echo "[test] Verifying $DIST/"

fail=0
check_file() {
    name="$1"
    path="$DIST/$name"
    if [ ! -e "$path" ]; then
        echo "FAIL: $name does not exist in dist/"
        fail=1
    elif [ -d "$path" ]; then
        echo "FAIL: $name is a DIRECTORY — docker would bind-mount it wrong"
        fail=1
    elif [ ! -f "$path" ]; then
        echo "FAIL: $name is not a regular file (symlink? socket?)"
        fail=1
    elif [ ! -s "$path" ]; then
        echo "FAIL: $name is empty"
        fail=1
    else
        echo "PASS: $name is a regular non-empty file ($(wc -c < "$path") bytes)"
    fi
}

check_file docker-compose.yml
check_file fluent-bit.conf
check_file parsers.conf

# Parse docker-compose.yml to confirm it mounts from relative paths,
# not from /opt/fluent-bit/ (the broken pattern that caused H3).
if grep -qE '^\s*-\s*/opt/fluent-bit/' "$DIST/docker-compose.yml"; then
    echo "FAIL: docker-compose.yml still mounts from /opt/fluent-bit/ (absolute) — must be ./"
    fail=1
else
    echo "PASS: docker-compose.yml uses relative mount paths"
fi

if grep -qE "^\s*-\s*\./(fluent-bit|parsers)\.conf:" "$DIST/docker-compose.yml"; then
    echo "PASS: docker-compose.yml mounts ./fluent-bit.conf and ./parsers.conf"
else
    echo "FAIL: docker-compose.yml is missing expected ./*.conf mounts"
    fail=1
fi

# Sanity: fluent-bit.conf must reference parsers.conf (side-car file)
if grep -q '^\s*Parsers_File\s*parsers.conf' "$DIST/fluent-bit.conf"; then
    echo "PASS: fluent-bit.conf references parsers.conf"
else
    echo "FAIL: fluent-bit.conf missing 'Parsers_File parsers.conf'"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "[test] ALL CHECKS PASSED"
    exit 0
else
    echo "[test] CHECKS FAILED"
    exit 1
fi
