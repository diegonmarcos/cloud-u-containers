#!/usr/bin/env bash
# Tester (#1147): fb-proxy-auth.sh converges filebrowser's auth method declaratively and is inert when unset.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; TPL="$HERE/templates/fb-proxy-auth.sh.tpl"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAIL=0; ok(){ echo "PASS $*"; }; bad(){ echo "FAIL $*" >&2; FAIL=1; }
mkdir -p "$W/bin"
cat > "$W/bin/filebrowser" <<'S'
#!/bin/sh
echo "filebrowser $*" >> "$STUB_LOG"
[ "$1 $2" = "users ls" ] && [ -f "$STUB_USER" ] && echo "1 diego"
exit 0
S
cat > "$W/init.sh" <<'S'
#!/bin/sh
echo "init $*" >> "$STUB_LOG"
S
chmod +x "$W/bin/filebrowser" "$W/init.sh"
sed "s#exec /init.sh#exec $W/init.sh#" "$TPL" > "$W/s.sh"
run(){ : > "$W/log"; ( env -i PATH="$W/bin:/usr/bin:/bin" STUB_LOG="$W/log" STUB_USER="$W/nouser" "$@" sh "$W/s.sh" arg1 ) >/dev/null 2>&1; }
run
grep -q filebrowser "$W/log" && bad "unset: touched the database" || ok "unset: filebrowser never called"
grep -q '^init arg1$' "$W/log" && ok "unset: hands over to /init.sh with args" || bad "unset: no handover"
run FB_PROXY_AUTH=true
grep -q 'config set .*--auth.method=proxy --auth.header=X-Forwarded-User' "$W/log" && ok "true: proxy method with the edge header" || bad "true: config set"
grep -q 'users add diego .*--perm.admin' "$W/log" && ok "true: mapped user ensured" || bad "true: user add"
grep -q '^init arg1$' "$W/log" && ok "true: hands over" || bad "true: no handover"
: > "$W/nouser"; touch "$W/nouser"
( : > "$W/log"; env -i PATH="$W/bin:/usr/bin:/bin" STUB_LOG="$W/log" STUB_USER="$W/nouser" FB_PROXY_AUTH=true sh "$W/s.sh" ) >/dev/null 2>&1
grep -q 'users add' "$W/log" && bad "true: re-added an existing user" || ok "true: existing user not re-added"
run FB_PROXY_AUTH=false
grep -q 'auth.method=json' "$W/log" && ok "false: explicit revert to json" || bad "false: revert"
grep -q 'X-Forwarded-User' "$HERE/../build.json" "$HERE/../build.json" >/dev/null 2>&1 && ok "header matches build.json identity.header" || bad "header differs from build.json identity.header"
grep -q 'entrypoint = \[ "tini" "--" "sh" "/fb-proxy-auth.sh" \]' "$HERE/compose.nix" && grep -q 'FILEBROWSER_PROXY_AUTH:-' "$HERE/compose.nix" && ok "compose wires the wrapper, default off" || bad "compose wiring"
exit "$FAIL"
