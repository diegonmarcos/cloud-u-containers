#!/usr/bin/env bash
# Tester: the pre-hook turns the bridge's rendered registration into an
# admin_execute entry Continuwuity will actually accept at startup.
#
# Continuwuity (src/admin/processor.rs parse + appservice/commands.rs register)
# drops blank lines, takes line 1 as the command and the rest as the body, and
# requires the body to be a ``` fenced block. A config that parses as TOML but
# breaks that shape is a homeserver that silently registers nothing — the
# bridge then dies with "as_token was not accepted", which is the defect this
# replaces. The registration is rendered from the REAL bridge template, so a
# template change that cannot be embedded (e.g. a ''' in it) fails here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TPL="$HERE/../../user-comm_matrix-mautrix-whatsapp/src/templates/registration.yaml.tpl"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
check() { if "${@:2}"; then echo "  ok   $1"; else echo "  FAIL $1"; FAILED=$((FAILED + 1)); fi; }

AS=aaaa1111; HS=bbbb2222
sed -e "s/\${AS_TOKEN}/$AS/; s/\${HS_TOKEN}/$HS/; s/@[A-Z_]*@/x/g" "$TPL" > "$WORK/registration.yaml"

render() { # $1 = scenario dir, $2... = registration paths listed
  local d="$WORK/$1"; mkdir -p "$d/assets" "$d/configs"; shift
  cp "$HERE/assets/compose-pre-hook.sh" "$d/assets/"
  { echo "# GENERATED banner line"; printf '%s\n' "$@"; } > "$d/configs/appservice-registrations.list"
  local rc=0; sh "$d/assets/compose-pre-hook.sh" >/dev/null 2>"$d/stderr" || rc=$?
  echo "$rc" > "$d/rc"
}
hook_ok() { [ "$(cat "$WORK/$1/rc")" = 0 ]; }

# What Continuwuity does with each admin_execute entry, then the register checks.
accepts() { # $1 = toml, $2 = expected number of registrations
  python3 - "$1" "$2" "$AS" "$HS" <<'PY'
import sys, tomllib
cfg = tomllib.load(open(sys.argv[1], "rb"))["global"]
cmds = cfg.get("admin_execute", [])
assert cfg.get("admin_execute_errors_ignore") is True, "errors_ignore not set"
assert len(cmds) == int(sys.argv[2]), f"{len(cmds)} commands"
for c in cmds:
    lines = [l for l in c.splitlines() if l.strip()]
    assert lines[0] == "appservices register", lines[0]
    body = lines[1:]
    assert len(body) >= 2 and body[0].strip().startswith("```") and body[-1].strip() == "```", "no code block"
    yaml = "\n".join(body[1:-1])
    assert f'as_token: "{sys.argv[3]}"' in yaml and f'hs_token: "{sys.argv[4]}"' in yaml, "tokens not carried"
    assert "\nid: whatsapp" in "\n" + yaml, "id missing"
PY
}

echo "-- one declared bridge"
render one "$WORK/registration.yaml"
check "pre-hook succeeded" hook_ok one
check "admin_execute registers the bridge's own tokens" accepts "$WORK/one/data/appservices.toml" 1
check "rendered file is private (holds tokens)" test "$(stat -c %a "$WORK/one/data/appservices.toml")" = 600

echo "-- declared bridge not deployed yet"
render missing "$WORK/nope/registration.yaml"
check "a missing bridge does not fail the homeserver deploy" hook_ok missing
check "homeserver config still valid, registers nothing" accepts "$WORK/missing/data/appservices.toml" 0
check "the gap is reported, not silent" grep -q "NOT registered" "$WORK/missing/stderr"

[ "$FAILED" -eq 0 ] || { echo "FAIL: $FAILED assertion(s)"; exit 1; }
echo "PASS: appservice registrations render into a startup config Continuwuity accepts"
