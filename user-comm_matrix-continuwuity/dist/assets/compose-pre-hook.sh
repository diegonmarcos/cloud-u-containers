#!/bin/sh
# compose-pre-hook.sh — runs on the VM before `docker compose up`.
# Renders data/appservices.toml: one `appservices register` admin_execute
# command per declared appservice, whose body is the registration.yaml that
# bridge's own deploy rendered from its sops pair. Continuwuity keeps
# registrations only in its database; this re-registers them on every start
# (same id = overwrite), so the homeserver can never hold a token the bridge
# does not, and nothing is pasted into the admin room by hand.
set -eu
ROOT="$(dirname "$0")/.."
mkdir -p "$ROOT/data"
OUT="$ROOT/data/appservices.toml"

{
  echo "[global]"
  # A malformed registration must not stop the homeserver itself; the bridge
  # that depends on it fails loudly on its own ("as_token was not accepted").
  echo "admin_execute_errors_ignore = true"
  echo "admin_execute = ["
  grep -v '^#' "$ROOT/configs/appservice-registrations.list" | while read -r reg; do
    [ -n "$reg" ] || continue
    if [ ! -r "$reg" ]; then
      echo "compose-pre-hook: WARNING $reg not found — deploy that bridge first; it is NOT registered" >&2
      continue
    fi
    # The body is embedded in a TOML ''' literal string, which cannot contain '''.
    if grep -qF "'''" "$reg"; then
      echo "compose-pre-hook: $reg contains ''' and cannot be embedded" >&2; exit 1
    fi
    printf "'''\nappservices register\n\`\`\`\n"
    cat "$reg"
    printf "\`\`\`\n''',\n"
  done
  echo "]"
} > "$OUT.tmp"
# Rewrite in place (same inode) — the file is bind-mounted into the container.
cat "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp"
chmod 600 "$OUT"
echo "compose-pre-hook: $(grep -c '^appservices register' "$OUT") appservice registration(s) rendered"
exit 0
