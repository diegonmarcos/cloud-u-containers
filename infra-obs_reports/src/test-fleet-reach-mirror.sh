#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║ The fleet-reachability mirror must not drift (#391 / #385)        ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# "Which VM states count as reached" is written TWICE:
#
#   authority   src/reports-common/src/fleet.rs  VmState::is_reachable()
#   mirror      src/build.sh                     require_hosts_reached()'s jq
#
# The second exists because the vacuity guard that decides a report run's exit
# status is read live from the repository checkout, while the first is compiled
# into the prebuilt image. Nothing but agreement links them.
#
# WHY THE DRIFT IS DANGEROUS IN BOTH DIRECTIONS
#   mirror NARROWER than authority — the guard fails a run on a fleet the
#     binary reached. That is exactly what #391 looked like from the outside:
#     `hosts reached: 0 of 4` printed by a run whose own log said
#     `L2 WG Mesh: 4/4 reachable`, `L3 Platform: ssh=4/4 docker=4/4` and
#     `SSH oci-apps OK (16483 bytes)`. Four red mornings blamed on the mesh.
#   mirror WIDER than authority — the guard passes a run that reached nothing,
#     and #385's vacuity guard silently becomes the check-that-cannot-fail it
#     was written to abolish. Eight consecutive green reports from a runner
#     with no route to the mesh is the incident that bought that guard.
#
# So this tester does not check a behaviour; it checks that two independent
# spellings of one rule still name the same set. It reads the variant names out
# of BOTH files and compares the sets. It has no opinion on what the set should
# contain — add a reachable state and it tells you about the OTHER file.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RS="$HERE/src/reports-common/src/fleet.rs"
SH="$HERE/src/build.sh"
rc=0
ok()   { printf '  [ok] %s\n' "$1"; }
nope() { printf '  [FAIL] %s\n' "$1"; rc=1; }

echo "test-fleet-reach-mirror: $RS  <->  $SH"

for f in "$RS" "$SH"; do
    [ -f "$f" ] || { echo "  [FAIL] missing $f"; exit 2; }
done

# ── Authority: the variants named inside is_reachable()'s matches!(...) ──
# Bounded to the function body so an unrelated `VmState::Terminated` elsewhere
# in the file cannot leak in. A body that yields zero variants is a parse
# failure, not an empty rule — fail loudly rather than compare {} to {}.
RS_BODY=$(awk '/pub fn is_reachable/{f=1} f{print} f&&/^    }$/{exit}' "$RS")
RS_SET=$(printf '%s\n' "$RS_BODY" \
         | grep -o 'VmState::[A-Za-z]*' | sed 's/VmState:://' | sort -u)
if [ -z "$RS_SET" ]; then
    nope "could not extract any variant from is_reachable() in fleet.rs — the awk range or the signature changed"
    echo "test-fleet-reach-mirror: FAIL"; exit 1
fi
ok "authority set read from is_reachable(): $(echo "$RS_SET" | tr '\n' ' ')"

# ── Mirror: the variants the jq select() accepts ──────────────────────
# Read from the `reached=$(jq ...)` expression only, and from CODE lines: the
# comments above it discuss variants by name (including ones that are NOT
# reachable, like Unknown) and would poison the set.
SH_EXPR=$(awk '/reached=\$\(jq /{f=1} f{ if ($0 !~ /^[[:space:]]*#/) print } f&&/length.*RUN_STATE/{exit}' "$SH")
# Two spellings appear in the jq: a quoted name (`. == "Running"`,
# `has("RunningUnverified")`) and a field access (`.Client.tcp_up == true`).
# Matching only the quoted form silently dropped Client and reported a drift
# that did not exist — a mirror tester that lies about the mirror.
SH_SET=$(printf '%s\n' "$SH_EXPR" \
         | grep -oE '"[A-Z][A-Za-z]*"|\.[A-Z][A-Za-z]*' \
         | tr -d '".' | sort -u)
if [ -z "$SH_SET" ]; then
    nope "could not extract any variant from require_hosts_reached()'s jq in build.sh"
    echo "test-fleet-reach-mirror: FAIL"; exit 1
fi
ok "mirror set read from the guard's jq: $(echo "$SH_SET" | tr '\n' ' ')"

# ── The comparison ───────────────────────────────────────────────────
MISSING_IN_SH=$(comm -23 <(printf '%s\n' "$RS_SET") <(printf '%s\n' "$SH_SET"))
MISSING_IN_RS=$(comm -13 <(printf '%s\n' "$RS_SET") <(printf '%s\n' "$SH_SET"))

if [ -n "$MISSING_IN_SH" ]; then
    nope "reachable in fleet.rs but NOT accepted by the guard's jq: $(echo "$MISSING_IN_SH" | tr '\n' ' ')"
    echo "       -> the guard will fail runs on a fleet the binary reached (#391)."
else
    ok "every state fleet.rs calls reachable is accepted by the guard"
fi

if [ -n "$MISSING_IN_RS" ]; then
    nope "accepted by the guard's jq but NOT reachable in fleet.rs: $(echo "$MISSING_IN_RS" | tr '\n' ' ')"
    echo "       -> the guard can pass a run that reached nothing (#385)."
else
    ok "the guard accepts nothing fleet.rs calls unreachable"
fi

# ── The guard must still be able to FAIL ─────────────────────────────
# A mirror check is satisfied by two files that both accept EVERYTHING, so
# assert the unreachable states are genuinely excluded. Terminated and Unknown
# are the two that must never count: Terminated is a positively powered-off VM,
# Unknown is the absence of evidence, and #391 was made of Unknown.
for must_not in Terminated Unknown; do
    if printf '%s\n' "$RS_SET" | grep -qx "$must_not"; then
        nope "fleet.rs counts $must_not as reachable — absence of evidence is not reach"
    elif printf '%s\n' "$SH_SET" | grep -qx "$must_not"; then
        nope "the guard's jq counts $must_not as reachable — absence of evidence is not reach"
    else
        ok "$must_not is reachable in neither half"
    fi
done

# ── The guard has no bypass ──────────────────────────────────────────
# Stated as a promise in build.sh's own header ("There is deliberately NO
# opt-out environment variable"). Unasserted, that promise is a comment.
if awk '/^require_hosts_reached\(\)/{f=1} f{print} f&&/^}$/{exit}' "$SH" \
   | grep -qE '(SKIP|ALLOW|IGNORE|DISABLE|FORCE)[A-Z_]*[:-]?=?|:-(1|true|yes)\}'; then
    nope "require_hosts_reached() looks like it grew an opt-out — a guard with a bypass is decoration"
else
    ok "require_hosts_reached() carries no opt-out switch"
fi

if [ "$rc" -eq 0 ]; then echo "test-fleet-reach-mirror: PASS"; else echo "test-fleet-reach-mirror: FAIL"; fi
exit "$rc"
