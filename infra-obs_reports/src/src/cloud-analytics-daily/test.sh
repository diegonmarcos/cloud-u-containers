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
printf '#!/bin/sh\nexit 1\n' > "$T/bin/docker"
chmod +x "$T/bin/ssh" "$T/bin/docker"

PATH="$T/bin:$PATH" DIST_DIR="$T/dist" bash "$HERE/build.sh" build >/dev/null 2>&1

RC=0
for e in umami matomo; do
  if grep -q 'database | DOWN' "$T/dist/cloud_analytics_$e.md"; then
    echo "PASS: $e report carries its engine state"
  else
    echo "FAIL: $e report lost its engine state"; RC=1
  fi
done
exit $RC
