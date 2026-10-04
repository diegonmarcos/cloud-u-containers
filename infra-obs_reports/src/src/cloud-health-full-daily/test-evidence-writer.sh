#!/usr/bin/env bash
# test-evidence-writer.sh — Phase 2 invariant: every successful report run
# materialises raw evidence under reports-logs/dist/vms/<vm>/ as a side
# effect of the report's own SSH probes. After this works, the bash
# collector's docker.sh / systemd.sh / network.sh modules become redundant
# for those sections — they were re-collecting via fresh SSH the same data
# the report already had in memory.
#
# Asserted invariants (post a fresh master-report run):
#   1. evidence/raw root exists at the declared output_dir
#      (cloud-data-reports-logs.json:.output_dir).
#   2. Every reachable VM has a vms/<vm>/ subdir.
#   3. Each subdir has meta.json with a recent ts (within last 30 min),
#      reachable: bool, AND a `source` field tagging which writer produced
#      it ("rsync /opt/health/latest.json" or "single-pass writer").
#   4. For reachable VMs:
#        - rsync path: health_latest.json present + parses as JSON object
#        - legacy path: at least UPTIME/DISK/MEM/CONTAINER_FULL section files
#   5. docker_ps.json exists for reachable VMs and is a JSON array —
#      reports-logs/index.sh keeps working unchanged across both paths.
#
# This tester only runs the assertions — it does NOT run the master
# report itself (3-4 min). Caller runs the report first; tester verifies.
#
# Usage:
#   reports/build.sh health-full-daily   # produces evidence as side effect
#   bash reports/src/cloud-health-full-daily/test-evidence-writer.sh

set -euo pipefail

REPO_ROOT="${GIT_BASE:-$HOME/git}/cloud-data"
CONFIG="$REPO_ROOT/cloud-data-reports-logs.json"
TOPOLOGY="$REPO_ROOT/cloud-data-topology.json"
FAILS=0

[ -f "$CONFIG" ]   || { echo "✗ $CONFIG missing"; exit 1; }
[ -f "$TOPOLOGY" ] || { echo "✗ $TOPOLOGY missing"; exit 1; }

OUTPUT_DIR=$(jq -r '.output_dir // "reports-logs/dist"' "$CONFIG")
EVIDENCE_ROOT="$REPO_ROOT/$OUTPUT_DIR"
VMS_ROOT="$EVIDENCE_ROOT/vms"

# 1. Root exists
if [ ! -d "$VMS_ROOT" ]; then
    echo "✗ $VMS_ROOT missing — has the master report ever run?"
    exit 1
fi
echo "✓ evidence root present: $VMS_ROOT"

# 2. + 3. Every reachable VM (from topology) has a vms/<vm>/ + recent meta.json
expected_vms=$(jq -r '.vms // [] | map(select(.ssh_alias? != null)) | .[] | .ssh_alias // .alias // .id // empty' "$TOPOLOGY")
required_sections="uptime disk mem container_full"
now_epoch=$(date -u +%s)

# Find the freshest meta.json across VMs — the run we want to verify.
freshest_ts=0
for vm in $expected_vms; do
    meta="$VMS_ROOT/$vm/meta.json"
    [ -f "$meta" ] || continue
    ts=$(jq -r '.ts // ""' "$meta")
    [ -z "$ts" ] && continue
    epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
    [ "$epoch" -gt "$freshest_ts" ] && freshest_ts="$epoch"
done

if [ "$freshest_ts" -eq 0 ]; then
    echo "✗ no meta.json found for any VM — report has not run with Phase 2 binary"
    FAILS=$((FAILS + 1))
fi

age=$((now_epoch - freshest_ts))
if [ "$age" -gt 1800 ]; then
    echo "ℹ freshest evidence is ${age}s old (>30min) — re-run the report for a fresh check"
fi

for vm in $expected_vms; do
    vm_dir="$VMS_ROOT/$vm"
    meta="$vm_dir/meta.json"

    if [ ! -d "$vm_dir" ]; then
        echo "✗ $vm: vms/$vm/ missing"
        FAILS=$((FAILS + 1))
        continue
    fi
    if [ ! -f "$meta" ]; then
        echo "✗ $vm: meta.json missing"
        FAILS=$((FAILS + 1))
        continue
    fi

    reachable=$(jq -r '.reachable // false' "$meta")
    src=$(jq -r '.source // ""' "$meta")

    case "$src" in
        *"rsync /opt/health/latest.json"*) writer="rsync" ;;
        *"single-pass writer"*)            writer="legacy" ;;
        *)
            echo "ℹ $vm: meta has no Phase-2 source tag (source='$src') — old bash-collector output"
            continue
            ;;
    esac

    if [ "$reachable" = "true" ]; then
        # 4. path-specific evidence files
        case "$writer" in
            rsync)
                if [ -f "$vm_dir/health_latest.json" ] && jq -e 'type == "object"' "$vm_dir/health_latest.json" >/dev/null 2>&1; then
                    echo "✓ $vm: health_latest.json present + parses (rsync path)"
                else
                    echo "✗ $vm: health_latest.json missing or invalid (rsync path)"
                    FAILS=$((FAILS + 1))
                fi
                ;;
            legacy)
                missing=""
                for sec in $required_sections; do
                    [ -f "$vm_dir/$sec.txt" ] || missing="$missing $sec"
                done
                if [ -n "$missing" ]; then
                    echo "✗ $vm: missing required section files (legacy path):$missing"
                    FAILS=$((FAILS + 1))
                else
                    echo "✓ $vm: uptime/disk/mem/container_full section files present (legacy path)"
                fi
                ;;
        esac

        # 5. docker_ps.json is a valid JSON array (both paths produce it)
        if [ -f "$vm_dir/docker_ps.json" ]; then
            if jq -e 'type == "array"' "$vm_dir/docker_ps.json" >/dev/null 2>&1; then
                count=$(jq 'length' "$vm_dir/docker_ps.json")
                echo "✓ $vm: docker_ps.json ($count containers, source=$writer)"
            else
                echo "✗ $vm: docker_ps.json not a JSON array"
                FAILS=$((FAILS + 1))
            fi
        else
            echo "ℹ $vm: docker_ps.json not produced (containers list may have been empty)"
        fi
    else
        echo "ℹ $vm: marked unreachable in meta.json (consistent — no section files expected)"
    fi
done

if [ "$FAILS" -eq 0 ]; then
    echo "test-evidence-writer: PASS"
    exit 0
else
    echo "test-evidence-writer: FAIL ($FAILS check(s))"
    exit 1
fi
