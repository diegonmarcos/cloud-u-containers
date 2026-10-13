#!/usr/bin/env bash
# test-matomo-ports.sh — matomo-hybrid must not bind a port another service owns.
#
# matomo-hybrid runs with network_mode: host, so EVERY listener inside it —
# including the "internal" 127.0.0.1 ones — lands in the host's port table.
# The ship engine evicts whatever container holds a port that a deploying
# service binds, and it matches by port only (not by address). On 2026-10-10
# matomo-nginx listened on 127.0.0.1:8081, c3-infra-api (10.0.0.6:8081) was
# deployed, and the engine `docker rm -f`-ed matomo-hybrid. Every later Ship
# skipped matomo as "unchanged", so it stayed gone.
#
# Checks (all static, no network, no secrets read):
#   1. no INTERNAL port matomo listens on (anything but ports.app) is declared
#      by another service deployed to the same host. ports.app itself is the
#      fleet allocation (caddy routes to it), so a clash there is reported as a
#      WARN for a human to re-allocate, not failed here;
#   2. the ports matomo listens on are its own build.json ports.app plus the
#      one internal matomo-nginx port, and every internal caller
#      (receiver proxy_pass, wake, import-inbox) points at that same port;
#   3. MariaDB never binds TCP (skip-networking), since 3306 belongs to
#      photoprism's MariaDB on the same host.
#
# Run from infra-obs_matomo/src (build.json tests cwd).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC="$(dirname "$SRC")"
REPO="$(dirname "$SVC")"
CFG="$SRC/code/config"
SCRIPTS="$SRC/code/scripts"
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok()   { echo "ok:   $*"; }

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }

app_port="$(jq -r '.ports.app' "$SVC/build.json")"
[[ "$app_port" =~ ^[0-9]+$ ]] || { echo "FAIL: build.json ports.app is not a number"; exit 1; }

# ── Ports matomo listens on ─────────────────────────────────────────────
# nginx:  `listen 8080 default_server;`  /  `listen 127.0.0.1:18081;`
# php-fpm: `listen = /run/...sock` (unix — ignored) or `listen = 127.0.0.1:9000`
mapfile -t listen_ports < <(
    {
        grep -hE '^[[:space:]]*listen[[:space:]]+[^=]' "$CFG"/*nginx*.conf \
            | sed -E 's/^[[:space:]]*listen[[:space:]]+//; s/[;[:space:]].*$//'
        grep -hE '^[[:space:]]*listen[[:space:]]*=' "$CFG"/*fpm*.conf \
            | sed -E 's/^[^=]*=[[:space:]]*//' | grep -v '^/' || true
    } | sed -E 's/.*://' | grep -E '^[0-9]+$' | sort -un
)
[ "${#listen_ports[@]}" -gt 0 ] || { echo "FAIL: found no listen ports — parser broken"; exit 1; }
echo "matomo listens on: ${listen_ports[*]} (ports.app=$app_port)"

internal_ports=()
for p in "${listen_ports[@]}"; do [ "$p" = "$app_port" ] || internal_ports+=("$p"); done
printf '%s\n' "${listen_ports[@]}" | grep -qx "$app_port" \
    && ok "receiver listens on ports.app ($app_port)" \
    || fail "no listener on ports.app $app_port — caddy would proxy a dead port"
[ "${#internal_ports[@]}" -eq 1 ] \
    && ok "exactly one internal port (${internal_ports[0]})" \
    || fail "expected exactly one internal port, got: ${internal_ports[*]:-none}"
internal="${internal_ports[0]:-}"

# ── 1. No collision with any other same-host service's declared ports ───
# Every number under a key containing "port" in any other build.json whose
# deploy.host is matomo's (a port on another VM cannot collide).
host="$(jq -r '.deploy.host' "$SVC/build.json")"
declare -A owner=()
while IFS=$'\t' read -r port svc; do
    owner[$port]+="$svc "
done < <(
    find "$REPO" -mindepth 2 -maxdepth 2 -name build.json -type f \
        -not -path "$SVC/*" -print0 |
    while IFS= read -r -d '' bj; do
        jq -r --arg s "$(basename "$(dirname "$bj")")" --arg h "$host" '
            select(.deploy.host == $h) |
            [.. | objects | to_entries[] | select(.key | test("port"; "i"))
                | .value | .. | numbers] | unique[] | "\(.)\t\($s)"' "$bj" 2>/dev/null || true
    done
)
[ "${#owner[@]}" -gt 0 ] || fail "found no ports in other build.json files — discovery broken"
for p in "${listen_ports[@]}"; do
    if [ -z "${owner[$p]:-}" ]; then
        ok "port $p is not declared by any other $host service"
    elif [ "$p" = "$app_port" ]; then
        echo "WARN: ports.app $p is also declared by: ${owner[$p]}(on $host) — fleet port allocation clash, re-allocate one of them"
    else
        fail "internal port $p is also declared by: ${owner[$p]}(on $host) — the host-networked matomo-hybrid would be evicted by their deploy"
    fi
done

# ── 2. Internal callers point at the internal listener ──────────────────
if [ -n "$internal" ]; then
    mapfile -t callers < <(
        grep -hoE '127\.0\.0\.1:[0-9]+' \
            "$CFG/receiver-nginx.conf" "$SCRIPTS/matomo-wake.sh" "$SCRIPTS/import-inbox.sh" \
            | sed 's/.*://' | sort -u
    )
    for c in "${callers[@]}"; do
        if [ "$c" = "$internal" ] || [ "$c" = "$app_port" ]; then
            ok "internal caller targets 127.0.0.1:$c"
        else
            fail "internal caller targets 127.0.0.1:$c but matomo-nginx listens on $internal"
        fi
    done
    grep -q "127.0.0.1:$internal" "$CFG/receiver-nginx.conf" \
        || fail "receiver-nginx.conf never proxies to the matomo-nginx port $internal"
fi

# ── 3. MariaDB stays off TCP ───────────────────────────────────────────
grep -qE '^[[:space:]]*skip[-_]networking[[:space:]]*(=[[:space:]]*(1|ON|on|true))?[[:space:]]*$' "$CFG/mariadb.cnf" \
    && ok "mariadb has skip-networking" \
    || fail "mariadb.cnf lacks skip-networking — it would bind host :3306"

if [ "$FAIL" -ne 0 ]; then echo "test-matomo-ports: FAILED"; exit 1; fi
echo "test-matomo-ports: PASSED"
