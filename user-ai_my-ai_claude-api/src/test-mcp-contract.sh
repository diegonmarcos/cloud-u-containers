#!/usr/bin/env bash
# ============================================================================
# test-mcp-contract.sh — the check that was missing when the code-graph MCP
# quietly stopped being consulted.
#
# The original defect was not a broken endpoint. The hooks told every agent to
# call `octocode_search` / `c3_*`, which are not tool names on any wired server.
# Agents found no such tool, curled the endpoint instead, got the MCP transport's
# HTTP 400 "Server not initialized", concluded the code graph was down, and fell
# back to grepping. Nothing logged an error, so the regression was invisible for
# as long as it lasted. These assertions make that class of drift loud.
#
#   static  (always)          — the agent-facing hook text still matches reality
#   live    ($AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN set) — every declared server
#                               completes an MCP handshake and lists tools, and
#                               skipping the handshake really does give the 400
#                               the hook text tells agents not to misread
#
# Usage: src/test-mcp-contract.sh
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/code/claude-config"
TPL="$CFG/mcp.tpl.json"
HOOKS="$CFG/hooks"

fail=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

echo "== static: hook text vs mcp.tpl.json =="

python3 -m json.tool "$TPL" >/dev/null 2>&1 \
  && ok "mcp.tpl.json parses" || bad "mcp.tpl.json does not parse"

for h in "$HOOKS"/*.sh; do
  bash -n "$h" 2>/dev/null && ok "$(basename "$h") parses" || bad "$(basename "$h") has a syntax error"
done

# The exact bug: bare, unprefixed tool identifiers presented to agents as callable.
# Every real name is mcp__<server>__<tool>; anything else sends the agent hunting.
# Asserted against what the hooks actually EMIT, not their source, because the
# source legitimately names the bad identifiers in the sentence that forbids them.
rendered=$(
  MCP_TPL="$TPL" "$HOOKS/b-context-inject-prompt.sh" 2>/dev/null
  echo '{"tool_name":"Bash"}' | "$HOOKS/c-context-inject-pretool.sh" 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['hookSpecificOutput']['additionalContext'])"
)
stray=$(printf '%s\n' "$rendered" \
        | grep -nE '(^|[^_[:alnum:]])(octocode_search|octocode_graphrag|knowledge_[a-z]+|c3_\*)' \
        | grep -vE 'mcp__|is NOT a tool|never was')
if [ -n "$stray" ]; then
  bad "agent-facing text advertises a bare MCP tool name (must be mcp__<server>__<tool>)"
  printf '%s\n' "$stray" | sed 's/^/       /'
else
  ok "no bare MCP tool names in agent-facing text"
fi

# Any mcp__<server>__ the hooks name must be a server mcp.tpl.json actually renders.
declared=$(python3 -c "import json;print(' '.join(json.load(open('$TPL'))))")
for s in $(grep -ohE 'mcp__[a-z0-9-]+__' "$HOOKS"/*.sh | sed 's/^mcp__//;s/__$//' | sort -u); do
  case " $declared " in
    *" $s "*) ok "hook names server '$s', which mcp.tpl.json declares" ;;
    *)        bad "hook names server '$s', absent from mcp.tpl.json" ;;
  esac
done

# The server list must be read from the template, never restated in prose —
# restating it is how it drifts.
grep -q 'jq -r .keys\[\]' "$HOOKS/b-context-inject-prompt.sh" \
  && ok "server list is read from mcp.tpl.json, not hardcoded" \
  || bad "b-context-inject-prompt.sh no longer derives the server list from mcp.tpl.json"

TOKEN="${AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN:-}"
if [ -z "$TOKEN" ]; then
  echo "== live: SKIPPED (AUTHELIA_OIDC_TOKEN_CLAUDE_ADMIN unset) =="
  [ "$fail" -eq 0 ] && echo "PASS (static only)" || echo "FAIL"
  exit "$fail"
fi

echo "== live: every declared server completes the MCP handshake =="
for name in $declared; do
  url=$(python3 -c "import json;print(json.load(open('$TPL'))['$name']['url'])")
  hdr=$(curl -sS -m 20 -D- -o /dev/null -X POST "$url" \
        -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-mcp-contract","version":"1"}}}' 2>/dev/null)
  sid=$(printf '%s' "$hdr" | tr -d '\r' | awk -F': ' '/^mcp-session-id/{print $2}')
  if [ -z "$sid" ]; then bad "$name: initialize returned no Mcp-Session-Id"; continue; fi
  n=$(curl -sS -m 30 -X POST "$url" \
        -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $TOKEN" -H "Mcp-Session-Id: $sid" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' 2>/dev/null \
      | sed 's/^data: //' \
      | python3 -c "import sys,json
for l in sys.stdin:
    l=l.strip()
    if l.startswith('{'):
        d=json.loads(l)
        if 'result' in d and 'tools' in d['result']: print(len(d['result']['tools'])); break
else: print(0)")
  [ "${n:-0}" -gt 0 ] && ok "$name: handshake + ${n} tools" || bad "$name: handshake succeeded but tools/list returned nothing"
done

# The claim the hook text makes to agents, asserted rather than assumed: the 400
# is the transport refusing an un-handshaken request, not the server being down.
echo "== live: no-handshake request really is a 400, not an outage =="
url=$(python3 -c "import json;print(json.load(open('$TPL'))['cloud-cgc-pub-mcp']['url'])")
code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -X POST "$url" \
       -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
       -H "Authorization: Bearer $TOKEN" \
       -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' 2>/dev/null)
[ "$code" = "400" ] \
  && ok "tools/list without initialize -> HTTP 400 (as the hook text tells agents)" \
  || bad "tools/list without initialize -> HTTP $code; the hook text explains 400 and is now stale"

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
