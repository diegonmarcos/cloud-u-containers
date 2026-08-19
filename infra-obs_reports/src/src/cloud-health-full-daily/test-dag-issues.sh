#!/usr/bin/env bash
# test-dag-issues.sh — verify the cloud-health-full-daily rust crate
# surfaces failed Dagu DAGs as Issue records the same way it does GHA.
#
# Regression: the report collected `dags[]` but the issue loop only
# iterated vms / containers / endpoints / certs / gha — DAGs were
# invisible in `exec_summary.all_issues`. With 21/29 DAGs failing
# (health_*, ops_*, security_*, sync_*) that was a huge debug blind
# spot — the user explicitly flagged it.
#
# This tester asserts:
#   1. Source has a `for dag in &dags` block in the issues loop
#      pushing `Issue { kind: "dag" }`.
#   2. The status mapping covers the API's known states (succeeded,
#      failed, running) plus a fallback for cancelled/queued/etc.
#   3. The freshly produced cloud_health_daily.json contains at least
#      one `kind == "dag"` issue when at least one DAG status is
#      "failed". (Run a build first; this checks the output.)

set -euo pipefail

CRATE_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$CRATE_DIR/src/main.rs"
DIST_JSON="${DIST_JSON:-$CRATE_DIR/../../dist/cloud_health_daily.json}"
FAILS=0

# 1. Source-level: dag iteration exists
if grep -q 'for dag in &dags' "$SRC"; then
    echo "✓ source has Dagu iteration in issues loop"
else
    echo "✗ source missing 'for dag in &dags' — DAGs not surfaced as issues"
    FAILS=$((FAILS + 1))
fi

# 2. Source-level: kind == "dag" pushed
if grep -q 'kind: "dag".into()' "$SRC"; then
    echo "✓ source pushes Issue with kind: dag"
else
    echo "✗ source does not push kind: dag"
    FAILS=$((FAILS + 1))
fi

# 3. Source-level: covers failed/succeeded/running + fallback
for state in '"failed"' '"succeeded"' '"running"'; do
    if grep -q "$state" "$SRC"; then
        echo "✓ source handles $state"
    else
        echo "✗ source missing handler for $state"
        FAILS=$((FAILS + 1))
    fi
done

# 4. Output-level (if a report has been produced): every failed DAG
# in .dags[] also appears in .exec_summary.all_issues with kind == "dag".
if [ -f "$DIST_JSON" ]; then
    failed_dags=$(jq -r '[.dags[]? | select(.status == "failed") | .name] | sort' "$DIST_JSON")
    issue_dags=$(jq -r '[.exec_summary.all_issues[]? | select(.kind == "dag" and .severity == "CRIT") | .entity] | sort' "$DIST_JSON")
    failed_count=$(printf '%s' "$failed_dags" | jq 'length')
    issue_count=$(printf '%s' "$issue_dags" | jq 'length')
    if [ "$failed_count" -gt 0 ]; then
        if [ "$failed_dags" = "$issue_dags" ]; then
            echo "✓ output: $failed_count failed DAGs all surface as kind:dag CRIT issues"
        else
            echo "✗ output: failed DAG list differs from kind:dag CRIT issue list"
            echo "  failed DAGs: $failed_dags"
            echo "  CRIT issues: $issue_dags"
            FAILS=$((FAILS + 1))
        fi
    else
        echo "ℹ output: no failed DAGs in this snapshot ($failed_count) — nothing to assert"
    fi
else
    echo "ℹ output: $DIST_JSON not present (run reports/build.sh health-full-daily first to verify output side)"
fi

if [ "$FAILS" -eq 0 ]; then
    echo "test-dag-issues: PASS"
    exit 0
else
    echo "test-dag-issues: FAIL ($FAILS check(s))"
    exit 1
fi
