#!/bin/sh
# Shared fire scaffolding — ONE declaration of everything a dispatch workspace needs.
#
# Every fire script used to restate this block: workspace-with-abort (a detached worktree since
# #487), declare the `github` remote,
# chown for the engine, then write the provenance lines. Restating it per ticket is how the
# fleet ends up with fire scripts that have quietly drifted apart — #482 was fired at a
# workspace that did not exist for 104 minutes because ONE copy was missing the abort.
#
# Usage: prep.sh <hermes|goose|claude> <slot> <repo-name> <marker-file> [brief-file]
#   Writes provenance to <marker-file>. Exits non-zero if the workspace cannot be prepared,
#   and the caller MUST treat that as fatal — never fire an agent at a workspace that failed.
#   [brief-file] (#510): make the brief readable by the engine, or abort. See below.
#
# #510: VERSIONED at cloud-u-containers/_dispatch/prep.sh; ~/git/_dispatch/prep.sh is a
# shim that execs it. Tester: test-dispatch-fail-opens.sh beside this file.
#
# NOT folded into run.sh deliberately (#485 proposed that): run.sh's stdout IS the agent log,
# and this scaffolding's output belongs in the marker, which is a different file. Merging them
# would put clone chatter inside the transcript the operator reads as the agent's answer.
set -u

ENGINE=$1
SLOT=$2
REPO=$3
M=$4
BRIEF=${5:-}

# #508: `claude` shares goose's ROOT on purpose — my-ai-api (goose) and my-ai_claude-api
# (claude) mount the SAME cloud-git-gh volume at the same path, and both exec as 10001:999.
case "$ENGINE" in
  hermes) ROOT=/opt/data/git ;;
  goose|claude) ROOT=/home/appuser/git ;;
  *) echo "prep: unknown engine: $ENGINE" >> "$M"; exit 64 ;;
esac
# The tester points this at a scratch tree; nothing in production sets it.
ROOT=${DISPATCH_ROOT:-$ROOT}

W=$ROOT/_work/$SLOT/$REPO
SRC=$ROOT/$REPO

# #482: `docker exec` is root, the shared trees are 10001:999, so EVERY git call below is a
# dubious-ownership candidate. Today that is survived only by `safe.directory = *` hand-written
# into /root/.gitconfig INSIDE the container — measured mtime 2026-09-18T00:03Z against container
# start 2026-09-17T08:20Z, and `cat /root/.gitconfig` in the image itself returns nothing. It is
# not baked; the next oci-apps deploy recreates hermes-agent and takes it with it.
# Declare it on the mounted volume instead, which survives a recreate.
#
# It MUST be a global config FILE. safe.directory is honored only from PROTECTED config scopes,
# so the two convenient forms are silently useless. Measured in this container, git 2.47.3, root
# cloning a 10001:999 tree with no /root/.gitconfig in view:
#   baseline, /root/.gitconfig visible  -> RC=0
#   git -c safe.directory='*'           -> RC=128 dubious ownership   (command scope NOT protected)
#   GIT_CONFIG_COUNT/KEY_0/VALUE_0      -> RC=128 dubious ownership   (env scope NOT protected)
#   GIT_CONFIG_GLOBAL=<file>            -> RC=0                       (global scope IS protected)
# Do not "simplify" this to -c or GIT_CONFIG_COUNT: both fail, and they fail at clone time, which
# prep.sh reports as an abort rather than a silent wrong result.
G=$ROOT/_dispatch/gitconfig
[ -f "$G" ] || printf '[safe]\n\tdirectory = *\n' > "$G"
GIT_CONFIG_GLOBAL=$G
export GIT_CONFIG_GLOBAL

mkdir -p "$(dirname "$W")" || { echo "prep: cannot create _work/$SLOT" >> "$M"; exit 65; }

if [ ! -d "$SRC/.git" ]; then
  echo "prep: ABORT — source tree $SRC is not a git repository" >> "$M"
  exit 66
