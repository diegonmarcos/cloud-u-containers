#!/usr/bin/env bash
# test-layer-deadlines.sh — no probe may hang the 11-layer health report.
#
# THE FAILURE THIS GUARDS
#   `health_full2::run` fans L4-L11 out through `tokio::join!`, which waits for
#   ALL of its futures. Not one of the five had a deadline, and three of them
#   (L8 `gh run list`, L10 `openssl s_client`, L11 IMAP `poll_once`) contained
#   awaits with no timeout at all. One wedged probe therefore hung the entire
#   health report forever, with no output and no error:
#     * run 35022084038 sat 3h43m between the L3 line and the L4-L11 line and
#       had to be cancelled by hand, holding the `health-reports` concurrency
#       lock and cancelling every scheduled run behind it;
#     * run 35041138252 reproduced it and was killed at 20 minutes by the
#       step-level `timeout` (exit 124). Its log is what named the culprit:
#       `[email_e2e] imap transient error` printed 441s into a 180s budget,
#       and `L4-L11 parallel:` never printed at all.
#
# WHY A SOURCE-LEVEL TESTER
#   This is a static/structural gate, and deliberately so: it runs anywhere
#   bash and grep exist, including the report container and a CI checkout with
#   no Rust toolchain. The BEHAVIOURAL proof — that the deadline actually fires
#   and that the check it emits is loud — lives in `health_full2::tests` and is
#   executed by `cargo test` in the Dockerfile builder stage. Neither replaces
#   the other: this one catches "someone added a sixth layer to the join! and
#   forgot to wrap it", which no unit test can see.
#
# Usage:  test-layer-deadlines.sh [SRC_ROOT]
#         SRC_ROOT defaults to the workspace root two levels up from this file.
#         Passing an alternative root is how the fix was mutation-proved: point
#         it at a pre-fix checkout and every assertion below must go RED.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${1:-$(cd "$HERE/.." && pwd)}"

MOD="$SRC_ROOT/cloud-health-full-daily/src/health_full2/mod.rs"
LAYERS="$SRC_ROOT/cloud-health-full-daily/src/health_full2/layers.rs"
E2E="$SRC_ROOT/reports-common/src/email_e2e.rs"

FAILS=0
ok()   { echo "✓ $*"; }
bad()  { echo "✗ $*"; FAILS=$((FAILS + 1)); }

for f in "$MOD" "$LAYERS" "$E2E"; do
    [ -f "$f" ] || { echo "✗ source not found: $f"; exit 1; }
done

echo "── layer deadlines (root: $SRC_ROOT) ──"

# ── 1. Every future inside the L4-L11 tokio::join! carries its own deadline ──
# Extracted by line range rather than by a whole-file grep: a `with_deadline`
# mentioned anywhere else in the file must not be able to satisfy this.
join_body=$(awk '/tokio::join!\(/{f=1} f{print} f&&/^    \);/{exit}' "$MOD")
join_futs=$(echo "$join_body" | grep -c 'layers::layer_')
join_wrapped=$(echo "$join_body" | grep -c 'with_deadline(')

if [ "$join_futs" -eq 0 ]; then
    bad "no layer futures found inside the tokio::join! — did the join move?"
elif [ "$join_futs" -eq "$join_wrapped" ]; then
    ok "all $join_futs futures in the L4-L11 join! are wrapped in with_deadline"
else
    bad "$((join_futs - join_wrapped)) of $join_futs futures in the L4-L11 join! have NO deadline"
    echo "$join_body" | grep 'layers::layer_' | grep -v 'with_deadline(' | sed 's/^/      /'
fi

# ── 2. One deadline per layer, not one around the whole join ──
# A single timeout around the join tells you the report hung but not WHICH
# layer hung — that ambiguity is why this defect survived two investigations.
if [ "$join_wrapped" -ge 5 ]; then
    ok "deadlines are PER LAYER ($join_wrapped distinct), not one around the join"
else
    bad "expected >=5 per-layer deadlines inside the join, found $join_wrapped"
