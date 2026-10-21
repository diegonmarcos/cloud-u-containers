#!/usr/bin/env bash
# Live probe (#1071), run by hand or from a mesh VM: every auth scheme against both mail hosts, asserting
# WHO answers. Edge gate = text/html or a 302 to auth.*; Stalwart = application/problem+json.
# Expected (public source / mesh source):
#   none            -> 302 auth.*            / 200 session
#   Basic wrong     -> 302 auth.*            / 401 problem+json (Stalwart)
#   Bearer garbage  -> 401 problem+json      / 401 problem+json (passed through, Stalwart decodes it)
#   X-Fleet garbage -> 401 text/html "Invalid token" (edge)  / 401 problem+json (mesh peers skip the gate)
# MODE=public|mesh picks the column. Optional: ME_PASSWORD=... asserts a real Basic login -> 200 on the mesh.
set -uo pipefail
MODE="${MODE:-public}"; fail=0
probe(){ # name host expect_code expect_type_regex curl-args...
  local name=$1 host=$2 code=$3 typ=$4; shift 4
  local out; out=$(curl -sS -m 15 -o /dev/null -w '%{http_code} %{content_type}' "$@" "https://$host.diegonmarcos.com/.well-known/jmap" 2>&1)
  if [[ "$out" == "$code "* && "$out" =~ $typ ]]; then echo "ok   [$MODE] $host $name -> $out"; else echo "FAIL [$MODE] $host $name -> $out (want $code $typ)" >&2; fail=1; fi
}
for h in jmap mails; do
  if [ "$MODE" = mesh ]; then
    probe none "$h" 200 'json'
    probe basic-wrong "$h" 401 'problem\+json' -u me@diegonmarcos.com:wrong
    probe bearer-garbage "$h" 401 'problem\+json' -H 'Authorization: Bearer abc.def'
    probe fleet-garbage "$h" 401 'problem\+json' -H 'X-Fleet-Authorization: Bearer abc' -u me@diegonmarcos.com:wrong
    [ -n "${ME_PASSWORD:-}" ] && probe basic-real "$h" 200 'json' -u "me@diegonmarcos.com:$ME_PASSWORD"
  else
    probe none "$h" 302 'html'
    probe basic-wrong "$h" 302 'html' -u me@diegonmarcos.com:wrong
    probe bearer-garbage "$h" 401 'problem\+json' -H 'Authorization: Bearer abc.def'
    probe fleet-garbage "$h" 401 'text/html' -H 'X-Fleet-Authorization: Bearer abc' -u me@diegonmarcos.com:wrong
  fi
done
exit $fail