fi

# #510 (b): the brief must be readable by the uid the engine runs as. 2026-09-24 the briefs
# were docker-cp'd in as uid 1001 mode 0600; every agent (uid 10001) hit "Permission denied"
# and exited rc=0. The engine uid is the owner of the shared tree it works in ($SRC), so the
# brief takes that owner and 0644. chown needs root: run prep as root (docker exec -u 0) when
# briefs arrive foreign-owned. Whatever the cause, an unreadable brief ABORTS here — run.sh
# also refuses one (rc=89), but failing at prep keeps the slot from being fired at all.
if [ -n "$BRIEF" ]; then
  if [ "$(id -u)" = 0 ]; then
    chown --reference="$SRC" "$BRIEF" >> "$M" 2>&1
  fi
  chmod 0644 "$BRIEF" >> "$M" 2>&1
  # Root reads anything, so as root "readable" is judged by the mode actually granted.
  if [ ! -r "$BRIEF" ] || [ "$(stat -c %a "$BRIEF" 2>/dev/null)" != 644 ]; then
    echo "prep: ABORT — brief unreadable by the engine: $(ls -ln "$BRIEF" 2>&1); prep uid=$(id -u)" >> "$M"
    exit 67
  fi
  echo "prep brief=$(stat -c '%u:%g %a' "$BRIEF")" >> "$M"
fi

