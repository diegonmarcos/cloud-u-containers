#!/bin/bash
# agents-tmp-reaper: periodically clear stale agent scratch from the /tmp of
# the agent containers, so a runaway agent cache cannot fill the host root
# filesystem.
#
# Why it exists (task 442 / issue 410): the agent containers leak into /tmp at
# roughly 2.36 GB/hour and had filled the oci-apps root filesystem. Each agent
# container's /tmp lives in its own writable layer, which Docker places on the
# host root filesystem (<root fs>/var/lib/docker/overlay2), so an unscrubbed
# /tmp grows the host disk even though the bytes never reached a host path.
#
# Why it is shaped like this (and not like the old hand-made one):
#
#   - SCOPED, per issue 393. An unscoped `docker system prune -af` on this same
#     box destroyed the matomo container and image nine hours after they were
#     restored, and the earlier nix watchdog nearly did the same to vaultwarden.
#     This reaper therefore never touches docker objects — no container, image,
#     volume, or build-cache prune. It only removes REGULAR FILES, and only:
#       1. under the declared scrub root (the agent scratch path, /tmp), and
#       2. older than STALE_MINUTES, and
#       3. inside a container explicitly listed in AGENT_CONTAINERS.
#     Everything else — younger files, non-agent containers, volumes, mount
#     points, the scrub root itself, and every docker-managed object — is left
#     alone by construction.
#
#   - Age-gated, not "everything in /tmp". The roster of agent scratch filenames
#     drifts (tsx-, uv-, compile-cache, goose-, hermes- …) and a name allow-list
#     is exactly the brittle list that rots. Age is the durable signal: anything
#     under an agent's own /tmp that has not been touched for STALE_MINUTES is
#     scrap by definition — agents keep their working output in their persistent
#     volumes (/opt/data, *_data), never in /tmp. A file touched within the age
#     window is left alone even if it sits in a scratch-looking path.
#
#   - It stays on one device (-xdev) and never follows symlinks out of /tmp, so
#     a mounted volume or linked path under the scrub root cannot be traversed
#     into. Mount points are not descended and not removed.
#
#   - Fail-closed roster. AGENT_CONTAINERS is required and validated; an empty
#     or malformed roster does nothing rather than guessing at "all containers".
#
# No restart policy, no autorestart: a scheduled one-shot is the whole contract.
# The container keeps running so crond owns the schedule; each firing runs this
# script exactly once via RUN_ONCE=true (the db-agent pattern).
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Configuration (mirrors db-agent's env-driven cron pattern) ──────────
SCHEDULE="${SCHEDULE:-0 */2 * * *}"      # cron schedule (default: every 2h)
STALE_MINUTES="${STALE_MINUTES:-180}"    # untouched-for-this-long ⇒ scratch
SCRUB_ROOT="${SCRUB_ROOT:-/tmp}"         # the agent scratch path
AGENT_CONTAINERS="${AGENT_CONTAINERS:-}" # REQUIRED: space-separated allow-list

# busybox crond spawns each firing in a fresh, near-empty environment, so the
# compose-injected values above would be lost and AGENT_CONTAINERS would come
# back empty every run. Export them so the crond-launched pass sees the same
# roster and thresholds as the initial pass.
export SCHEDULE STALE_MINUTES SCRUB_ROOT AGENT_CONTAINERS

# ── Core scrub ──────────────────────────────────────────────────────────
# Scrub a directory tree of stale scratch. Facts we want asserted no matter
# where this runs (inside a container via `docker exec`, or standalone against
# a test root):
#   delete  stale regular files under the root
#   delete  stale empty subdirectories (bottom-up)
#   keep    everything younger than STALE_MINUTES
#   keep    the scrub root itself
#   keep    mount points (never descended, never removed)
#   keep    symlinks (never followed, never removed)
scrub_tree() {
  local root="$1"
  local age="$2"

  # Never operate on an empty or relative root; /tmp must end up /tmp, never "".
  if [ -z "$root" ] || [ "$root" = "/" ] || [ "${root:0:1}" != "/" ]; then
    log "REFUSE: scrub root '$root' is not an absolute, non-root path"
    return 1
  fi
  if [ ! -d "$root" ]; then
    log "SKIP: scrub root '$root' is not a directory"
    return 0
  fi

  log "scrub $root: files+empty-dirs older than ${age}m"

  # Stale regular files. -xdev: never leave the root's filesystem (mounts at or
  # below the root are not crossed). -type f: never touch dirs/symlinks/sockets
  # here; directories are handled separately so an aged-but-still-mountpoint
  # directory is never descended or removed.
  find "$root" -mindepth 1 -xdev -type f -mmin +"$age" -print -delete \
    | while IFS= read -r f; do log "  deleted $f"; done

  # Stale empty directories, deepest first. Only REMOVE a directory if it is
  # (a) older than the age and (b) empty. A bind-mounted volume root that
  # happens to be empty is ALSO a mount point, so reject those explicitly.
  find "$root" -mindepth 1 -xdev -type d -mmin +"$age" -empty -print \
    | while IFS= read -r d; do
        if mountpoint -q "$d" 2>/dev/null; then
          log "  keep $d (mount point)"
          continue
        fi
        if rmdir "$d" 2>/dev/null; then
          log "  deleted empty dir $d"
        fi
      done

  return 0
}

# ── One reaping pass across the declared agent containers ───────────────
reap() {
  # Validate the fail-closed roster first.
  if [ -z "$AGENT_CONTAINERS" ]; then
    log "ERROR: AGENT_CONTAINERS is empty — refusing to guess at the fleet. Nothing scrubbed."
    return 1
  fi

  for name in $AGENT_CONTAINERS; do
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      log "SKIP ${name}: not a running container"
      continue
    fi

    log "reap ${name}${SCRUB_ROOT}"
    # Scrub inside the container's own /tmp (its writable layer — the bytes
    # that grow the host root filesystem). `sh -c` keeps the find/rmdir run on
    # the far side; STALE_MINUTES is interpolated here but is operator-set and
    # numeric, so quoting it stays safe.
    if docker exec "$name" sh -c '
        set -u
        STALE='"$STALE_MINUTES"'
        # inline copy of scrub_tree (busybox sh on the far side has no
        # reliable `mountpoint`; we rely on -xdev not to cross and on not
        # removing non-empty dirs)
        find '"${SCRUB_ROOT}"' -mindepth 1 -xdev -type f -mmin +"$STALE" -print -delete
        find '"${SCRUB_ROOT}"' -mindepth 1 -xdev -type d -mmin +"$STALE" -empty -exec rmdir {} + 2>/dev/null
      ' 2>/dev/null; then
      log "reap ${name}: pass complete"
    else
      log "WARN reap ${name}: docker exec failed (container up?)"
    fi
  done
}

log "agents-tmp-reaper starting — schedule='$SCHEDULE' stale=${STALE_MINUTES}m scrub_root='$SCRUB_ROOT'"
log "agent containers: ${AGENT_CONTAINERS:-<NONE — disarmed>}"

# ── Main: run once, or hand off to cron (db-agent pattern) ──────────────
if [ "${RUN_ONCE:-false}" = "true" ]; then
  reap
  exit $?
fi

# If run standalone (outside a container clock) also run once.
if ! command -v crond >/dev/null 2>&1; then
  log "crond not present — running one pass and exiting"
  reap
  exit $?
fi

echo "$SCHEDULE /usr/local/bin/entrypoint.sh" > /etc/crontabs/root
export RUN_ONCE=true

reap
log "handing off to cron ($SCHEDULE)"
exec crond -f -l 2