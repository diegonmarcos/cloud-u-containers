#!/bin/sh
# #742: give a finished slot's disk back — the one place a dispatch worktree is ever removed.
#
# prep.sh adds a full worktree per repo per slot (cloud-u-android alone is ~36k files, ~600MB)
# and, until this file, nothing removed one. On 2026-10-01 oci-apps reached 185MB free with 24
# slots accumulated under _work/, and the next two fires died with "No space left on device".
#
# Usage: reap.sh <hermes|goose|claude> <slot>             reap that slot; the caller vouches it
#                                                         is finished (fire.sh, after run.sh)
#        reap.sh <hermes|goose|claude> --sweep [<skip>]   reap every FINISHED slot but <skip>
#                                                         (prep.sh, when the disk is short)
# Output is the log; the callers append it to the slot's marker.
#
# NEVER destroys work. A worktree is removed only when `git status` is empty AND every commit on
# its HEAD is on some remote; otherwise it is KEPT and the reason is printed. Untracked files
# count as work. Anything that is not one of this engine's worktrees is not judged at all.
#
# A slot is FINISHED, for --sweep, when its marker names this engine (or predates the engine
# field) and live.sh lists no agent for it. live.sh sees only THIS container's processes, which
# is why the engine must match: goose shares claude's tree from another container, and hermes
# worktrees point into a mount this one does not have.
set -u

ENGINE=$1
case "$ENGINE" in
  hermes) ROOT=/opt/data/git ;;
  goose|claude) ROOT=/home/appuser/git ;;
  *) echo "reap: unknown engine: $ENGINE"; exit 64 ;;
esac
# The tester points this at a scratch tree; nothing in production sets it.
ROOT=${DISPATCH_ROOT:-$ROOT}
HERE=$(dirname "$0")
# Same reason as prep.sh: root running git on a 10001-owned tree needs safe.directory from a
# protected (global) scope.
[ -f "$ROOT/_dispatch/gitconfig" ] && { GIT_CONFIG_GLOBAL=$ROOT/_dispatch/gitconfig; export GIT_CONFIG_GLOBAL; }

reap_slot() {
  SD=$ROOT/_work/$1
  [ -d "$SD" ] || return 0
  for c in "$SD"/*; do
    [ -e "$c" ] || continue
    if [ -f "$c/.git" ]; then
      GD=$(sed -n 's/^gitdir: //p' "$c/.git")
      case "$GD" in
        "$ROOT"/*/.git/worktrees/*) ;;
        *) echo "reap: KEPT $c — its git dir '$GD' is not under $ROOT, so it is not this engine's to judge"; continue ;;
      esac
      if ! ST=$(git -C "$c" --no-optional-locks status --porcelain 2>&1); then
        echo "reap: KEPT $c — git status failed: $(echo "$ST" | head -1)"; continue
      fi
      if [ -n "$ST" ]; then
        echo "reap: KEPT $c — $(echo "$ST" | wc -l | tr -d ' ') uncommitted path(s), e.g. $(echo "$ST" | head -3 | tr '\n' ' ')"; continue
      fi
      AHEAD=$(git -C "$c" rev-list --count HEAD --not --remotes 2>&1)
      if [ "$AHEAD" != 0 ]; then
        echo "reap: KEPT $c — $AHEAD commit(s) on HEAD $(git -C "$c" rev-parse --short HEAD 2>/dev/null) that no remote has"; continue
      fi
      SRC=${GD%/.git/worktrees/*}
      # Twice -f: dispatch worktrees are added --lock (prep.sh), and only a double force removes
      # a locked one. The status check above is what keeps this from discarding anything.
      if OUT=$(git -C "$SRC" worktree remove -f -f "$c" 2>&1); then
        git -C "$SRC" worktree prune
        echo "reap: removed worktree $c"
      else
        echo "reap: KEPT $c — worktree remove failed: $(echo "$OUT" | head -1)"
      fi
    elif [ -d "$c" ] && [ -z "$(ls -A "$c")" ]; then
      OUT=$(rmdir "$c" 2>&1) && echo "reap: removed empty $c" \
        || echo "reap: CANNOT remove empty $c (slot owned by $(stat -c %U "$SD")): $OUT"
    else
      echo "reap: KEPT $c — not a dispatch worktree"
    fi
  done
  if [ -z "$(ls -A "$SD")" ]; then
    OUT=$(rmdir "$SD" 2>&1) && echo "reap: removed slot $SD" \
      || echo "reap: CANNOT remove empty slot $SD (owned by $(stat -c %U "$SD")): $OUT"
  fi
}

if [ "${2:-}" != --sweep ]; then
  reap_slot "${2:?reap: which slot?}"
  exit 0
fi

SKIP=${3:-}
# Fail closed: if liveness cannot be read, nothing is provably finished.
if ! LIVE=$(DISPATCH_ROOT=$ROOT sh "$HERE/live.sh" list); then
  echo "reap: live.sh failed — no slot can be proven finished, nothing reaped"
  exit 0
fi
for SD in "$ROOT"/_work/*; do
  [ -d "$SD" ] || continue
  S=${SD##*/}
  [ "$S" = "$SKIP" ] && continue
  case "$LIVE" in *"slot=$S "*) echo "reap: skip $S — agent alive"; continue ;; esac
  MK=$ROOT/_dispatch/logs/dispatch-$S.marker
  if [ ! -f "$MK" ]; then
    echo "reap: skip $S — no marker, so no way to tell which engine owns it"; continue
  fi
  E=$(sed -n 's/^FIRE start .* engine=\([^ ]*\).*/\1/p' "$MK" | head -1)
  if [ -n "$E" ] && [ "$E" != "$ENGINE" ]; then
    echo "reap: skip $S — fired by $E, whose agents this container cannot see"; continue
  fi
  reap_slot "$S"
done
