#!/bin/bash
# cloud-analytics-daily — build + send the Umami and Matomo daily reports.
#
#   build.sh link            no-op — this crate has no cargo binary to symlink
#   build.sh build|run|all   generate dist/cloud_analytics_{umami,matomo}.{md,html}
#   build.sh ship            build, then mail each report (reuses the ops sender)
#
# link/run/all exist because reports/src/build.sh discovers EVERY cloud-*/ dir
# with an executable build.sh and drives them through the _crate_engine.sh verb
# contract: Phase 0b calls `link` on every crate, Phase 2 calls `run` on every
# derive. This crate is shell-only (no Rust binary), but it must still answer
# those verbs — otherwise its `usage:` branch exits 2 under the orchestrator's
# `set -eu` and takes the whole daily run down with it.
#
# Two reports, not one: the engines are independent collectors and the whole
# point of running both is being able to see them disagree. Merging them into a
# single document would hide exactly the discrepancy worth looking at.
set -eu

# $0, not ${BASH_SOURCE[0]}: the reports entrypoint invokes this with sh
# (dash), where the bash array syntax is a parse error — "build.sh: 12: Bad
# substitution", which killed both Cloud Health Reports runs (ARM + x86) and
# only ever surfaced as a bare `usage:` line. $0 is correct in bash and dash
# alike for a script that is executed rather than sourced.
HERE="$(cd "$(dirname "$0")" && pwd)"
DIST="${DIST_DIR:-$HERE/../../dist}"
SENDER="$HERE/../cloud-health-full-daily/src/send.sh"
DATE=$(date '+%Y-%m-%d')
WINDOW_H="${WINDOW_H:-24}"
export WINDOW_H

mkdir -p "$DIST"

gen() { # $1 engine label, $2 query script, $3 slug
  echo "[analytics] querying $1 …"
  # A dead engine must not take the other one's report down with it: emit an
  # empty section set and let render.sh print "No data in this window."
  if ! "$HERE/src/$2" > "$DIST/.$3.raw" 2>"$DIST/.$3.err"; then
    echo "[analytics] WARN: $1 query failed — $(tail -1 "$DIST/.$3.err" 2>/dev/null)" >&2
    : > "$DIST/.$3.raw"
  fi
  "$HERE/src/render.sh" "$1" "$DIST/cloud_analytics_$3.md" "$DIST/cloud_analytics_$3.html" < "$DIST/.$3.raw"
  rm -f "$DIST/.$3.raw" "$DIST/.$3.err"
}

case "${1:-build}" in
  link)
    ;;
  build|run|all)
    gen "Umami"  umami-query.sh  umami
    gen "Matomo" matomo-query.sh matomo
    ;;
  ship)
    "$0" build
    RC=0
    for e in umami matomo; do
      L=$(echo "$e" | sed 's/^./\U&/')
      MAIL_SUBJECT="Cloud Analytics Report ($L) - $DATE" \
        "$SENDER" "$DIST/cloud_analytics_$e.html" || RC=1
    done
    exit $RC
    ;;
  *) echo "usage: build.sh {link|build|run|all|ship}" >&2; exit 2;;
esac
