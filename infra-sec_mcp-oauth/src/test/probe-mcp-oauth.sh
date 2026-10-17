#!/usr/bin/env bash
# probe-mcp-oauth.sh — live, read-mostly probe of the MCP OAuth AS (option 31.1).
#
# Run AFTER a deploy (CI post-ship step or by hand):
#   bash infra-sec_mcp-oauth/src/test/probe-mcp-oauth.sh [https://mcp.diegonmarcos.com] [svc]
#
# Checks, from an anonymous off-mesh client (the claude.ai connector's view):
#   1. RFC 8414 + RFC 9728 metadata are public, JSON, and point at each other
#   2. DCR accepts the claude.ai callback and REJECTS a foreign redirect_uri
#   3. /authorize WITHOUT an Authelia session never yields a code
#      (401 from Authelia, or 302 to auth.diegonmarcos.com)
#   4. /token rejects a bogus code (invalid_grant / invalid_client)
#   5. /introspect is NOT reachable publicly (mesh-only)
#   6. a tool endpoint still refuses an anonymous / forged opaque token
# Side effect: registers ONE throwaway public client (no tokens; evicted by the
# registry cap). Exit 0 = all pass; non-zero = count of failures.
set -uo pipefail

BASE="${1:-https://mcp.diegonmarcos.com}"
SVC="${2:-cloud-infra}"
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

# 1. discovery
AS=$(curl -fsS --max-time 15 "$BASE/.well-known/oauth-authorization-server" 2>/dev/null)
if [ "$(jq -r .issuer <<<"$AS" 2>/dev/null)" = "$BASE" ] \
   && jq -e '.code_challenge_methods_supported == ["S256"] and (.registration_endpoint|length>0)' <<<"$AS" >/dev/null 2>&1
then pass "AS metadata (issuer, S256, registration_endpoint)"; else fail "AS metadata: $AS"; fi

PR=$(curl -fsS --max-time 15 "$BASE/.well-known/oauth-protected-resource/$SVC/mcp" 2>/dev/null)
if [ "$(jq -r '.authorization_servers[0]' <<<"$PR" 2>/dev/null)" = "$BASE" ] \
   && [ "$(jq -r .resource <<<"$PR" 2>/dev/null)" = "$BASE/$SVC/mcp" ]
then pass "protected-resource metadata for /$SVC/mcp"; else fail "PR metadata: $PR"; fi

# 2. DCR
REG=$(curl -sS --max-time 15 -X POST -H 'Content-Type: application/json' \
  -d '{"client_name":"ci-probe","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}' "$BASE/register")
CID=$(jq -r '.client_id // empty' <<<"$REG" 2>/dev/null)
[ -n "$CID" ] && pass "DCR accepts claude.ai callback ($CID)" || fail "DCR claude.ai: $REG"

C=$(code -X POST -H 'Content-Type: application/json' \
  -d '{"redirect_uris":["https://evil.example/cb"]}' "$BASE/register")
[ "$C" = 400 ] && pass "DCR rejects foreign redirect_uri" || fail "DCR foreign redirect -> $C (want 400)"

# 3. /authorize without a session: never a code
CH=$(printf 'probe-verifier-%064d' 0 | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
LOC=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 -G "$BASE/authorize" \
  --data-urlencode "response_type=code" --data-urlencode "client_id=${CID:-x}" \
  --data-urlencode "redirect_uri=https://claude.ai/api/mcp/auth_callback" \
  --data-urlencode "code_challenge=$CH" --data-urlencode "code_challenge_method=S256" --data-urlencode "state=p")
case "$LOC" in
  *code=*)                      fail "/authorize issued a code without a session: $LOC" ;;
  401*|403*|302*auth.diegonmarcos.com*) pass "/authorize gated by Authelia ($LOC)" ;;
  *)                            fail "/authorize unexpected: $LOC" ;;
esac

# 4. /token bogus code
T=$(curl -sS --max-time 15 -X POST "$BASE/token" -d grant_type=authorization_code \
  -d code=bogus -d "client_id=${CID:-x}" -d code_verifier=bogus)
jq -e '.error == "invalid_grant" or .error == "invalid_client"' <<<"$T" >/dev/null 2>&1 \
  && pass "/token rejects bogus code" || fail "/token bogus: $T"

# 5. introspection must not be public
C=$(code -X POST -d token=mcpat_x "$BASE/introspect")
case "$C" in 200) fail "/introspect is publicly reachable" ;; *) pass "/introspect not public ($C)" ;; esac

# 6. tool endpoint refuses anonymous + forged opaque token
C=$(code -X POST "$BASE/$SVC/mcp")
[ "$C" = 401 ] || [ "$C" = 403 ] && pass "/$SVC/mcp anonymous -> $C" || fail "/$SVC/mcp anonymous -> $C"
C=$(code -X POST -H 'Authorization: Bearer mcpat_forged' "$BASE/$SVC/mcp")
[ "$C" = 401 ] || [ "$C" = 403 ] && pass "/$SVC/mcp forged mcpat_ -> $C" || fail "/$SVC/mcp forged -> $C"

echo "failures: $FAIL"
exit "$FAIL"
