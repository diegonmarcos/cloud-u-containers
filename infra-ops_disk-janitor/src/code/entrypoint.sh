#!/bin/bash
# disk-janitor (#811): declared, scheduled disk cleanup for oci-apps.
#
# 2026-10-03 oci-apps sat at 94-95% of its root filesystem; a hand-run
# `docker image prune -af --filter until=48h` freed 9.7 GB, and the dispatch
# _work slots had already caused ENOSPC once (#742). This makes that hygiene a
# declared policy instead of an operator's shell history.
#
# Each pass:
#   1. images      remove images NOT referenced by any container (running or
#                  stopped), older than IMAGE_MIN_AGE_HOURS, and not among the
#                  newest IMAGE_KEEP_PER_REPO of their repository. `docker rmi`
#                  without -f, so the daemon refuses anything still in use.
#   2. build cache `docker builder prune --filter until=<age>`.
#   3. volumes     ONLY dangling volumes whose name is a 64-hex anonymous id,
#                  carrying no com.docker.compose.* label, older than
#                  VOLUME_MIN_AGE_DAYS. Named volumes are never candidates.
#   4. _work slots for each DISPATCH_CONTAINERS "container:engine", run the
#                  dispatcher's own reap.sh --sweep inside that container. It
#                  keeps any slot with uncommitted or unpushed work and prints
#                  why; those KEPT lines are surfaced in this log and the alert.
#   5. logs        dispatch logs older than LOG_RETENTION_DAYS (markers of live
#                  slots are kept by age: a live slot touches its marker).
#   6. measure     free space of host /; ntfy alert below ALERT_FREE_GB;
#                  metrics JSON at /var/log/disk-janitor/metrics.json.
#
# MODE=dry-run (default) reports what each step WOULD do and deletes nothing.
# MODE=enforce deletes. Anything else is treated as dry-run (fail closed).
# Never: docker system prune, rmi -f, named volumes, data volumes.
set -uo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

SCHEDULE="${SCHEDULE:-17 */3 * * *}"
MODE="${MODE:-dry-run}"
IMAGE_MIN_AGE_HOURS="${IMAGE_MIN_AGE_HOURS:-48}"
IMAGE_KEEP_PER_REPO="${IMAGE_KEEP_PER_REPO:-2}"
BUILD_CACHE_MIN_AGE_HOURS="${BUILD_CACHE_MIN_AGE_HOURS:-48}"
VOLUME_MIN_AGE_DAYS="${VOLUME_MIN_AGE_DAYS:-7}"
DISPATCH_CONTAINERS="${DISPATCH_CONTAINERS:-}"
DISPATCH_ROOT="${DISPATCH_ROOT:-/home/appuser/git}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
ALERT_FREE_GB="${ALERT_FREE_GB:-12}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-health_resources}"
HOST_ROOT="${HOST_ROOT:-/host}"
STATE_DIR="${STATE_DIR:-/var/log/disk-janitor}"
# busybox crond starts each firing with an empty environment.
export SCHEDULE MODE IMAGE_MIN_AGE_HOURS IMAGE_KEEP_PER_REPO BUILD_CACHE_MIN_AGE_HOURS \
  VOLUME_MIN_AGE_DAYS DISPATCH_CONTAINERS DISPATCH_ROOT LOG_RETENTION_DAYS ALERT_FREE_GB \
  NTFY_URL NTFY_TOPIC HOST_ROOT STATE_DIR

for v in IMAGE_MIN_AGE_HOURS IMAGE_KEEP_PER_REPO BUILD_CACHE_MIN_AGE_HOURS VOLUME_MIN_AGE_DAYS LOG_RETENTION_DAYS ALERT_FREE_GB; do
  case "${!v}" in ''|*[!0-9]*) log "REFUSE: $v='${!v}' is not a non-negative integer"; exit 64 ;; esac
done
[ "$MODE" = enforce ] || MODE=dry-run
DRY=1; [ "$MODE" = enforce ] && DRY=0

free_kb() { df -Pk "$HOST_ROOT" 2>/dev/null | awk 'NR==2{print $4}'; }
pct_used() { df -Pk "$HOST_ROOT" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }

N_IMG=0; N_VOL=0; KEPT_SLOTS=""; N_LOGS=0

