#!/usr/bin/env bash
# test-issues-dedup.sh — verify exec_summary.all_issues has no duplicates
# by (kind, entity, severity). Two known sources of duplicates that the
# fix at main.rs around `issues.retain(...)` collapses:
#
#   1. GHA: the same workflow failing N times in the gh run window emits
#      N identical Issue records — collapses to 1.
#   2. ENDPOINT: the same public URL declared in monitoring-targets +
#      caddy-routes + service.domain shows up N times — collapses to 1.
#
# Asserted on the live cloud_health_daily.json:
#   * Every (kind, entity, severity) tuple appears exactly once in all_issues.
#   * critical/warnings counts equal the deduped count of CRIT/WARN issues.
#   * issues_by_kind sums to all_issues.length.
#
# Caller: run reports/build.sh health-full-daily first, then this tester.

set -euo pipefail

REPO_ROOT="${GIT_BASE:-$HOME/git}/cloud-data"
JSON="$REPO_ROOT/reports/dist/cloud_health_daily.json"
FAILS=0

[ -f "$JSON" ] || { echo "✗ $JSON missing — run reports/build.sh health-full-daily"; exit 1; }

# 1. Dedup invariant
total=$(jq '.exec_summary.all_issues | length' "$JSON")
unique=$(jq '.exec_summary.all_issues | map([.kind, .entity, .severity]) | unique | length' "$JSON")
if [ "$total" -eq "$unique" ]; then
    echo "✓ all_issues are unique by (kind, entity, severity): $total entries"
else
    dup=$((total - unique))
    echo "✗ all_issues has $dup duplicate (kind, entity, severity) tuples ($total entries, $unique distinct)"
    jq -r '.exec_summary.all_issues
        | map([.kind, .entity, .severity])
        | group_by(.)
        | map(select(length > 1))
        | .[]
        | "    \(length)× \(.[0] | join("/"))"' "$JSON" | head -10
    FAILS=$((FAILS + 1))
fi

# 2. Counters match the deduped vec
crit_summary=$(jq '.exec_summary.critical' "$JSON")
warn_summary=$(jq '.exec_summary.warnings' "$JSON")
crit_actual=$(jq '[.exec_summary.all_issues[] | select(.severity == "CRIT")] | length' "$JSON")
warn_actual=$(jq '[.exec_summary.all_issues[] | select(.severity == "WARN")] | length' "$JSON")

if [ "$crit_summary" -eq "$crit_actual" ]; then
    echo "✓ exec_summary.critical ($crit_summary) matches deduped CRIT count"
else
    echo "✗ exec_summary.critical=$crit_summary but actual deduped CRIT=$crit_actual"
    FAILS=$((FAILS + 1))
fi
if [ "$warn_summary" -eq "$warn_actual" ]; then
    echo "✓ exec_summary.warnings ($warn_summary) matches deduped WARN count"
else
    echo "✗ exec_summary.warnings=$warn_summary but actual deduped WARN=$warn_actual"
    FAILS=$((FAILS + 1))
fi

# 3. issues_by_kind sums to all_issues.length
sum_kinds=$(jq '[.exec_summary.issues_by_kind | to_entries[] | .value] | add // 0' "$JSON")
if [ "$sum_kinds" -eq "$total" ]; then
    echo "✓ issues_by_kind sums to all_issues.length ($total)"
else
    echo "✗ issues_by_kind sums to $sum_kinds, all_issues has $total"
    FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-issues-dedup: PASS"
    exit 0
else
    echo "test-issues-dedup: FAIL ($FAILS check(s))"
    exit 1
fi
