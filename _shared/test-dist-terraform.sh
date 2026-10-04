#!/bin/sh
# test-dist-terraform.sh — validate a c_vps/<provider>/dist/ tree
#
# Run: ./test-dist-terraform.sh /home/diego/git/cloud-infra/c_vps/<provider>/dist
#
# Exits 0 if all PASS, 1 on any FAIL.

DIST="${1:-./dist}"
[ -d "$DIST" ] || { echo "no dist/ at $DIST"; exit 1; }

PASS=0; FAIL=0
pass() { printf "  \033[0;32mPASS\033[0m  %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  \033[0;31mFAIL\033[0m  %s\n" "$1"; FAIL=$((FAIL+1)); }

echo "── required dist files ──"
[ -f "$DIST/main.tf" ] && pass "main.tf" || fail "missing main.tf"

echo "── tfvars rendered (if template existed in src) ──"
if [ -f "$DIST/terraform.tfvars" ]; then
    if grep -q 'INJECTED_FROM_SECRETS' "$DIST/terraform.tfvars" 2>/dev/null; then
        fail "terraform.tfvars still has INJECTED_FROM_SECRETS sentinel"
    else
        pass "terraform.tfvars rendered"
    fi
fi

echo "── backup pollution cap (≤ 1) ──"
backup_count=$(find "$DIST" -maxdepth 1 -name 'terraform.tfstate*.backup' 2>/dev/null | wc -l)
if [ "$backup_count" -le 1 ]; then
    pass "$backup_count .tfstate.backup file(s) (≤ 1 ok)"
else
    fail "$backup_count .tfstate.backup files (rotate/cleanup)"
fi

echo "── no .secrets in committed tree ──"
if [ -f "$DIST/.secrets" ]; then
    # ok if gitignored — engine writes it on apply
    if git -C "$(dirname "$DIST")" check-ignore -q "$DIST/.secrets" 2>/dev/null; then
        pass ".secrets present but gitignored"
    else
        fail ".secrets present and NOT gitignored"
    fi
else
    pass "no .secrets file (clean tree)"
fi

echo "── encrypted state mirrored (if applied) ──"
if [ -f "$DIST/terraform.tfstate" ]; then
    if [ -f "$DIST/terraform.tfstate.enc" ] || [ -f "$(dirname "$DIST")/src/terraform.tfstate.enc" ]; then
        pass "encrypted state exists alongside plaintext"
    else
        fail "plaintext state without encrypted mirror"
    fi
fi

echo
echo "═══ $PASS pass / $FAIL fail ═══"
[ "$FAIL" -eq 0 ]
