#!/bin/bash
# test.sh — a dead analytics engine must still say so in its report (#selection).
#
# Three behaviours, all asserted against the REAL build.sh with stubbed ssh/
# docker so the query scripts run their real SQL paths against nothing:
#
#   1. a dead engine is diagnosed, never hidden   (##ENGINE rows)
#   2. outcome keys: both engines dead  -> passed:0 (#392 — the vacuity guard
#      must be able to fail an analytics run that verified nothing)
#   3. outcome keys: both engines alive -> passed:2 (the guard must not
#      false-fire on a healthy run)
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
printf '#!/bin/sh\nexec bash -s\n' > "$T/bin/ssh"

# docker DEAD — reproduces the 2026-09 state (every engine container gone).
# echo, THEN exit 1 — the real `docker inspect` writes a bare newline to STDOUT
# before failing on an absent container. A stub that printed nothing made this
# tester pass against a query script whose rendered row was actually split in
# two ("| matomo-hybrid |  |" / "| missing |"), which only surfaced on the live
# system. A stub that does not reproduce the failure mode does not test it.
printf '#!/bin/sh\necho\nexit 1\n' > "$T/bin/docker.dead"
# docker ALIVE — answers `select 1;` (any engine's liveness probe) with the
# number one, and `inspect` with `running`, so both query scripts' ##ENGINE
# rows read reachable. Everything else still fails like the dead stub.
cat > "$T/bin/docker.alive" <<'STUB'
#!/bin/sh
# Every command exits 0, matching a live engine whose docker calls succeed;
# only the liveness probe and `inspect` get non-empty output. (The dead stub
# exits 1, matching absent containers. A stub is faithful to the case it fixes.)
for a in "$@"; do
  case "$a" in
    "select 1;") echo 1; exit 0 ;;
  esac
done
case "${1:-}" in
  inspect) echo "running"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/bin/ssh" "$T/bin/docker.dead" "$T/bin/docker.alive"

RC=0
run_build() { # $1 dist dir; PATH must already carry the stubs
  mkdir -p "$1"
  PATH="$T/bin:$PATH" DIST_DIR="$1" WINDOW_H=24 bash "$HERE/build.sh" build >/dev/null 2>&1
}

# ── fixture 1: BOTH engines dead ─────────────────────────────────────────
cp "$T/bin/docker.dead" "$T/bin/docker"
run_build "$T/dist"

STATE="$T/dist/_run_state.json"
if [ -f "$STATE" ]; then
  STATE_JSON=$(jq -c '.analytics // {}' "$STATE")
  UMAMI_OK=$(printf '%s' "$STATE_JSON" | jq -r '.umami_ok')
  MATOMO_OK=$(printf '%s' "$STATE_JSON" | jq -r '.matomo_ok')
  PASSED=$(printf '%s' "$STATE_JSON" | jq -r '.passed')
  # NOTE: `.umami_ok` not `.umami_ok // "missing"` — jq's // treats `false` as
  # absent, so false would read back as "missing" and defeat the assertion.
  if [ "$UMAMI_OK" = "false" ] && [ "$MATOMO_OK" = "false" ] && [ "$PASSED" = "0" ]; then
    echo "PASS: outcome keys with both engines dead (umami_ok=$UMAMI_OK matomo_ok=$MATOMO_OK passed=$PASSED) — the vacuity guard can fail the run"
  else
    echo "FAIL: outcome keys wrong — got $STATE_JSON, expected umami_ok=false matomo_ok=false passed=0"; RC=1
  fi
else
  echo "FAIL: build.sh did not write $STATE — the vacuity guard has nothing to evaluate"; RC=1
fi

# ── fixture 2: BOTH engines alive ────────────────────────────────────────
cp "$T/bin/docker.alive" "$T/bin/docker"
run_build "$T/dist2"
STATE2_JSON=$(jq -c '.analytics // {}' "$T/dist2/_run_state.json" 2>/dev/null || echo "{}")
PASSED2=$(printf '%s' "$STATE2_JSON" | jq -r '.passed')
UMAMI2=$(printf '%s' "$STATE2_JSON" | jq -r '.umami_ok')
if [ "$PASSED2" = "2" ] && [ "$UMAMI2" = "true" ]; then
  echo "PASS: healthy run records passed=2 umami_ok=true (guard does not false-fire)"
else
  echo "FAIL: healthy run wrote $STATE2_JSON — expected passed=2 umami_ok=true"; RC=1
fi

# ── fixture 1 again for the rendered-report half (original #selection test) ──
cp "$T/bin/docker.dead" "$T/bin/docker"
for e in umami matomo; do
  if grep -q 'database | DOWN' "$T/dist/cloud_analytics_$e.md"; then
    echo "PASS: $e report carries its engine state"
  else
    echo "FAIL: $e report lost its engine state"; RC=1
  fi

  # The OTHER half of the ##ENGINE contract, and the half that was never
  # asserted: a "<container>|missing" row. "database | DOWN" alone cannot tell
  # a reader WHICH engine died, and matomo-query.sh emitted its container rows
  # through `docker exec <c> supervisorctl`, which prints nothing at all when
  # the container is absent — so on 2026-09-16, with matomo-hybrid gone from
  # oci-apps entirely, the Matomo health table silently dropped all seven
  # process rows and still read as a well-formed report. umami-query.sh had
  # always looped over its declared containers and printed "missing"; this
  # asserts BOTH engines do, so the asymmetry cannot come back unnoticed.
  if grep -qE '^\| [A-Za-z0-9_-]+ \| missing \|' "$T/dist/cloud_analytics_$e.md"; then
    echo "PASS: $e report names the missing container"
  else
    echo "FAIL: $e report has no '<container> | missing' row — a dead engine reads as a quiet day"; RC=1
  fi
done
exit $RC