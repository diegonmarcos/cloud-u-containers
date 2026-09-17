#!/bin/bash
# cloud-analytics-daily — build + send the Umami and Matomo daily reports.
#
#   build.sh link            no-op — this crate has no cargo binary to symlink
#   build.sh build|run|all   generate dist/cloud_analytics_{umami,matomo}.{md,html}
#                            and write the ANALYTICS outcome keys into
#                            dist/_run_state.json (the orchestrator's vacuity
#                            guard reads those keys; without them a run of this
#                            crate alone could not prove it verified anything)
#   build.sh send            mail each of the ALREADY GENERATED reports — the
#                            guarded half of `ship` (see below); never generates
#   build.sh ship            build + send in one — sits on the DIRECT crate
#                            path and therefore bypasses the orchestrator's
#                            vacuity guards (#392); the Dagu DAGs no longer use
#                            it, and new callers should use the guarded
#                            entrypoint target (`daily-mail`-style split)
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
  # A dead engine must not take the other one's report down with it — but it
  # must not erase its own diagnosis either. The query scripts emit ##ENGINE
  # first and unconditionally ("database|DOWN", "<container>|missing") so a dead
  # collector never reads like a quiet day; truncating the output on a non-zero
  # exit threw exactly those rows away and mailed an all-empty report. Keep
  # whatever was captured and add the failure itself as one more engine row.
  local ok=1
  if ! "$HERE/src/$2" > "$DIST/.$3.raw" 2>"$DIST/.$3.err"; then
    ok=0
    ERR=$(tail -1 "$DIST/.$3.err" 2>/dev/null | tr '|' '/')
    echo "[analytics] WARN: $1 query failed — $ERR" >&2
    printf '##ENGINE\nquery|FAILED — %s\n' "${ERR:-no error output}" >> "$DIST/.$3.raw"
  fi
  # OK means the ENGINE answered, not that the script exited 0 — a query
  # script that ran but whose database is down still exits 0 (its failures are
  # diagnosed, not fatal). The ##ENGINE contract is the honest signal:
  # `database|reachable` is emitted only when the engine's DB answered.
  if ! grep -q '^database|reachable' "$DIST/.$3.raw" 2>/dev/null; then
    ok=0
  fi
  "$HERE/src/render.sh" "$1" "$DIST/cloud_analytics_$3.md" "$DIST/cloud_analytics_$3.html" < "$DIST/.$3.raw"
  rm -f "$DIST/.$3.raw" "$DIST/.$3.err"
  eval "ANALYTICS_${3}_OK=$ok"
}

# ── Outcome keys in _run_state.json ──────────────────────────────────────
# #392: the orchestrator's `require_probe_reached` guard (reports/src/build.sh
# cmd_one) evaluates a run by the keys it wrote into the shared snapshot — any
# `passed` or `*_ok` key, at any depth, in a section the run changed. This
# crate used to write ONLY .md/.html, so a standalone analytics run recorded no
# outcome keys and the guard could not tell a live run from a dead one. It now
# merges an `analytics` section carrying one `*_ok` per engine plus a `passed`
# count into dist/_run_state.json, coordinated on the SAME lock file the Rust
# `merge_section` uses (._run_state.json.lock, flock) so derives running in
# parallel in the daily fan-out never lose each other's writes.
#
# The graph edge cases are deliberate:
#   - on a cloud-security / GHA run that cannot reach the engines, both
#     *_ok are false -> passed:0 -> the guard fails the run: an analytics
#     report that queried nothing must not publish as a clean bill of health.
#   - one engine dead, other alive -> passed:1 -> the run verified something,
#     and the report itself still shows the dead engine (##ENGINE rows).
#   - checked_at is INSIDE the section so two healthy consecutive runs differ
#     (the guard reads the DELTA against the previous snapshot; a section that
#     is byte-identical to last run is not this run's evidence).
write_run_state() {
  local umami_ok="${ANALYTICS_umami_OK:-0}"
  local matomo_ok="${ANALYTICS_matomo_OK:-0}"
  local passed=0 total_engines=2
  [ "$umami_ok" = "1" ] && passed=$((passed + 1))
  [ "$matomo_ok" = "1" ] && passed=$((passed + 1))
  local umami_bool matomo_bool
  [ "$umami_ok" = "1" ] && umami_bool=true || umami_bool=false
  [ "$matomo_ok" = "1" ] && matomo_bool=true || matomo_bool=false
  local state="$DIST/_run_state.json"
  local lock="$DIST/._run_state.json.lock"
  local tmp state_tmp
  tmp="$(mktemp "$DIST/._analytics_state.XXXXXX")"
  state_tmp="$DIST/_run_state.json.tmp.$$"
  : > "$lock" 2>/dev/null || true
  (
    flock 9
    jq -n \
      --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
      --argjson umami_ok "${umami_bool}" \
      --argjson matomo_ok "${matomo_bool}" \
      --argjson passed "${passed}" \
      --argjson total_engines "${total_engines}" \
      '{checked_at: $checked_at, umami_ok: $umami_ok, matomo_ok: $matomo_ok,
        passed: $passed, total_engines: $total_engines}' > "$tmp"
    if [ -f "$state" ]; then
      jq --slurpfile a "$tmp" \
         '.analytics = $a[0] | .generated_at = $a[0].checked_at' "$state" \
         > "$state_tmp" && mv -f "$state_tmp" "$state"
    else
      jq -n --slurpfile a "$tmp" \
         '{version: 1, generated_at: $a[0].checked_at, analytics: $a[0]}' \
         > "$state_tmp" && mv -f "$state_tmp" "$state"
    fi
  ) 9>"$lock"
  rm -f "$tmp" "$lock" "$state_tmp"
  echo "[analytics] run_state analytics section: umami_ok=$umami_ok matomo_ok=$matomo_ok passed=$passed/$total_engines"
}

send_all() { # mail each report; non-zero when any send fails
  local RC=0 e
  for e in umami matomo; do
    L=$(echo "$e" | sed 's/^./\U&/')
    MAIL_SUBJECT="Cloud Analytics Report ($L) - $DATE" \
      "$SENDER" "$DIST/cloud_analytics_$e.html" || RC=1
  done
  return $RC
}

case "${1:-build}" in
  link)
    ;;
  build|run|all)
    gen "Umami"  umami-query.sh  umami
    gen "Matomo" matomo-query.sh matomo
    write_run_state
    ;;
  send)
    send_all
    ;;
  ship)
    "$0" build
    send_all
    ;;
  *) echo "usage: build.sh {link|build|run|all|send|ship}" >&2; exit 2;;
esac