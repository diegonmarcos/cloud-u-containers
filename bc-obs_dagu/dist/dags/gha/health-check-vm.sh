#!/bin/sh
# Health check for a single VM — container status + port checks (async)
# Usage: health-check-vm.sh <ssh-alias> <ports> [known-flaky]
#   ssh-alias:   SSH config alias (e.g. oci-apps, gcp-proxy)
#   ports:       comma-separated port list (e.g. 80,443,8080)
#   known-flaky: comma-separated container names that warn instead of fail
set -e

ALIAS="${1:?Usage: $0 <ssh-alias> <ports> [known-flaky]}"
PORTS="${2:?Usage: $0 <ssh-alias> <ports> [known-flaky]}"
KNOWN_FLAKY="${3:-}"

CONTAINERS="/tmp/containers.txt"
PORT_RESULTS="/tmp/port_results"
mkdir -p "$PORT_RESULTS"

# ── Container health ──
echo "=== $ALIAS container health ==="
ssh "$ALIAS" 'docker ps --format "{{.Names}}\t{{.Status}}" 2>&1' | tee "$CONTAINERS"

failed=0
warned=0
while IFS=$(printf '\t') read -r name status; do
  [ -z "$name" ] && continue
  if printf '%s' "$status" | grep -qiE 'Restarting|unhealthy|Exited'; then
    if [ -n "$KNOWN_FLAKY" ] && printf '%s' ",$KNOWN_FLAKY," | grep -q ",$name,"; then
      echo "::warning::$name — $status (known-flaky, non-blocking)"
      ssh -n "$ALIAS" "docker logs $name --tail 10 2>&1" || true
      warned=$((warned + 1))
    else
      echo "::error::$name — $status"
      ssh -n "$ALIAS" "docker logs $name --tail 10 2>&1" || true
      failed=$((failed + 1))
    fi
  else
    echo "✓ $name — $status"
  fi
done < "$CONTAINERS"

# ── Port checks (async) ──
echo ""
echo "=== Port checks ==="
IFS=','
for port in $PORTS; do
  (
    if ssh -n "$ALIAS" "timeout 2 bash -c 'echo > /dev/tcp/127.0.0.1/$port' 2>/dev/null"; then
      echo "PASS $port" > "$PORT_RESULTS/$port"
    else
      echo "FAIL $port" > "$PORT_RESULTS/$port"
    fi
  ) &
done
unset IFS
wait

# Collect port results
port_fail=0
for f in "$PORT_RESULTS"/*; do
  [ -f "$f" ] || continue
  result=$(cat "$f")
  port=$(echo "$result" | awk '{print $2}')
  case "$result" in
    PASS*) echo "✓ :$port open" ;;
    FAIL*) echo "✗ :$port closed"; port_fail=$((port_fail + 1)) ;;
  esac
done

# ── Summary ──
echo ""
[ "$warned" -gt 0 ] && echo "::warning::$warned known-flaky container(s) unhealthy (non-blocking)"
[ "$port_fail" -gt 0 ] && echo "::warning::$port_fail port(s) closed"

if [ "$failed" -gt 0 ]; then
  echo "::error::$failed container(s) unhealthy"
  echo ""
  echo "=== Debug dump ==="
  ssh -n "$ALIAS" 'free -m; echo "---"; uptime; echo "---"; df -h / 2>/dev/null' || true
  exit 1
fi
echo "All containers healthy"
