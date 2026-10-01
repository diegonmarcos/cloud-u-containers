#!/bin/sh
# ONE fire script for every dispatch. Replaces the per-ticket fire-NNN-<engine>.sh copies.
#
# prep.sh's own header records why those copies are a defect: restating the scaffolding per
# ticket is how #482 ended up fired at a workspace that did not exist for 104 minutes, because
# ONE copy was missing the abort. A 10-agent fleet (#508) would have meant ten more copies.
# The ticket number is an ARGUMENT, not a new file.
#
# Usage: fire.sh <hermes|goose|claude> <slot> <repo-name>[,<repo-name>...] [model]
#
# #510: VERSIONED at cloud-u-containers/_dispatch/fire.sh; ~/git/_dispatch/fire.sh is a
# shim that execs it. Tester: test-dispatch-fail-opens.sh beside this file.
#
# [model] is claude-only and DEFAULTS TO sonnet, so every existing three-argument call site is
# unchanged. Same reasoning as the ticket number above: Diego names the engine per ticket
# ("deploy a fable agent", #512), and a second copy of this file with one word changed would be
# the exact defect this file exists to delete.
#
# MUST be invoked detached — `docker exec -d`. run.sh is called SYNCHRONOUSLY below, so an
# attached exec blocks for the agent's entire life; a wrapper with a `timeout` then kills the
# agent and any retry loop re-runs prep.sh, re-cloning ~660MB per attempt. That is not
# hypothetical: it is how the first #508 wave was lost.
set -u

ENGINE=$1
SLOT=$2
REPO=$3
MODEL=${4:-sonnet}

case "$ENGINE" in
  hermes) D=/opt/data/git/_dispatch ;;
  goose|claude) D=/home/appuser/git/_dispatch ;;
  *) echo "fire: unknown engine: $ENGINE" >&2; exit 64 ;;
esac
# The tester points this at a scratch tree; nothing in production sets it.
[ -n "${DISPATCH_ROOT:-}" ] && D=$DISPATCH_ROOT/_dispatch

L=$D/logs
M=$L/dispatch-$SLOT.marker
mkdir -p "$L"
: > "$M"
echo "FIRE start $(date -u +%FT%TZ) engine=$ENGINE slot=$SLOT repo=$REPO model=$MODEL" >> "$M"

# #738: register this agent for its whole life — live.sh beside this file is the one reader,
# and the ship engine asks it before recreating the container. Removed on every way out except
# SIGKILL; live.sh checks the pid is still this fire.sh, so a killed container's leftovers are
# not agents. Registered BEFORE the admission check, never after: live.sh writes the hold
# before it lists, so a fire racing a drain is either listed or refused, never neither.
REG=$L/live/$SLOT
mkdir -p "$L/live"
echo "slot=$SLOT engine=$ENGINE repo=$REPO model=$MODEL pid=$$ start=$(date -u +%FT%TZ)" > "$REG"
trap 'rm -f "$REG"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
UNTIL=$(cat "$L/live/.draining" 2>/dev/null)
case "$UNTIL" in
  ''|*[!0-9]*) ;;
  *) if [ "$(date +%s)" -lt "$UNTIL" ]; then
       echo "FIRE ABORT: draining — a ship is waiting to recreate this container (hold until $(date -u -d "@$UNTIL" +%FT%TZ 2>/dev/null || echo "$UNTIL")); re-fire after it" >> "$M"
       exit 75
     fi ;;
esac

PROMPT=$D/dispatch-$SLOT.md
if [ ! -f "$PROMPT" ]; then
  echo "FIRE ABORT: no ticket at $PROMPT" >> "$M"
  exit 66
fi

# #510: the brief is passed so prep can make it readable by the engine, or abort.
# #717/#658: <repo> may be a comma list — EVERY repo the brief touches gets its own worktree in
# this slot, so no part of the agent's work happens in a shared index. The first is where the
# agent starts. One prep failure aborts the whole fire: half an isolated slot is not one.
OIFS=$IFS; IFS=,
for R in $REPO; do
  IFS=$OIFS
  sh "$D/prep.sh" "$ENGINE" "$SLOT" "$R" "$M" "$PROMPT"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "FIRE ABORT: prep $R failed rc=$RC" >> "$M"
    exit "$RC"
  fi
done
IFS=$OIFS

# run.sh writes the "FIRE exit rc=" line into $M itself, by trap, so it lands even when this
# shell does not survive to write it (#717).
DISPATCH_REPOS=$REPO sh "$D/run.sh" "$ENGINE" "$SLOT" "$PROMPT" "$L/dispatch-$SLOT.outer" "$MODEL" \
  > "$L/dispatch-$SLOT.outer" 2>&1
RC=$?

# #742: the agent is gone (run.sh has written its exit line), so its worktrees go too — every
# one of them used to stay forever, and 24 such slots filled oci-apps' disk. reap.sh keeps any
# worktree with uncommitted or unpushed work and says why in this marker. A fire.sh that never
# gets here (SIGKILL) leaves its slot to prep.sh's low-disk sweep.
sh "$(dirname "$0")/reap.sh" "$ENGINE" "$SLOT" >> "$M" 2>&1
exit "$RC"
