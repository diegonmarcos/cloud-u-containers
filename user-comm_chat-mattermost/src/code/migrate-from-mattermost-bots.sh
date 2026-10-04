#!/bin/sh
# ╔══════════════════════════════════════════════════════════════════╗
# ║ One-time migration: mattermost-bots → chat-mattermost            ║
# ║                                                                  ║
# ║ Runs as compose.pre_hook on EVERY deploy, but only does work on  ║
# ║ the first deploy after the service rename. After success a       ║
# ║ marker file in /opt/containers/chat-mattermost/.migrated         ║
# ║ short-circuits future runs to a no-op.                           ║
# ║                                                                  ║
# ║ Migrates 6 named volumes from the old compose project's prefix   ║
# ║ (mattermost-bots_*) to the new (chat-mattermost_*) by copying    ║
# ║ via temporary alpine container — docker has no native volume     ║
# ║ rename. After migration the old volumes are kept (orphaned) so a ║
# ║ revert is possible; they can be `docker volume rm`d manually     ║
# ║ once chat-mattermost is verified healthy.                        ║
# ║                                                                  ║
# ║ Also stops + removes the old project's containers (which hold    ║
# ║ the same explicit container_name's as the new project would).    ║
# ║                                                                  ║
# ║ Idempotent. Safe to run multiple times — marker file gates work. ║
# ╚══════════════════════════════════════════════════════════════════╝
set -eu

MARKER="$(dirname "$0")/../.migrated-from-mattermost-bots"
OLD_PROJECT="mattermost-bots"
NEW_PROJECT="chat-mattermost"

# Volumes to migrate. Names match what docker-compose generates from the
# compose service block (project prefix + volume key).
# Plugin volumes (mattermost_plugins, mattermost_client_plugins) intentionally
# excluded: chat-mattermost no longer mounts them — plugins live in the image.
# Any old mattermost-bots_mattermost_plugins volume remains orphaned (safe to
# manually `docker volume rm` after verifying chat-mattermost is healthy).
VOLUMES="mattermost_config mattermost_data mattermost_logs mattermost_postgres"

# Old project's explicit container_name's — must be stopped+removed so the
# new project can take the same names. (Compose enforces container_name
# uniqueness across the daemon, not per-project.)
OLD_CONTAINERS="mattermost mattermost-postgres mattermost-bots cloud-mattermost-mcp"

log() { printf '[migrate] %s\n' "$1"; }

# ── 0. Marker short-circuit ───────────────────────────────────────────
if [ -f "$MARKER" ]; then
    log "marker $MARKER present — already migrated, no-op"
    exit 0
fi

# ── 1. Sanity check: old project's volumes must exist ────────────────
# If they don't, this is either a fresh install (nothing to migrate) or
# the migration already ran on a different node. Either way: write the
# marker and exit success — don't block compose-up forever.
_have_old=0
for _v in $VOLUMES; do
    if docker volume inspect "${OLD_PROJECT}_${_v}" >/dev/null 2>&1; then
        _have_old=1
        break
    fi
done
if [ "$_have_old" -eq 0 ]; then
    log "no ${OLD_PROJECT}_* volumes exist — nothing to migrate (fresh install or already cleaned up)"
    mkdir -p "$(dirname "$MARKER")"
    : > "$MARKER"
    exit 0
fi

log "old volumes detected — starting migration"

# ── 2. Stop + remove old containers (release volumes, free names) ────
# `docker rm -f` is idempotent: silent success if the container doesn't
# exist. We don't `compose down` because the old project's compose file
# is on a different on-disk path that the new deploy may already have
# overwritten.
for _c in $OLD_CONTAINERS; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$_c"; then
        log "stopping + removing container $_c"
        docker rm -f "$_c" >/dev/null
    fi
done

# ── 3. Per-volume copy: old → new ────────────────────────────────────
# Docker has no `volume rename`. Standard pattern: spin up a one-shot
# alpine container with BOTH volumes mounted, cp -a from old → new.
# `cp -a` preserves perms, owners, symlinks, timestamps.
# If the new volume doesn't exist yet, `-v` creates it.
# `--rm` cleans up the temp container.
for _v in $VOLUMES; do
    _old="${OLD_PROJECT}_${_v}"
    _new="${NEW_PROJECT}_${_v}"

    if ! docker volume inspect "$_old" >/dev/null 2>&1; then
        log "skip $_v — old volume $_old missing (already migrated?)"
        continue
    fi

    # If new volume already has data, don't clobber — leave it alone.
    # Empty check: alpine du -s of /to and skip if > 4KB (just dir overhead).
    _new_bytes=$(docker run --rm -v "${_new}:/to" alpine:3 sh -c 'du -bs /to 2>/dev/null | cut -f1' 2>/dev/null || echo 0)
    if [ "${_new_bytes:-0}" -gt 4096 ]; then
        log "skip $_v — $_new already non-empty ($_new_bytes bytes), leaving as-is"
        continue
    fi

    log "copying $_old → $_new"
    docker run --rm \
        -v "${_old}:/from:ro" \
        -v "${_new}:/to" \
        alpine:3 \
        sh -c 'cp -a /from/. /to/'
    log "  ✓ $_v migrated"
done

# ── 4. Write marker — migration succeeded ────────────────────────────
mkdir -p "$(dirname "$MARKER")"
{
    printf 'migrated_at=%s\n' "$(date -Iseconds)"
    printf 'from_project=%s\n' "$OLD_PROJECT"
    printf 'to_project=%s\n'   "$NEW_PROJECT"
    printf 'volumes=%s\n'      "$VOLUMES"
} > "$MARKER"

log "migration complete — marker written to $MARKER"
log "old ${OLD_PROJECT}_* volumes are kept as a backup (NOT auto-deleted)."
log "after verifying chat-mattermost is healthy, manually clean up via:"
log "  docker volume ls --filter name=^${OLD_PROJECT}_  # inspect first"
log "  # then remove the ones you confirmed are orphaned, one at a time"