# #487/#488/#558 → WORKTREES (Diego's decision, 2026-09-24). The slot is a `git worktree add
# --detach` of $SRC main, not a clone. A clone was one of three bad things: --shared wrote an
# ABSOLUTE alternates path (#487 measured all 20 under _work engine-bound, ZERO readable from both),
# --local hardlinked objects and died with EPERM on cloud-infra's root-owned objects (#558), and
# --no-hardlinks copied ~575MB per slot. A worktree has NO object store of its own: its .git is a
# one-line FILE pointing at $SRC/.git/worktrees/<id>, and every object lives in $SRC/.git/objects.
# Nothing to link, nothing to copy, no alternates.
#
# Its paths are still ABSOLUTE (git 2.47 has no relative worktree paths), so a worktree made here
# is only valid in THIS engine's mount (#484's lesson again). Consequence for prune: from goose, a
# hermes worktree's gitdir (/opt/data/git/...) looks MISSING, and a bare `git worktree prune`
# would delete its metadata out from under a running hermes agent. So every dispatch worktree is
# added LOCKED, and prune first unlocks only the ones under THIS engine's $ROOT whose directory is
# really gone. Another engine's worktrees are never ours to judge.
#
# #482: a failed add MUST abort.
prune_own() {
  for G in "$SRC"/.git/worktrees/*/gitdir; do
    [ -f "$G" ] || continue
    P=$(dirname "$(cat "$G")")
    case "$P" in
      "$ROOT"/_work/*) [ -e "$P" ] || git -C "$SRC" worktree unlock "$P" >> "$M" 2>&1 ;;
    esac
  done
  git -C "$SRC" worktree prune -v >> "$M" 2>&1
}

if [ ! -e "$W/.git" ]; then
  prune_own
  # Hooks OFF for the add: the source's own core.hooksPath applies to a worktree (a clone never
  # inherited it), and cloud-infra's post-checkout then ran a submodule SSH clone inside prep —
  # measured on the first real cloud-infra worktree. prep runs as root in production; it must
  # not execute repo-tracked hook code. Command scope is fine here: it is not safe.directory.
  git -C "$SRC" -c core.hooksPath=/dev/null worktree add --detach --lock --reason "dispatch slot $SLOT root=$ROOT" "$W" main >> "$M" 2>&1
  RC=$?
  echo "prep worktree rc=$RC" >> "$M"
  # After: the fresh worktree is locked, so it MUST survive a prune. If it does not, the lock is
  # not protecting it from the other engine either — refuse the slot.
  prune_own
  if [ "$RC" -ne 0 ] || ! git -C "$W" rev-parse --git-dir > /dev/null 2>&1; then
    echo "prep: ABORT — worktree add failed rc=$RC, refusing to fire an agent with no workspace" >> "$M"
    exit 2
  fi
fi
GITDIR=$(git -C "$W" rev-parse --absolute-git-dir)

# A worktree shares $SRC/.git/config. Everything below writes it only when it would change, so
# an idle prep never rewrites the shared config file (a root rewrite hands it to root:root).
# #485 papercut 2: declare `github` — the agents are told to push to it. Idempotent.
URL=https://github.com/diegonmarcos/$REPO.git
if [ "$(git -C "$SRC" remote get-url github 2>/dev/null)" != "$URL" ]; then
  git -C "$SRC" remote add github "$URL" 2>/dev/null || git -C "$SRC" remote set-url github "$URL"
fi

# #481: agents have pushed deliberate mutation commits to shared main. A mutation is a proof
# step, never a deliverable. Install a pre-push hook that refuses them.
# PREFIX, never substring: "MUTATION: drop the guard" is refused, but a legitimate subject like
# "fix the MUTATION guard so it cannot be bypassed" MUST still push.
# PER-WORKTREE: core.hooksPath in the SHARED config would repoint hooks for the main checkout and
# every other slot, and cloud-infra/cloud-u-android already set it there (0_git/dist/hooks). So
# the hooks live in this worktree's own metadata dir (pruned with it) and are wired through
# extensions.worktreeConfig, which only $GITDIR/config.worktree sees.
HOOKS=$GITDIR/dispatch-hooks
mkdir -p "$HOOKS"
cat > "$HOOKS/pre-push" <<'HOOK'
#!/bin/sh
# Refuse to push any commit whose SUBJECT LINE BEGINS with MUTATION.
# Prefix only — a subject that merely mentions the word is legitimate and must pass.
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [ "$local_sha" = "0000000000000000000000000000000000000000" ] && continue
  if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
    RANGE=$local_sha
  else
    RANGE="$remote_sha..$local_sha"
  fi
  BAD=$(git log --format='%h %s' "$RANGE" 2>/dev/null | awk '$2 ~ /^MUTATION/ {print}')
  if [ -n "$BAD" ]; then
    echo "pre-push REFUSED: mutation commits must never reach shared main (#481)." >&2
    echo "$BAD" >&2
    echo "A mutation is a proof step. Show it red locally, restore, then push the real fix." >&2
    exit 1
  fi
done
exit 0
HOOK
chmod 755 "$HOOKS/pre-push"
[ "$(git -C "$SRC" config --bool extensions.worktreeConfig)" = true ] \
  || git -C "$SRC" config extensions.worktreeConfig true
git -C "$W" config --worktree core.hooksPath "$HOOKS"

# #485 root cause: `docker exec` is uid=0(root), but every engine runs as 10001:999 (#488
# measured hermes and appuser NUMERICALLY identical). Everything root just created — the slot,
# the worktree metadata in the SHARED $SRC/.git, and the shared config if it was rewritten — goes
# to the owner of $SRC, or the agent gets a workspace it cannot write to (_work/476 and 477
# silently cloned a `-h` sibling and worked there).
if [ "$(id -u)" = 0 ]; then
  chown -R --reference="$SRC" "$ROOT/_work/$SLOT" "$SRC/.git/worktrees" "$SRC/.git/config" >> "$M" 2>&1
fi

echo "prep owner=$(stat -c %U "$W" 2>/dev/null || echo unknown)" >> "$M"
echo "prep at $(git -C "$W" rev-parse --short HEAD 2>/dev/null || echo unknown) gitdir=$GITDIR" >> "$M"
echo "prep dirty=$(git -C "$W" --no-optional-locks status --porcelain 2>/dev/null | wc -l)" >> "$M"
echo "prep hooksPath=$(git -C "$W" config core.hooksPath 2>/dev/null || echo NONE)" >> "$M"
exit 0
