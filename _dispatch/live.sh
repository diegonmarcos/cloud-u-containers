#!/bin/sh
# Which dispatched agents are alive in THIS container — the one answer the ship engine asks
# before it recreates an agent container.
#
# On 2026-10-01 cloud-agi-claude was recreated by three ordinary ships (01:25Z, 10:28Z,
# 11:32:52Z); the last one SIGKILLed six agents at once, mid-task, because nothing on the deploy
# path knew they existed. fire.sh now registers every agent in $LIVE/<slot> for its whole life;
# this script is the one reader. The engine pipes it into the container
# (`docker exec -i C sh -s -- <mode>`), so the copy that runs is the one at the SHIPPED sha,
# never the shared tree's possibly-stale checkout.
#
# Usage: live.sh [list | hold <until-epoch> | release]
#   list     print one line per live agent; nothing at all means drained.
#   hold     close admission until <until-epoch> (fire.sh refuses new agents while it holds),
#            THEN list. Marker first, list second: fire.sh registers first and checks second,
#            so an agent racing a drain is either listed here or refused there — never neither.
#   release  reopen admission now.
# A registered entry is live only while its pid is still that agent's fire.sh: a SIGKILLed
# container leaves entries behind, and a recycled pid must not read as an agent.
# Agents not registered at all (fired by a fire.sh older than the registry, or run.sh by hand)
# are still agents: a fire.sh/run.sh process for a slot with no live entry is listed as
# "unregistered" — the recreate kills those just the same.
#
# env DISPATCH_ROOT (default $AGENT_GIT_TREE) — the tree that holds _dispatch/; DISPATCH_PROC
# (default /proc) exists only so the tester can plant processes.
set -u

ROOT=${DISPATCH_ROOT:-${AGENT_GIT_TREE:-}}
[ -n "$ROOT" ] || { echo "live.sh: neither DISPATCH_ROOT nor AGENT_GIT_TREE is set" >&2; exit 2; }
LIVE=$ROOT/_dispatch/logs/live
PROC=${DISPATCH_PROC:-/proc}
HOLD=$LIVE/.draining

case "${1:-list}" in
  release) rm -f "$HOLD"; exit 0 ;;
  hold)    mkdir -p "$LIVE" && echo "${2:?hold needs an until-epoch}" > "$HOLD.tmp" && mv "$HOLD.tmp" "$HOLD" || exit 2 ;;
  list)    ;;
  *)       echo "live.sh: unknown mode: $1" >&2; exit 64 ;;
esac

cmd() { tr '\0' ' ' 2>/dev/null < "$PROC/$1/cmdline"; }
SEEN=" "
for f in "$LIVE"/*; do
  [ -f "$f" ] || continue
  # One line: slot=<s> engine=<e> repo=<r> model=<m> pid=<p> start=<t>
  E=$(cat "$f")
  S=${f##*/}
  P=$(echo "$E" | sed -n 's/.* pid=\([0-9]*\).*/\1/p')
  N=$(echo "$E" | sed -n 's/.* engine=\([^ ]*\).*/\1/p')
  case "$(cmd "$P")" in
    *"_dispatch/fire.sh $N $S "*) echo "$E"; SEEN="$SEEN$S " ;;
  esac
done
for p in "$PROC"/[0-9]*; do
  set -- $(cmd "${p##*/}" | sed -n 's#.*_dispatch/\(fire\|run\)\.sh \([^ ]*\) \([^ ]*\) .*#\2 \3#p')
  [ $# -eq 2 ] || continue
  case "$SEEN" in *" $2 "*) continue ;; esac
  echo "slot=$2 engine=$1 pid=${p##*/} unregistered"
  SEEN="$SEEN$2 "
done
