#!/usr/bin/env bash
# Mutation test for render-dist-secret-mounts-guard.sh: a render that strips secret mounts must go
# red; a render that keeps them, or adds some, must stay green.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; GUARD="$HERE/render-dist-secret-mounts-guard.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P=0; F=0
ok() { P=$((P+1)); echo "  ok   $1"; }; bad() { F=$((F+1)); echo "  FAIL $1"; }
new_repo() { rm -rf "$T/r"; mkdir -p "$T/r/svc/dist/compose"; git -C "$T/r" init -q
  printf '{"volumes":["./.secrets.d:/run/secrets:ro","./.secrets.json:/run/secrets.json:ro"],"env_file":[".secrets"]}' > "$T/r/svc/dist/compose/docker-compose.yml"
  git -C "$T/r" add -A; git -C "$T/r" -c user.email=t@t -c user.name=t commit -q -m base; }
run() { bash "$GUARD" "$T/r" svc >"$T/out" 2>&1; }

new_repo; echo x > "$T/r/svc/dist/.src-hash"; run && ok "src-hash only change: green" || { bad "false positive"; cat "$T/out"; }
new_repo; printf '{"volumes":[],"env_file":[]}' > "$T/r/svc/dist/compose/docker-compose.yml"
run && bad "MUTATION stripped mounts not caught" || { grep -q 'svc/dist/compose/docker-compose.yml' "$T/out" && ok "mutation: stripped secret mounts turn the guard red" || bad "red but path not named"; }
new_repo; rm "$T/r/svc/dist/compose/docker-compose.yml"
run && bad "MUTATION deleted compose not caught" || ok "mutation: deleted compose turns the guard red"
new_repo; printf '{"volumes":["./.secrets.d:/run/secrets:ro","./.secrets.json:/run/secrets.json:ro","/run/secrets/x"],"env_file":[".secrets"]}' > "$T/r/svc/dist/compose/docker-compose.yml"
run && ok "added mounts: green" || bad "added mounts rejected"
echo "render-dist-secret-mounts-guard.test: $P passed, $F failed"; [ "$F" -eq 0 ]
