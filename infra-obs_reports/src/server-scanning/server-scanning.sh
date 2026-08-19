#!/bin/sh
# server-scanning.sh — TCP port discovery for a host (default 1-20005).
#
# Sibling of ~/url-triage.sh. This script answers "what's open on this host?",
# url-triage.sh answers "what is the service at this URL really doing?".
#
# Usage:
#   server-scanning.sh <host|ip> [--ports START-END] [--banner] [--no-color]
#   server-scanning.sh --self-test
#
# Output:
#   ~/.triage/scan-<host>-<UTC>/
#     report.json              canonical metadata
#     banner-tcp<port>.txt     2-line cleartext banner grab per open port (if --banner)
#
# Source of truth: this file at $HOME, not managed by home-manager.

set -u

###############################################################################
# Args — $1 = host/IP
###############################################################################

usage() {
    cat <<'USAGE'
Usage: server-scanning.sh <host|ip> [--ports START-END] [--banner] [--no-color]
       server-scanning.sh --self-test

Examples:
  server-scanning.sh diegonmarcos.com
  server-scanning.sh mail.diegonmarcos.com --banner
  server-scanning.sh 35.226.147.64 --ports 1-1024 --banner
  server-scanning.sh --self-test               # quick scan against example.com

Output:
  ~/.triage/scan-<host>-<UTC>/report.json    canonical artifact
  ~/.triage/scan-<host>-<UTC>/banner-tcp<port>.txt  (with --banner)
USAGE
}

SELF_TEST=0
case "${1:-}" in
    "")          usage; exit 2 ;;
    -h|--help)   usage; exit 0 ;;
    --self-test) SELF_TEST=1; INPUT="example.com"; shift ;;
    -*)          printf 'server-scanning: first arg must be host/IP\n' >&2; usage >&2; exit 2 ;;
    *)           INPUT=$1; shift ;;
esac

PORTS="1-20005"
USE_COLOR="auto"
BANNERS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ports=*)  PORTS=${1#--ports=} ;;
        --ports)    shift; PORTS=${1:-$PORTS} ;;
        --banner)   BANNERS=1 ;;
        --no-color) USE_COLOR="no" ;;
        -h|--help)  usage; exit 0 ;;
        *)          printf 'server-scanning: unknown flag: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [ "$SELF_TEST" -eq 1 ]; then
    PORTS="20-25"
    BANNERS=1
fi

###############################################################################
# Color
###############################################################################

if [ "$USE_COLOR" = "auto" ]; then
    if [ -t 1 ]; then USE_COLOR=yes; else USE_COLOR=no; fi
fi
if [ "$USE_COLOR" = "yes" ]; then
    C_BOLD=$(printf '\033[1m');   C_DIM=$(printf '\033[2m')
    C_GREEN=$(printf '\033[1;32m'); C_YELLOW=$(printf '\033[1;33m')
    C_RED=$(printf '\033[1;31m'); C_OFF=$(printf '\033[0m')
else
    C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi

###############################################################################
# Host / preflight
###############################################################################

