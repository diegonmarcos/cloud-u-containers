#!/bin/bash
# test.sh — a dead analytics engine must still say so in its report.
#
# Simulates the 2026-09 state: every engine container gone. `ssh` is stubbed to
# run the remote block locally and `docker` to fail, so each query script runs
# its real SQL path against nothing. The ##ENGINE rows those scripts emit first
# ("database|DOWN", "<container>|missing") are the only honest content such a
# report has; before this tester, build.sh threw them away whenever the query
# exited non-zero and the Umami mail went out with every section empty.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
printf '#!/bin/sh\nexec bash -s\n' > "$T/bin/ssh"
# echo, THEN exit 1 — the real `docker inspect` writes a bare newline to STDOUT
# before failing on an absent container. A stub that printed nothing made this
# tester pass against a query script whose rendered row was actually split in
# two ("| matomo-hybrid |  |" / "| missing |"), which only surfaced on the live
# system. A stub that does not reproduce the failure mode does not test it.
printf '#!/bin/sh\necho\nexit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/ssh" "$T/bin/docker"

PATH="$T/bin:$PATH" DIST_DIR="$T/dist" bash "$HERE/build.sh" build >/dev/null 2>&1

RC=0
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
