#!/usr/bin/env bash
# Test: MADDY_NOREPLY_{USER,PASSWORD} exist in mail-mcp sops secrets
# AND their values are consistent with the canonical source of truth in
# aa-sui_tools-maddy/secrets.yaml (the Maddy account creation side).
#
# This guards against drift — if Maddy's NOREPLY_PASSWORD is rotated, this
# test FAILS until mail-mcp's copy is updated.
#
# Usage: ./test-noreply-secret.sh
# Expected: exits 0 on success.

set -euo pipefail

ROOT="/home/diego/git/cloud-infra/a_solutions"
MADDY_SECRETS="$ROOT/aa-sui_tools-maddy/src/secrets.yaml"
MAIL_MCP_SECRETS="$ROOT/aa-sui_mail-mcp/src/secrets.yaml"
C3_MCP_SECRETS="$ROOT/bc-obs_c3-infra-mcp/src/secrets.yaml"

[ -f "$MADDY_SECRETS" ]    || { echo "FAIL: Maddy secrets missing";    exit 2; }
[ -f "$MAIL_MCP_SECRETS" ] || { echo "FAIL: mail-mcp secrets missing"; exit 2; }
[ -f "$C3_MCP_SECRETS" ]   || { echo "FAIL: c3-infra-mcp secrets missing"; exit 2; }

check_key() {
    local file="$1" key="$2" label="$3"
    if ! sops -d --extract "[\"$key\"]" "$file" >/dev/null 2>&1; then
        echo "FAIL: $label is missing key $key"
        exit 1
    fi
    echo "  OK: $label has $key"
}

echo "[test] Verifying required NOREPLY secret keys exist…"
check_key "$MADDY_SECRETS"    "NOREPLY_PASSWORD"        "maddy"
check_key "$MAIL_MCP_SECRETS" "MADDY_NOREPLY_USER"      "mail-mcp"
check_key "$MAIL_MCP_SECRETS" "MADDY_NOREPLY_PASSWORD"  "mail-mcp"
check_key "$C3_MCP_SECRETS"   "NOREPLY_PASSWORD"        "c3-infra-mcp"

echo "[test] Verifying NOREPLY_PASSWORD is consistent across services…"
# Compare hashes, never print plaintext
MADDY_HASH=$(sops -d --extract '["NOREPLY_PASSWORD"]'       "$MADDY_SECRETS"    | sha256sum | cut -d' ' -f1)
MAIL_HASH=$(sops  -d --extract '["MADDY_NOREPLY_PASSWORD"]' "$MAIL_MCP_SECRETS" | sha256sum | cut -d' ' -f1)
C3_HASH=$(sops    -d --extract '["NOREPLY_PASSWORD"]'       "$C3_MCP_SECRETS"   | sha256sum | cut -d' ' -f1)

if [ "$MADDY_HASH" != "$MAIL_HASH" ]; then
    echo "FAIL: mail-mcp MADDY_NOREPLY_PASSWORD does not match Maddy NOREPLY_PASSWORD"
    echo "  maddy   sha256: $MADDY_HASH"
    echo "  mailmcp sha256: $MAIL_HASH"
    exit 1
fi
echo "  OK: mail-mcp and maddy NOREPLY passwords match (sha256=${MADDY_HASH:0:12}…)"

if [ "$MADDY_HASH" != "$C3_HASH" ]; then
    echo "FAIL: c3-infra-mcp NOREPLY_PASSWORD does not match Maddy NOREPLY_PASSWORD"
    echo "  maddy sha256: $MADDY_HASH"
    echo "  c3    sha256: $C3_HASH"
    exit 1
fi
echo "  OK: c3-infra-mcp and maddy NOREPLY passwords match"

echo ""
echo "PASS: NOREPLY secret is present + consistent across maddy, mail-mcp, c3-infra-mcp"
