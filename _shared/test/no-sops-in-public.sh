#!/usr/bin/env bash
# Guard (#1064): no sops-encrypted file may be tracked in this PUBLIC repo.
# The containers' encrypted secrets live only in the private repo
# cloud-me-pvt-vault (Linux-Containers/); CI overlays them at ship time
# (cloudy-t-infra overlay-private-secrets.sh). Ciphertext in a public repo is
# not plaintext exposure, but the owner wants it private, and every copy here is
# one more place a key rotation has to reach.
#
# A tracked file counts as sops-encrypted when it carries sops metadata AND
# ciphertext:
#   yaml / dotenv : a line starting `sops:` or `sops_mac=`, plus `ENC[`
#   json          : a `"sops": {` key, plus `ENC[`
# Source files that merely MENTION the marker (a regex in a .ts, a comment) do
# not carry such a line and are not matched.
#
# Allowlist _shared/test/no-sops-in-public.allow (one path per line, `#`
# comments): transition only. It must end up empty; an entry for a path that is
# no longer tracked is harmless.
#
# Usage: no-sops-in-public.sh [repo_root]     exit 1 on any violation, 0 clean.
# Never prints file content, only paths.
set -u
ROOT="${1:-$(git rev-parse --show-toplevel)}"
ALLOW="$ROOT/_shared/test/no-sops-in-public.allow"
bad=0; n=0
allowed() { [ -f "$ALLOW" ] && grep -vE '^\s*(#|$)' "$ALLOW" | grep -qxF -- "$1"; }
while IFS= read -r -d '' f; do
  p="$ROOT/$f"
  [ -f "$p" ] && [ ! -L "$p" ] || continue
  [ "$(wc -c < "$p")" -le 2000000 ] || continue
  grep -Iq . "$p" 2>/dev/null || continue
  grep -q 'ENC\[' "$p" || continue
  if grep -qE '^(sops:|sops_mac=)|^[[:space:]]*"sops"[[:space:]]*:[[:space:]]*\{' "$p"; then
    n=$((n+1))
    if allowed "$f"; then continue; fi
    echo "SOPS-IN-PUBLIC: $f"; bad=$((bad+1))
  fi
done < <(git -C "$ROOT" ls-files -z)
if [ "$bad" -gt 0 ]; then
  echo "no-sops-in-public: FAIL, $bad sops-encrypted file(s) tracked in this public repo (not allowlisted)."
  echo "Put them in cloud-me-pvt-vault Linux-Containers/<same path> instead and remove them here."
  exit 1
fi
echo "no-sops-in-public: ok ($n sops file(s) tracked, all allowlisted)"
