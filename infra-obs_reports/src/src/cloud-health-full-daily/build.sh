#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
BINARY="cloud-health-full-daily"
. "$ROOT/../_crate_engine.sh"

send_html() {
    echo "═══ Sending report via SMTP ═══"
    # Engine writes to the SHARED reports/dist/, not per-crate dist/.
    # ROOT = reports/src/cloud-health-full-daily — REPORTS_DIST is 2 up.
    # Invoke via bash explicitly: send.sh uses ${BASH_SOURCE[0]} (bash-only).
    bash "$ROOT/src/send.sh" "$ROOT/../../dist/cloud_health_daily.html"
}

case "${1:-all}" in
    build)  engine_build ;;
    link)   engine_link ;;
    html|run) engine_run ;;
    send)   send_html ;;
    all)    engine_build; engine_run ;;
    ship)   engine_build; engine_run; send_html ;;
    *)      echo "Usage: $0 [build|link|html|send|run|all|ship]"; exit 1 ;;
esac
