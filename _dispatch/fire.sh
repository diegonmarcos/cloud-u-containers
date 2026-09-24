#!/bin/sh
# ONE fire script for every dispatch. Replaces the per-ticket fire-NNN-<engine>.sh copies.
#
# prep.sh's own header records why those copies are a defect: restating the scaffolding per
# ticket is how #482 ended up fired at a workspace that did not exist for 104 minutes, because
# ONE copy was missing the abort. A 10-agent fleet (#508) would have meant ten more copies.
# The ticket number is an ARGUMENT, not a new file.
#
# Usage: fire.sh <hermes|goose|claude> <slot> <repo-name> [model]
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

PROMPT=$D/dispatch-$SLOT.md
if [ ! -f "$PROMPT" ]; then
  echo "FIRE ABORT: no ticket at $PROMPT" >> "$M"
  exit 66
fi

# #510: the brief is passed so prep can make it readable by the engine, or abort.
sh "$D/prep.sh" "$ENGINE" "$SLOT" "$REPO" "$M" "$PROMPT"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "FIRE ABORT: prep failed rc=$RC" >> "$M"
  exit "$RC"
fi

sh "$D/run.sh" "$ENGINE" "$SLOT" "$PROMPT" "$L/dispatch-$SLOT.outer" "$MODEL" \
  > "$L/dispatch-$SLOT.outer" 2>&1
echo "FIRE exit rc=$? $(date -u +%FT%TZ)" >> "$M"