# ── 1. images ─────────────────────────────────────────────────────────────
prune_images() {
  local now cutoff in_use
  now=$(date +%s); cutoff=$((now - IMAGE_MIN_AGE_HOURS * 3600))
  # Every image ID any container (any state) references.
  in_use=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)
  declare -A seen=()
  # newest first, so the first K per repo are the keepers
  docker image ls --no-trunc --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}' 2>/dev/null \
  | while IFS=$'\t' read -r id repo tag; do
      created=$(docker image inspect --format '{{.Created}}' "$id" 2>/dev/null) && [ -n "$created" ] || continue
      echo -e "$(date -d "${created%%.*}" +%s 2>/dev/null || echo 0)\t$id\t$repo\t$tag"
    done | sort -rn | {
    while IFS=$'\t' read -r ts id repo tag; do
      ref="$repo:$tag"; [ "$repo" = "<none>" ] && ref="$id"
      n=${seen[$repo]:-0}; seen[$repo]=$((n + 1))
      if grep -qx "$id" <<<"$in_use"; then continue; fi
      if [ "$repo" != "<none>" ] && [ "$n" -lt "$IMAGE_KEEP_PER_REPO" ]; then continue; fi
      if [ "$ts" -eq 0 ] || [ "$ts" -gt "$cutoff" ]; then continue; fi
      if [ $DRY = 1 ]; then log "  [dry-run] would rmi $ref ($(date -d @"$ts" '+%F'))"; echo x >&3
      elif docker rmi "$ref" >/dev/null 2>&1; then log "  rmi $ref"; echo x >&3
      else log "  KEPT $ref — rmi refused (in use or shared)"; fi
    done
  } 3>"$STATE_DIR/.img"
  N_IMG=$(wc -l <"$STATE_DIR/.img")
}

# ── 3. anonymous dangling volumes ─────────────────────────────────────────
prune_volumes() {
  local cutoff=$(( $(date +%s) - VOLUME_MIN_AGE_DAYS * 86400 ))
  for v in $(docker volume ls -q --filter dangling=true 2>/dev/null); do
    [[ "$v" =~ ^[0-9a-f]{64}$ ]] || continue          # named → never
    labels=$(docker volume inspect --format '{{json .Labels}}' "$v" 2>/dev/null) || continue
    case "$labels" in *com.docker.compose*) continue ;; esac
    created=$(docker volume inspect --format '{{.CreatedAt}}' "$v" 2>/dev/null)
    ts=$(date -d "$(echo "$created" | sed 's/ [A-Z]*$//; s/T/ /; s/Z$//; s/[+-][0-9][0-9]:[0-9][0-9]$//')" +%s 2>/dev/null || echo 0)
    [ "$ts" -gt 0 ] && [ "$ts" -le "$cutoff" ] || continue
    # last check right before acting: still unreferenced?
    [ -z "$(docker ps -aq --filter volume="$v")" ] || continue
    if [ $DRY = 1 ]; then log "  [dry-run] would remove anonymous volume ${v:0:12}"; N_VOL=$((N_VOL + 1))
    elif docker volume rm "$v" >/dev/null 2>&1; then log "  removed anonymous volume ${v:0:12}"; N_VOL=$((N_VOL + 1)); fi
  done
}