fi

# ── 3. A timed-out layer is LOUD, not a silent empty vec ──
# An empty Vec<Check> reads downstream as "this layer found zero problems",
# which reproduces the original defect one level down.
arm=$(awk '/async fn with_deadline/{f=1} f{print} f&&/^}/{c++; if(c>0 && /^}/) exit}' "$MOD")
if [ -z "$arm" ]; then
    bad "with_deadline() not found in mod.rs — the layers have no deadline helper"
else
    if echo "$arm" | grep -q 'Severity::Critical'; then
        ok "timeout arm emits Severity::Critical (reaches summary.critical + Dagu ntfy)"
    else
        bad "timeout arm does not emit Severity::Critical — the timeout will be quiet"
    fi
    if echo "$arm" | grep -q 'passed: false'; then
        ok "timeout arm emits passed:false (not a healthy zero)"
    else
        bad "timeout arm does not emit passed:false — a wedged layer would read as healthy"
    fi
    if echo "$arm" | grep -qE 'vec!\[Check'; then
        ok "timeout arm returns a Check, not an empty vec (layer is not silently dropped)"
    else
        bad "timeout arm does not return a Check — the layer is silently dropped"
    fi
    if echo "$arm" | grep -q 'name: format!("LAYER TIMEOUT: {}", layer)'; then
        ok "the emitted check NAMES the layer that wedged"
    else
        bad "the emitted check does not name the layer — you would be back here a third time"
    fi
fi

# ── 4. No unbounded subprocess await inside the layer engine ──
# `openssl s_client` and `gh` have no connect/read deadline of their own; a
# bare `.output().await` on either blocks the process forever.
# The wrap is written as `timeout(SUBPROCESS_TIMEOUT, Command::new(...)...)`,
# so the `timeout(` token PRECEDES `Command::new`. Walk back from each
# `.output()` and require a `timeout(` in the preceding window.
bare=$(awk '
    /\.output\(\)/ {
        found=0
        for (i = NR-14; i < NR; i++) if (i in line && line[i] ~ /timeout\(/) found=1
        if (!found) {
            for (i = NR-14; i < NR; i++) if (i in line && line[i] ~ /Command::new/) print i": "line[i]
        }
    }
    { line[NR] = $0 }
' "$LAYERS")
if [ -z "$bare" ]; then
    ok "every shelled-out probe in layers.rs is wrapped in a timeout"
else
    bad "unbounded subprocess await(s) in layers.rs — these can hang forever:"
    echo "$bare" | sed 's/^/      /'
fi

# ── 5. The mail round-trip's declared timeout is actually enforced ──
# poll_inbox's deadline was only consulted BETWEEN attempts; poll_once itself
# had no deadline, so one stalled attempt never re-evaluated the loop
# condition. 441s inside one attempt against a 180s budget, measured.
poll=$(awk '/async fn poll_inbox/{f=1} f{print} f&&/^}/{exit}' "$E2E")
if echo "$poll" | grep -q 'timeout(' ; then
    ok "poll_inbox bounds each poll_once ATTEMPT, not just the loop"
else
    bad "poll_inbox does not bound a single poll_once attempt — its declared"
    bad "  timeout_secs budget is unenforceable and L11 can hang indefinitely"
fi

# ── 6. L11 keeps a budget above the declared mail round-trip ──
# #342 ("Health Mail Full" red: maddy=178s / stalwart=181s vs gmail=32s) is a
# TRUE positive. A layer deadline at or under those numbers would erase it.
if grep -q 'EMAIL_LAYER_MARGIN' "$MOD" && grep -q 'load_config()' "$MOD"; then
    ok "L11's budget is derived from the declared timeout_secs + a margin"
else
    bad "L11 shares the generic layer deadline — it would guillotine the mail"
    bad "  round-trip and make the #342 red disappear"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "PASS — no layer of the 11-layer report can hang it."
    exit 0
fi
echo "FAIL — $FAILS assertion(s) failed. A wedged probe can still hang the whole report."
exit 1
