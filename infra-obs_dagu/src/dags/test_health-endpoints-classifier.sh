#!/bin/sh
# Tester for health_service-endpoints DOWN classifier (2026-07-07).
# Proves auth-gated 401/403 and 2xx/3xx are treated UP; only 000/5xx-backend DOWN.
# Run: sh test_health-endpoints-classifier.sh   (exit 0 = pass)
set -eu

# Mirror of the classifier in health_service-endpoints.yaml. Keep in sync.
is_down() {
  case "$1" in
    000|502|503|504) echo down ;;
    *)               echo up ;;
  esac
}

fail=0
check() { # code expected
  got=$(is_down "$1")
  if [ "$got" != "$2" ]; then
    echo "FAIL: HTTP $1 -> $got (expected $2)"; fail=1
  else
    echo "ok:   HTTP $1 -> $got"
  fi
}

# Alive — endpoint responding (incl. auth gates)
check 200 up      # healthy
check 301 up      # redirect (maddy)
check 302 up      # redirect (matomo/openobserve)
check 401 up      # auth challenge — endpoint ALIVE
check 403 up      # Authelia/ntfy-3tier gate — endpoint ALIVE
check 404 up      # route reachable, path missing — not "down"

# Down — unreachable or backend dead
check 000 down    # timeout / connection refused
check 502 down    # bad gateway — upstream dead
check 503 down    # service unavailable
check 504 down    # gateway timeout

if [ "$fail" = 0 ]; then echo "PASS"; else echo "FAILED"; exit 1; fi