HOST=${INPUT#*://}
HOST=${HOST%%/*}
HOST=${HOST%%\?*}
HOST=${HOST%%:*}

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq;  then printf 'jq required\n'   >&2; exit 1; fi
if ! have nmap; then printf 'nmap required — declare in flake\n' >&2; exit 1; fi
HAVE_NC=0; have nc && HAVE_NC=1

###############################################################################
# Workspace + output dir
###############################################################################

TS=$(date -u +%Y%m%dT%H%M%SZ)
SAFE_HOST=$(printf '%s' "$HOST" | tr '/:?#' '____')
# Colocated dist/ per cloud-data `reports/<name>/dist/...` convention.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT_DIR="$SCRIPT_DIR/dist/scan-${SAFE_HOST}-${TS}"
mkdir -p "$OUT_DIR"
TMP=$(mktemp -d 2>/dev/null) || TMP="/tmp/server-scanning.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM HUP

REPORT_JSON="$OUT_DIR/report.json"

###############################################################################
# Stage 1 — nmap scan
###############################################################################

START_TS=$(date +%s)
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf '%sserver-scanning(%s)  ports=%s  banner=%s%s\n' \
       "$C_BOLD" "$HOST" "$PORTS" "$BANNERS" "$C_OFF"
printf '%sRunning nmap TCP-connect scan...%s\n' "$C_DIM" "$C_OFF"

nmap -sT -Pn -n -p "$PORTS" -T4 --open \
     --max-retries 1 --host-timeout 120s \
     --min-rate 1000 "$HOST" 2>&1 > "$TMP/nmap.out" || true

# Extract just the "<port>/tcp open SERVICE" lines
awk '/^[0-9]+\/tcp[[:space:]]+open/' "$TMP/nmap.out" > "$TMP/open_ports.txt"
OPEN_COUNT=$(wc -l < "$TMP/open_ports.txt" | tr -d ' ')

printf '\n%s=== TCP open ports (%s) ===%s\n' "$C_GREEN" "$OPEN_COUNT" "$C_OFF"
if [ "$OPEN_COUNT" -eq 0 ]; then
    printf '  (none — host firewalled or down)\n'
else
    cat "$TMP/open_ports.txt"
fi

###############################################################################
# Stage 2 — optional cleartext banner grabs (parallel, bounded)
###############################################################################

# Worker: connect, read up to 5s, save to $OUT_DIR/banner-tcp<port>.txt
grab_banner() {
    PORT=$1
    BNR=$OUT_DIR/banner-tcp${PORT}.txt
    if [ "$HAVE_NC" = 1 ]; then
        # printf '' closes stdin so nc returns after server greeting
        printf '' | nc -w 5 "$HOST" "$PORT" > "$BNR" 2>&1 || true
    fi
}

BANNER_JSON='[]'
if [ "$BANNERS" = 1 ] && [ "$OPEN_COUNT" -gt 0 ]; then
    printf '\n%s=== Cleartext banner grabs (parallel, 5s each) ===%s\n' "$C_YELLOW" "$C_OFF"
    PIDS=""
    while read -r LINE; do
        PORT=${LINE%%/*}
        grab_banner "$PORT" &
        PIDS="$PIDS $!"
    done < "$TMP/open_ports.txt"
    for p in $PIDS; do wait "$p" 2>/dev/null; done

    # Build JSON array of {port, banner_file, first_line}
    BANNER_JSON=$(jq -n '[]')
    while read -r LINE; do
        PORT=${LINE%%/*}
        BNR=$OUT_DIR/banner-tcp${PORT}.txt
        if [ -s "$BNR" ]; then
            FIRST=$(head -1 "$BNR" | tr -d '\r' | head -c 120)
            BSIZE=$(wc -c < "$BNR" | tr -d ' ')
            BANNER_JSON=$(printf '%s' "$BANNER_JSON" | jq \
                --argjson port "$PORT" \
                --arg file "banner-tcp${PORT}.txt" \
                --arg first "$FIRST" \
                --argjson size "$BSIZE" \
                '. + [{port: $port, file: $file, size_bytes: $size, first_line: $first}]')
            printf '  %sport %s%s  %s\n' "$C_BOLD" "$PORT" "$C_OFF" "$FIRST"
        else
            BANNER_JSON=$(printf '%s' "$BANNER_JSON" | jq \
                --argjson port "$PORT" \
                '. + [{port: $port, file: null, size_bytes: 0, first_line: null}]')
            printf '  %sport %s%s  (silent — client-first protocol or filtered)\n' "$C_BOLD" "$PORT" "$C_OFF"
        fi
    done < "$TMP/open_ports.txt"
fi

###############################################################################
# Stage 3 — assemble JSON
###############################################################################

END_TS=$(date +%s)
FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ELAPSED=$(( END_TS - START_TS ))

OPEN_PORTS_JSON=$(awk '
    /^[0-9]+\/tcp[[:space:]]+open/ {
        n=split($1, a, "/")
        printf "%s\n", a[1]
    }' "$TMP/nmap.out" \
    | jq -R . | jq -s 'map(tonumber)')

jq -n \
    --arg input        "$INPUT" \
    --arg host         "$HOST" \
    --arg ports        "$PORTS" \
    --arg started_at   "$STARTED_AT" \
    --arg finished_at  "$FINISHED_AT" \
    --argjson elapsed  "$ELAPSED" \
    --argjson open     "$OPEN_PORTS_JSON" \
    --argjson banners  "$BANNER_JSON" \
    --argjson did_banner "$BANNERS" \
    '{
      meta: {
        input: $input, host: $host, ports_scanned: $ports,
        started_at: $started_at, finished_at: $finished_at,
        elapsed_seconds: $elapsed,
        banner_grabs_enabled: ($did_banner == 1)
      },
      open_tcp_ports: $open,
      banners: $banners
    }' > "$REPORT_JSON"

printf '\n%s=== Recommended next-step probes (deep dive per port) ===%s\n' "$C_YELLOW" "$C_OFF"
jq -r --arg host "$HOST" '
    .banners[]?
    | .port as $p
    | (.first_line // "")
    | if   test("^SSH-")             then "  ssh://\($host):\($p)         → url-triage.sh ssh://\($host):\($p)"
      elif test("^220 ")             then "  smtp://\($host):\($p)        → url-triage.sh smtp://\($host):\($p)"
      elif test("^\\* OK")           then "  imap://\($host):\($p)        → url-triage.sh imap://\($host):\($p)"
      elif test("^\\+OK")            then "  pop3://\($host):\($p)        → url-triage.sh pop3://\($host):\($p)"
      elif $p == 80                  then "  http://\($host):\($p)        → url-triage.sh http://\($host)"
      elif $p == 443                 then "  https://\($host):\($p)       → url-triage.sh https://\($host)"
      elif $p == 465                 then "  smtps://\($host):\($p)       → url-triage.sh smtps://\($host):\($p)"
      elif $p == 587                 then "  submission://\($host):\($p)  → url-triage.sh smtp://\($host):\($p) (STARTTLS auto)"
      elif $p == 993                 then "  imaps://\($host):\($p)       → url-triage.sh imaps://\($host):\($p)"
      elif $p == 995                 then "  pop3s://\($host):\($p)       → url-triage.sh pop3s://\($host):\($p)"
      else "  tcp://\($host):\($p)          → url-triage.sh tcp://\($host):\($p)"
      end
' "$REPORT_JSON"

printf '\n%s== scan done in %ss  ·  artifacts: %s ==%s\n' \
       "$C_BOLD" "$ELAPSED" "$OUT_DIR" "$C_OFF"
