#!/bin/sh
# jev-ask.sh <use> [key=value ...] — ask the Jev sidecar (#881) one question set and print ONE line of
# advice, or nothing. Always exits 0 and prints nothing on any failure: no key, sidecar down, timeout,
# observe-only/gate closed, malformed answer. A DAG appends the output to its alert body, so with no
# opinion the alert is byte-for-byte what it was before Jev. Questions: lib/jev-questions.json (one place).
# A missing key or an unreachable sidecar raises ONE low-priority ntfy per day (never an error).
use="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
SIDECAR="${JEV_SIDECAR_URL:-http://10.0.0.6:3110}"
NTFY="${NTFY_URL:-http://10.0.0.6:8090}"
[ -n "$use" ] && [ "${JEV_ASK_DISABLE:-0}" != 1 ] && command -v jq >/dev/null 2>&1 || exit 0
state=$(jq -n '[$ARGS.positional[] | capture("^(?<k>[^=]+)=(?<v>.*)$") | {(.k): .v}] | add // {}' --args "$@" 2>/dev/null) || exit 0
req=$(jq -c --argjson s "$state" --arg u "$use" '{state: $s, questions: .[$u]}' "$HERE/jev-questions.json" 2>/dev/null) || exit 0
ans=$(curl -s --max-time "${JEV_ASK_TIMEOUT:-8}" -X POST -H 'Content-Type: application/json' -d "$req" "$SIDECAR/decide/$use" 2>/dev/null)
reason=$(printf '%s' "$ans" | jq -r 'if .ok == true then "ok" else (.reason // "unreachable") end' 2>/dev/null || echo unreachable)
case "$reason" in
  ok)
    printf '%s' "$ans" | jq -r '"Jev suggests: " + ([.results | to_entries[] | .key + "=" + (if .value.type == "noul" then (if .value.value then "yes" else "no" end) elif .value.type == "choice" then .value.pick else .value.level end) + " (p=" + (.value.p | tostring) + (if .value.confident then "" else ", not confident" end) + ")"] | join(", "))' 2>/dev/null
    ;;
  no_key|unreachable)
    stamp="${TMPDIR:-/tmp}/jev-ask-alerted.$(date -u +%Y%m%d)"
    if [ ! -e "$stamp" ]; then
      : > "$stamp" 2>/dev/null
      curl -s --max-time 5 -X POST "$NTFY/infra_jev" -H "Title: Jev sidecar has no opinion ($reason)" -H "Priority: 2" -H "Tags: robot,warning" \
        -d "jev-sidecar answered '$reason' for use $use. Alerts are unchanged (no opinion = today's behaviour). If no_key: set OPENROUTER_API_KEY in the jev-sidecar sops secrets and redeploy." >/dev/null 2>&1
    fi
    ;;
esac
exit 0