# ── 4. dispatch _work slots ───────────────────────────────────────────────
# Read-only report for dry-run: same judgement reap.sh makes, no removal.
SLOT_REPORT='
R=$1; for c in "$R"/_work/*/*; do
  [ -f "$c/.git" ] || continue
  ST=$(git -C "$c" --no-optional-locks status --porcelain 2>/dev/null | wc -l)
  AH=$(git -C "$c" rev-list --count HEAD --not --remotes 2>/dev/null || echo "?")
  if [ "$ST" = 0 ] && [ "$AH" = 0 ]; then echo "clean $c"; else echo "reap: KEPT $c — $ST uncommitted, $AH unpushed"; fi
done'
sweep_slots() {
  for pair in $DISPATCH_CONTAINERS; do
    c=${pair%%:*}; e=${pair#*:}
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then log "  SKIP $c: not running"; continue; fi
    if [ $DRY = 1 ]; then
      out=$(docker exec "$c" sh -c "GIT_CONFIG_GLOBAL=$DISPATCH_ROOT/_dispatch/gitconfig; export GIT_CONFIG_GLOBAL; $SLOT_REPORT" _ "$DISPATCH_ROOT" 2>&1)
      while IFS= read -r l; do [ -n "$l" ] && log "  [dry-run] $c: $l"; done <<<"$out"
      log "  [dry-run] $c: enforce would run $DISPATCH_ROOT/_dispatch/reap.sh $e --sweep (removes only clean+pushed finished slots)"
    else
      out=$(docker exec "$c" sh "$DISPATCH_ROOT/_dispatch/reap.sh" "$e" --sweep 2>&1)
      while IFS= read -r l; do [ -n "$l" ] && log "  $c: $l"; done <<<"$out"
    fi
    k=$(grep -c 'KEPT' <<<"$out" || true)
    [ "${k:-0}" -gt 0 ] && KEPT_SLOTS="$KEPT_SLOTS $c:$k"
  done
}

# ── 5. dispatch logs ──────────────────────────────────────────────────────
prune_logs() {
  for pair in $DISPATCH_CONTAINERS; do
    c=${pair%%:*}
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    act="-print"; [ $DRY = 0 ] && act="-print -delete"
    n=$(docker exec "$c" sh -c "find '$DISPATCH_ROOT/_dispatch/logs' -type f -mtime +$LOG_RETENTION_DAYS $act 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    log "  $c: ${n} dispatch log(s) older than ${LOG_RETENTION_DAYS}d $([ $DRY = 1 ] && echo 'would be removed' || echo removed)"
    N_LOGS=$((N_LOGS + n))
  done
}

notify() {
  [ -n "$NTFY_URL" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: floppy_disk" \
    -d "$2" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || log "WARN: ntfy publish failed"
}

run_pass() {
  mkdir -p "$STATE_DIR"
  local before after
  before=$(free_kb)
  log "disk-janitor pass MODE=$MODE — host / free $((before / 1048576)) GB ($(pct_used)% used)"
  log "images: unused, >${IMAGE_MIN_AGE_HOURS}h, beyond newest ${IMAGE_KEEP_PER_REPO}/repo"; prune_images
  log "build cache: >${BUILD_CACHE_MIN_AGE_HOURS}h"
  if [ $DRY = 1 ]; then log "  [dry-run] would run: docker builder prune -f --filter until=${BUILD_CACHE_MIN_AGE_HOURS}h"
  else docker builder prune -f --filter "until=${BUILD_CACHE_MIN_AGE_HOURS}h" 2>&1 | tail -1 | while IFS= read -r l; do log "  $l"; done; fi
  log "volumes: anonymous+dangling+unlabelled, >${VOLUME_MIN_AGE_DAYS}d"; prune_volumes
  log "dispatch _work slots"; sweep_slots
  log "dispatch logs >${LOG_RETENTION_DAYS}d"; prune_logs
  after=$(free_kb)
  local free_gb=$((after / 1048576)) used; used=$(pct_used)
  log "done — images=$N_IMG volumes=$N_VOL logs=$N_LOGS kept_slots='${KEPT_SLOTS# }' free ${free_gb} GB (${used}% used), reclaimed $(((after - before) / 1024)) MB"
  cat >"$STATE_DIR/metrics.json.tmp" <<EOF
{"ts":"$(date -u +%FT%TZ)","mode":"$MODE","free_gb":$free_gb,"used_pct":${used:-null},"reclaimed_mb":$(((after - before) / 1024)),"images":$N_IMG,"volumes":$N_VOL,"logs":$N_LOGS,"kept_slots":"${KEPT_SLOTS# }","alert_free_gb":$ALERT_FREE_GB}
EOF
  mv "$STATE_DIR/metrics.json.tmp" "$STATE_DIR/metrics.json"
  if [ -n "$after" ] && [ "$free_gb" -lt "$ALERT_FREE_GB" ]; then
    notify "oci-apps disk low: ${free_gb} GB free" \
      "oci-apps / is ${used}% used, ${free_gb} GB free (< ${ALERT_FREE_GB} GB) after disk-janitor MODE=$MODE. Candidates: images=$N_IMG volumes=$N_VOL logs=$N_LOGS. Slots kept for unpushed/uncommitted work: ${KEPT_SLOTS:-none}." high
  fi
}

log "disk-janitor starting — schedule='$SCHEDULE' mode=$MODE"
if [ "${RUN_ONCE:-false}" = "true" ] || ! command -v crond >/dev/null 2>&1; then
  run_pass; exit 0
fi
echo "$SCHEDULE $(readlink -f "$0") >> $STATE_DIR/janitor.log 2>&1" > /etc/crontabs/root
export RUN_ONCE=true
run_pass
log "handing off to cron ($SCHEDULE)"
exec crond -f -l 2
