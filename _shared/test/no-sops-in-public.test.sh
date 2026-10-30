#!/usr/bin/env bash
# Mutation test for no-sops-in-public.sh: the guard must go RED on a planted
# sops file (yaml, json, dotenv), stay green on look-alikes, and honour the allowlist.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/no-sops-in-public.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
P=0; F=0
ok() { P=$((P+1)); echo "  ok   $1"; }; bad() { F=$((F+1)); echo "  FAIL $1"; }
new_repo() { rm -rf "$T/r"; mkdir -p "$T/r/svc/src" "$T/r/_shared/test"; git -C "$T/r" init -q; }
commit() { git -C "$T/r" add -A >/dev/null; git -C "$T/r" -c user.email=t@t -c user.name=t commit -q -m x; }
run() { bash "$GUARD" "$T/r" >"$T/out" 2>&1; }

new_repo; echo 'a: 1' > "$T/r/svc/src/config.yaml"
printf 'const re = /ENC\\[AES256/;\nsops: mentioned in a comment? no, indented\n' | sed 's/^sops/  sops/' > "$T/r/svc/src/check.ts"
commit; run && ok "clean tree and source files that only mention the marker: green" || { bad "false positive"; cat "$T/out"; }

new_repo; printf 'K: ENC[AES256_GCM,data:abc,tag:t]\nsops:\n  version: 3.9.4\n' > "$T/r/svc/src/secrets.yaml"; commit
run && bad "MUTATION yaml sops file not caught" || { grep -q 'svc/src/secrets.yaml' "$T/out" && ok "mutation: planted yaml sops file turns the guard red" || bad "red but path not named"; }

new_repo; printf '{\n  "K": "ENC[AES256_GCM,data:abc]",\n  "sops": {\n    "version": "3.9.4"\n  }\n}\n' > "$T/r/svc/src/x.json"; commit
run && bad "MUTATION json sops file not caught" || ok "mutation: planted json sops file turns the guard red"

new_repo; printf 'K=ENC[AES256_GCM,data:abc]\nsops_mac=ENC[AES256_GCM,data:m]\n' > "$T/r/svc/src/.env.enc"; commit
run && bad "MUTATION dotenv sops file not caught" || ok "mutation: planted dotenv sops file turns the guard red"

new_repo; printf 'K: ENC[AES256_GCM,data:abc]\nsops:\n  version: 3.9.4\n' > "$T/r/svc/src/secrets.yaml"
echo 'svc/src/secrets.yaml' > "$T/r/_shared/test/no-sops-in-public.allow"; commit
run && ok "allowlisted path is tolerated" || bad "allowlist ignored"

new_repo; printf 'K: ENC[AES256_GCM,data:abc]\nsops:\n  version: 3.9.4\n' > "$T/r/svc/src/secrets.yaml"; commit
git -C "$T/r" rm -q svc/src/secrets.yaml; commit
run && ok "removed file: green again" || bad "still red after removal"

echo "no-sops-in-public.test: $P passed, $F failed"; [ "$F" -eq 0 ]
