#!/bin/sh
# test-src-terraform.sh — validate a c_vps/<provider>/src/ tree
#
# Run: ./test-src-terraform.sh /home/diego/git/cloud-infra/c_vps/<provider>/src
#
# Exits 0 if all PASS, 1 on any FAIL.

SRC="${1:-./src}"
[ -d "$SRC" ] || { echo "no src/ at $SRC"; exit 1; }

PASS=0; FAIL=0
pass() { printf "  \033[0;32mPASS\033[0m  %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[0;31mFAIL\033[0m  %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "── required source files ──"
[ -f "$SRC/main.tf" ]               && pass "main.tf"               || fail "missing main.tf"
[ -f "$SRC/terraform.json" ]        && pass "terraform.json"        || pass "terraform.json (optional)"

echo "── encrypted state present (if any) ──"
if [ -f "$SRC/terraform.tfstate.enc" ]; then
    if grep -q 'ENC\[\|sops:' "$SRC/terraform.tfstate.enc" 2>/dev/null; then
        pass "terraform.tfstate.enc is sops-encrypted"
    else
        fail "terraform.tfstate.enc exists but lacks sops/ENC marker"
    fi
fi

echo "── secrets sops-encrypted (if any) ──"
if [ -f "$SRC/secrets.yaml" ]; then
    if head -c 200 "$SRC/secrets.yaml" | grep -q 'sops:\|ENC\['; then
        pass "secrets.yaml is sops-encrypted"
    else
        fail "secrets.yaml exists but is NOT sops-encrypted"
    fi
fi

echo "── banned: plaintext state in src/ ──"
if [ -f "$SRC/terraform.tfstate" ]; then
    fail "plaintext terraform.tfstate present in src/ (must live in dist/ only)"
else
    pass "no plaintext terraform.tfstate"
fi

echo "── banned: stale state backups in src/ ──"
backup_count=$(find "$SRC" -maxdepth 1 -name 'terraform.tfstate*.backup' 2>/dev/null | wc -l)
if [ "$backup_count" -eq 0 ]; then
    pass "no .tfstate.backup files in src/"
else
    fail "$backup_count stale .tfstate.backup file(s) in src/ (delete them)"
fi

echo "── banned: real tfvars in src/ ──"
if [ -f "$SRC/terraform.tfvars" ]; then
    fail "terraform.tfvars present in src/ (must be rendered into dist/)"
else
    pass "no terraform.tfvars in src/"
fi

echo "── tfvars template present (if secrets) ──"
if [ -f "$SRC/secrets.yaml" ]; then
    if [ -f "$SRC/terraform.tfvars.template" ] || [ -f "$SRC/terraform.tfvars.example" ]; then
        pass "tfvars template present"
    else
        fail "secrets.yaml present but no terraform.tfvars.template/.example"
    fi
fi

echo
echo "═══ $PASS pass / $FAIL fail ═══"
[ "$FAIL" -eq 0 ]
