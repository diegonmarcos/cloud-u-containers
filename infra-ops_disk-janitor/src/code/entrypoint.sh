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
#                  newest IMAGE_KEEP_PREVIOUS of their repository. `docker rmi`
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
# Added 2026-10-14 (disk must never fill again), same container, same pass:
#   7. runners     idle GitHub runner containers: stale self-update folders
#                  (bin.<ver>, externals.<ver>, _update), old _diag logs and _work
#                  dirs older than RUNNER_WORK_MIN_AGE_DAYS. A runner with a
#                  Runner.Worker process is never touched.
#   8. gradle      my-ai-api-home Gradle cache: derived caches (transforms, jars,
#                  build-cache) and downloaded artifacts not read or written for
#                  GRADLE_MAX_AGE_DAYS are removed; they re-download / rebuild.
#   9. lance       octocode_db / octocode_db_pvt: superseded manifests and the data
#                  fragments only they named (same functions as the cgc-db restore),
#                  so the live volumes stay trimmed between restores.
#
# Added 2026-10-17 (oci-apps back at 94%; a manual pass freed ~17 GB):
#  10. caches      a) host ~/.cache/cgc-db-staging.* older than STAGING_MAX_AGE_HOURS
#                     (a cgc-db restore killed by a signal left 1-4 GB each).
#                  b) npm _cacache in NPM_CACHE_HOMES once it exceeds NPM_CACHE_MAX_MB
#                     and no npm process runs in NPM_CACHE_CONTAINER (npm re-downloads).
#                  c) git clones under GIT_GC_ROOTS: plain `git gc` (default 2-week
#                     prune, so objects a live agent just wrote are safe) when loose
#                     objects exceed GIT_GC_LOOSE_MB or packs exceed GIT_GC_MAX_PACKS.
#                  Gradle step 8 now also judges caches/<gradle-version>/* entries.
# images now keep: every image a container references + the newest
# IMAGE_KEEP_PREVIOUS unused tagged image per repo (the rollback). Dangling images
# go after DANGLING_MIN_AGE_HOURS.
#
# AGGRESSIVE (flag --aggressive or AGGRESSIVE=1, used by the disk watchdog above
# 85% root usage): no age gates on unused/dangling images, `builder prune -af`,
# gradle/runner age windows shortened. The keep rules (in use + 1 previous) and
# the never-list below stay exactly the same.
#
# MODE=dry-run (default) reports what each step WOULD do and deletes nothing.
# MODE=enforce deletes. Anything else is treated as dry-run (fail closed).
# Never: docker system prune, rmi -f, named volumes, data volumes.
set -uo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

SCHEDULE="${SCHEDULE:-17 */3 * * *}"
MODE="${MODE:-dry-run}"
IMAGE_MIN_AGE_HOURS="${IMAGE_MIN_AGE_HOURS:-24}"
IMAGE_KEEP_PREVIOUS="${IMAGE_KEEP_PREVIOUS:-1}"
DANGLING_MIN_AGE_HOURS="${DANGLING_MIN_AGE_HOURS:-1}"
RUNNER_WORK_MIN_AGE_DAYS="${RUNNER_WORK_MIN_AGE_DAYS:-3}"
RUNNER_IMAGE_MATCH="${RUNNER_IMAGE_MATCH:-github-runner}"
GRADLE_HOME_PATH="${GRADLE_HOME_PATH:-/vol/my-ai-api-home/toolchain/gradle-home}"
GRADLE_MAX_AGE_DAYS="${GRADLE_MAX_AGE_DAYS:-30}"
LANCE_HOMES="${LANCE_HOMES:-/vol/octocode_db /vol/octocode_db_pvt}"
STAGING_PARENT="${STAGING_PARENT:-/vol/host-cache}"
STAGING_MAX_AGE_HOURS="${STAGING_MAX_AGE_HOURS:-24}"
NPM_CACHE_HOMES="${NPM_CACHE_HOMES:-/vol/claude-superset-api-home}"
NPM_CACHE_MAX_MB="${NPM_CACHE_MAX_MB:-1024}"
NPM_CACHE_CONTAINER="${NPM_CACHE_CONTAINER:-cloud-agi-claude}"
GIT_GC_ROOTS="${GIT_GC_ROOTS:-/vol/shared-git-tree /vol/octocode_repos}"
GIT_GC_LOOSE_MB="${GIT_GC_LOOSE_MB:-200}"
GIT_GC_MAX_PACKS="${GIT_GC_MAX_PACKS:-20}"
AGGRESSIVE="${AGGRESSIVE:-0}"
for a in "$@"; do [ "$a" = "--aggressive" ] && AGGRESSIVE=1; done
BUILD_CACHE_MIN_AGE_HOURS="${BUILD_CACHE_MIN_AGE_HOURS:-48}"
VOLUME_MIN_AGE_DAYS="${VOLUME_MIN_AGE_DAYS:-7}"
DISPATCH_CONTAINERS="${DISPATCH_CONTAINERS:-}"
DISPATCH_ROOT="${DISPATCH_ROOT:-/home/appuser/git}"
# reap.sh is versioned in the cloud-u-containers checkout, not in the runtime _dispatch dir.
REAP_SCRIPT="${REAP_SCRIPT:-$DISPATCH_ROOT/cloud-u-containers/_dispatch/reap.sh}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
ALERT_FREE_GB="${ALERT_FREE_GB:-12}"
NTFY_URL="${NTFY_URL:-}"
NTFY_TOPIC="${NTFY_TOPIC:-health_resources}"
HOST_ROOT="${HOST_ROOT:-/host}"
STATE_DIR="${STATE_DIR:-/var/log/disk-janitor}"
# busybox crond starts each firing with an empty environment.
export SCHEDULE MODE IMAGE_MIN_AGE_HOURS IMAGE_KEEP_PREVIOUS DANGLING_MIN_AGE_HOURS BUILD_CACHE_MIN_AGE_HOURS \
  RUNNER_WORK_MIN_AGE_DAYS RUNNER_IMAGE_MATCH GRADLE_HOME_PATH GRADLE_MAX_AGE_DAYS LANCE_HOMES \
  STAGING_PARENT STAGING_MAX_AGE_HOURS NPM_CACHE_HOMES NPM_CACHE_MAX_MB NPM_CACHE_CONTAINER \
  GIT_GC_ROOTS GIT_GC_LOOSE_MB GIT_GC_MAX_PACKS \
  VOLUME_MIN_AGE_DAYS DISPATCH_CONTAINERS DISPATCH_ROOT REAP_SCRIPT LOG_RETENTION_DAYS ALERT_FREE_GB \
  NTFY_URL NTFY_TOPIC HOST_ROOT STATE_DIR

for v in IMAGE_MIN_AGE_HOURS IMAGE_KEEP_PREVIOUS DANGLING_MIN_AGE_HOURS BUILD_CACHE_MIN_AGE_HOURS VOLUME_MIN_AGE_DAYS LOG_RETENTION_DAYS ALERT_FREE_GB RUNNER_WORK_MIN_AGE_DAYS GRADLE_MAX_AGE_DAYS \
  STAGING_MAX_AGE_HOURS NPM_CACHE_MAX_MB GIT_GC_LOOSE_MB GIT_GC_MAX_PACKS; do
  case "${!v}" in ''|*[!0-9]*) log "REFUSE: $v='${!v}' is not a non-negative integer"; exit 64 ;; esac
done
[ "$MODE" = enforce ] || MODE=dry-run
[ "$AGGRESSIVE" = 1 ] || AGGRESSIVE=0
export AGGRESSIVE
if [ "$AGGRESSIVE" = 1 ]; then
  IMAGE_MIN_AGE_HOURS=0; DANGLING_MIN_AGE_HOURS=0; BUILD_CACHE_MIN_AGE_HOURS=0
  RUNNER_WORK_MIN_AGE_DAYS=0; GRADLE_MAX_AGE_DAYS=$((GRADLE_MAX_AGE_DAYS / 2))
fi
DRY=1; [ "$MODE" = enforce ] && DRY=0

free_kb() { df -Pk "$HOST_ROOT" 2>/dev/null | awk 'NR==2{print $4}'; }
pct_used() { df -Pk "$HOST_ROOT" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}'; }

N_IMG=0; N_VOL=0; KEPT_SLOTS=""; N_LOGS=0; N_RUNNER=0; N_GRADLE=0; N_CACHE=0

# ── 1. images ─────────────────────────────────────────────────────────────
# Keep: every image a container (any state) references, plus the newest
# IMAGE_KEEP_PREVIOUS unused tagged image per repository (the rollback).
# Remove: dangling images older than DANGLING_MIN_AGE_HOURS, and every other
# unused tagged image older than IMAGE_MIN_AGE_HOURS. `docker rmi` without -f,
# so the daemon still refuses anything in use or with a dependent child.
prune_images() {
  local now cutoff dcutoff in_use
  now=$(date +%s); cutoff=$((now - IMAGE_MIN_AGE_HOURS * 3600)); dcutoff=$((now - DANGLING_MIN_AGE_HOURS * 3600))
  # Every image ID any container (any state) references.
  in_use=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null | sort -u)
  declare -A prev=()
  # newest first, so the first unused tagged image per repo is its "previous"
  docker image ls --no-trunc --format '{{.ID}}\t{{.Repository}}\t{{.Tag}}' 2>/dev/null \
  | while IFS=$'\t' read -r id repo tag; do
      created=$(docker image inspect --format '{{.Created}}' "$id" 2>/dev/null) && [ -n "$created" ] || continue
      echo -e "$(date -d "${created%%.*}" +%s 2>/dev/null || echo 0)\t$id\t$repo\t$tag"
    done | sort -rn | {
    while IFS=$'\t' read -r ts id repo tag; do
      ref="$repo:$tag"; [ "$repo" = "<none>" ] && ref="$id"
      if grep -qx "$id" <<<"$in_use"; then continue; fi
      if [ "$repo" = "<none>" ] || [ "$tag" = "<none>" ]; then
        limit=$dcutoff
      else
        n=${prev[$repo]:-0}; prev[$repo]=$((n + 1))
        if [ "$n" -lt "$IMAGE_KEEP_PREVIOUS" ]; then continue; fi
        limit=$cutoff
      fi
      if [ "$ts" -eq 0 ] || [ "$ts" -gt "$limit" ]; then continue; fi
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
      log "  [dry-run] $c: enforce would run $REAP_SCRIPT $e --sweep (removes only clean+pushed finished slots)"
    else
      if ! docker exec "$c" test -f "$REAP_SCRIPT"; then
        log "  ERROR $c: reap script $REAP_SCRIPT missing — slots NOT swept"; KEPT_SLOTS="$KEPT_SLOTS $c:reap-missing"; continue
      fi
      out=$(docker exec "$c" sh "$REAP_SCRIPT" "$e" --sweep 2>&1)
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

# ── 7. GitHub runner containers ───────────────────────────────────────────
# Self-update leaves bin.<ver>/externals.<ver>/_update next to the live ones and
# every job leaves its checkout under the work dir (a bind mount on the host
# disk). Only an IDLE runner (no Runner.Worker) is touched, and only paths older
# than the window; the live bin/ and externals/ are never named here.
RUNNER_SWEEP='
W=${RUNNER_WORKDIR:-/tmp/runner/work}; D=$1; R=/actions-runner
n=0
if [ -d "$R/bin" ]; then
  for p in "$R"/bin.* "$R"/externals.* "$R"/_work/_update "$W/_update"; do
    [ -e "$p" ] || continue; echo "rm $p"; [ "$2" = 1 ] || rm -rf "$p"
  done
fi
for p in "$R"/_diag/*; do
  [ -f "$p" ] || continue
  [ -n "$(find "$p" -mtime +7 2>/dev/null)" ] || continue; echo "rm $p"; [ "$2" = 1 ] || rm -f "$p"
done
if [ -d "$W" ]; then
  for p in "$W"/*; do
    [ -d "$p" ] || continue
    case "${p##*/}" in _PipelineMapping) continue ;; esac
    [ -z "$(find "$p" -maxdepth 0 -mtime +$D 2>/dev/null)" ] && [ "$D" != 0 ] && continue
    echo "rm $p"; [ "$2" = 1 ] || rm -rf "$p"
  done
fi'
sweep_runners() {
  local c busy
  for c in $(docker ps --format '{{.Names}} {{.Image}}' | awk -v m="$RUNNER_IMAGE_MATCH" 'index($2, m) {print $1}'); do
    busy=$(docker exec "$c" sh -c 'grep -l "Runner[.]Worker" /proc/[0-9]*/cmdline 2>/dev/null | wc -l' 2>/dev/null || echo 1)
    if [ "${busy:-1}" != 0 ]; then log "  SKIP $c: a job is running"; continue; fi
    out=$(docker exec -e RUNNER_WORKDIR="${RUNNER_WORKDIR:-}" "$c" sh -c "$RUNNER_SWEEP" _ "$RUNNER_WORK_MIN_AGE_DAYS" "$DRY" 2>&1)
    while IFS= read -r l; do [ -n "$l" ] && { log "  $c: $([ $DRY = 1 ] && echo '[dry-run] would ')$l"; N_RUNNER=$((N_RUNNER + 1)); }; done <<<"$out"
  done
}

# ── 8. Gradle cache (my-ai-api-home) ──────────────────────────────────────
# Everything below is derived or re-downloadable. A dir is stale when no file in
# it was read (atime) or written (mtime) within GRADLE_MAX_AGE_DAYS.
gradle_stale() { [ -z "$(find "$1" -type f \( -atime -"$GRADLE_MAX_AGE_DAYS" -o -mtime -"$GRADLE_MAX_AGE_DAYS" \) 2>/dev/null | head -n 1)" ]; }
gradle_rm() {
  if [ $DRY = 1 ]; then log "  [dry-run] would remove ${1#"$GRADLE_HOME_PATH"/}"; else rm -rf "$1" && log "  removed ${1#"$GRADLE_HOME_PATH"/}"; fi
  N_GRADLE=$((N_GRADLE + 1))
}
trim_gradle() {
  [ -d "$GRADLE_HOME_PATH/caches" ] || { log "  SKIP: $GRADLE_HOME_PATH/caches not mounted"; return 0; }
  local d
  for d in "$GRADLE_HOME_PATH"/caches/transforms-* "$GRADLE_HOME_PATH"/caches/jars-* "$GRADLE_HOME_PATH"/caches/build-cache-* "$GRADLE_HOME_PATH"/caches/[0-9]*.* "$GRADLE_HOME_PATH"/caches/modules-2/files-2.1/*/*/* "$GRADLE_HOME_PATH"/wrapper/dists/*/*; do
    [ -d "$d" ] || continue
    case "$d" in
      */transforms-*|*/jars-*|*/build-cache-*|*/caches/[0-9]*.*) # the cache roots (incl. per-gradle-version caches/8.13): judge each entry, not the root
        for e in "$d"/*; do [ -d "$e" ] && gradle_stale "$e" && gradle_rm "$e"; done ;;
      *) gradle_stale "$d" && gradle_rm "$d" ;;
    esac
  done
  # daemon logs
  for d in "$GRADLE_HOME_PATH"/daemon/*/*.log; do
    [ -f "$d" ] && [ -n "$(find "$d" -mtime +"$GRADLE_MAX_AGE_DAYS" 2>/dev/null)" ] && gradle_rm "$d"
  done
}

# ── 9. cgc lance volumes ──────────────────────────────────────────────────
# VERBATIM from cloud-infra 1_cicd/src/ops/cloud-cgc-db-restore-all.sh (#988).
lance_newest_manifest() { # $1 = table dir -> stdout: newest manifest file name
  ls "$1/_versions" 2>/dev/null | awk '
    /^[0-9]+\.manifest$/ {
      n = $0; sub(/\.manifest$/, "", n)
      if (length(n) == 20 && substr(n, 1, 6) == "184467") {
        if (v2 == "" || (n "") < (v2 "")) v2 = n
      } else if (v1 == "" || n + 0 > v1 + 0) v1 = n
    }
    END { if (v2 != "") print v2 ".manifest"; else if (v1 != "") print v1 ".manifest" }'
}

lance_prune_old_versions() { # $1 = octocode home (or staging tree), $2 = keep count
  _lpo_keep="${2:-2}"; _lpo_n=0
  for _lpo_t in "$1"/*/storage/*.lance; do
    [ -d "$_lpo_t/_versions" ] || continue
    _lpo_new=$(lance_newest_manifest "$_lpo_t")
    [ -n "$_lpo_new" ] || continue
    case "$_lpo_new" in
      184467*) _lpo_order="sort" ;;   # V2: newest first ascending
      *)       _lpo_order="sort -rn" ;;
    esac
    for _lpo_m in $(ls "$_lpo_t/_versions" | grep -E '^[0-9]+\.manifest$' | $_lpo_order | awk -v k="$_lpo_keep" 'NR > k'); do
      [ "$_lpo_m" = "$_lpo_new" ] && continue
      rm -f "$_lpo_t/_versions/$_lpo_m" && _lpo_n=$((_lpo_n + 1))
    done
  done
  [ "$_lpo_n" -gt 0 ] && echo "[cgc-db] pruned $_lpo_n superseded lance manifest(s) under $1 (kept newest $_lpo_keep per table)"
  :
}

lance_gc_unreferenced_data() { # $1 = octocode home (or staging tree)
  _lgc_n=0; _lgc_kb=0
  for _lgc_t in "$1"/*/storage/*.lance; do
    [ -d "$_lgc_t/_versions" ] && [ -d "$_lgc_t/data" ] || continue
    _lgc_drop=$(
      { for _lgc_f in "$_lgc_t"/data/*.lance; do
          [ -e "$_lgc_f" ] && printf 'D %s\n' "${_lgc_f##*/}"
        done
        for _lgc_m in "$_lgc_t"/_versions/*.manifest; do
          [ -f "$_lgc_m" ] || continue
          tr -c '0-9a-f.ln' '\n' < "$_lgc_m" | grep -oE '[0-9a-f]{32,}\.lance' | sed 's/^/R /'
        done
      } | awk '
        $1 == "D" { d[++nd] = $2; next }
        $1 == "R" { nr++; s = $2; for (i = 1; i <= length(s); i++) ref[substr(s, i)] = 1 }
        END {
          if (nr == 0) exit 1
          k = 0; for (j = 1; j <= nd; j++) if (d[j] in ref) k++
          if (k == 0) exit 1
          for (j = 1; j <= nd; j++) if (!(d[j] in ref)) print d[j]
        }') || continue
    [ -n "$_lgc_drop" ] || continue
    _lgc_b=$(du -sk "$_lgc_t/data" 2>/dev/null | cut -f1)
    for _lgc_f in $_lgc_drop; do
      rm -f "$_lgc_t/data/$_lgc_f" && _lgc_n=$((_lgc_n + 1))
    done
    _lgc_a=$(du -sk "$_lgc_t/data" 2>/dev/null | cut -f1)
    _lgc_kb=$((_lgc_kb + ${_lgc_b:-0} - ${_lgc_a:-0}))
  done
  [ "$_lgc_n" -gt 0 ] && echo "[cgc-db] removed $_lgc_n unreferenced lance data fragment(s) under $1 ($((_lgc_kb / 1024)) MB)"
  :
}

gc_lance_volumes() {
  local h
  for h in $LANCE_HOMES; do
    [ -d "$h" ] || { log "  SKIP $h: not mounted"; continue; }
    # a restore or index write in progress: leave the volume alone
    if [ -n "$(find "$h" -type f -mmin -60 2>/dev/null | head -n 1)" ]; then log "  SKIP $h: written in the last 60 min"; continue; fi
    if [ $DRY = 1 ]; then
      log "  [dry-run] would prune superseded manifests + unreferenced fragments under $h ($(du -sm "$h" 2>/dev/null | cut -f1) MB now)"
    else
      lance_prune_old_versions "$h" 2 2>&1 | while IFS= read -r l; do log "  $l"; done
      lance_gc_unreferenced_data "$h" 2>&1 | while IFS= read -r l; do log "  $l"; done
    fi
  done
}

# ── 10. regenerable caches ────────────────────────────────────────────────
cache_rm() { # $1 path, $2 label
  if [ $DRY = 1 ]; then log "  [dry-run] would remove $2"; else rm -rf "$1" && log "  removed $2"; fi
  N_CACHE=$((N_CACHE + 1))
}
trim_caches() {
  local d m n mb loose packs
  # a) cgc-db restore staging orphans (the restore now cleans up on signals too;
  #    this catches SIGKILL / VM reset). A live restore is far younger than the window.
  if [ -d "$STAGING_PARENT" ]; then
    for d in "$STAGING_PARENT"/cgc-db-staging.*; do
      [ -d "$d" ] || continue
      [ -n "$(find "$d" -maxdepth 0 -mmin +$((STAGING_MAX_AGE_HOURS * 60)) 2>/dev/null)" ] || continue
      [ -z "$(find "$d" -mmin -$((STAGING_MAX_AGE_HOURS * 60)) 2>/dev/null | head -n 1)" ] || continue
      cache_rm "$d" "staging orphan ${d##*/} ($(du -sm "$d" 2>/dev/null | cut -f1) MB)"
    done
  else log "  SKIP staging: $STAGING_PARENT not mounted"; fi
  # b) npm content cache: npm verifies integrity and refetches anything missing.
  for d in $NPM_CACHE_HOMES; do
    [ -d "$d/.npm/_cacache" ] || continue
    mb=$(du -sm "$d/.npm/_cacache" 2>/dev/null | cut -f1)
    [ "${mb:-0}" -gt "$NPM_CACHE_MAX_MB" ] || continue
    n=$(docker exec "$NPM_CACHE_CONTAINER" sh -c 'grep -l "npm\|npx" /proc/[0-9]*/cmdline 2>/dev/null | wc -l' 2>/dev/null || echo 0)
    if [ "${n:-0}" != 0 ]; then log "  SKIP npm cache in $d: npm is running in $NPM_CACHE_CONTAINER"; continue; fi
    cache_rm "$d/.npm/_cacache" "npm _cacache in $d (${mb} MB > ${NPM_CACHE_MAX_MB} MB)"
  done
  # c) git clones: repack loose objects / many packs. Never --prune=now.
  command -v git >/dev/null 2>&1 || { log "  SKIP git gc: git not installed"; return 0; }
  for m in $GIT_GC_ROOTS; do
    [ -d "$m" ] || continue
    for d in "$m"/*/; do
      [ -d "$d.git/objects" ] || continue
      loose=$(git -c safe.directory='*' -C "$d" count-objects -v 2>/dev/null | awk '/^size:/{print int($2/1024)}')
      packs=$(git -c safe.directory='*' -C "$d" count-objects -v 2>/dev/null | awk '/^packs:/{print $2}')
      [ "${loose:-0}" -gt "$GIT_GC_LOOSE_MB" ] || [ "${packs:-0}" -gt "$GIT_GC_MAX_PACKS" ] || continue
      [ ! -e "$d.git/index.lock" ] && [ ! -e "$d.git/gc.pid" ] || { log "  SKIP git gc ${d}: repo busy"; continue; }
      if [ $DRY = 1 ]; then log "  [dry-run] would git gc $d (loose ${loose} MB, ${packs} packs)"
      else
        owner=$(stat -c %u:%g "$d.git")
        nice -n 19 git -c safe.directory='*' -c pack.threads=1 -C "$d" gc --quiet 2>&1 | tail -n 2 | while IFS= read -r l; do log "  $l"; done
        chown -R "$owner" "$d.git" 2>/dev/null
        log "  git gc $d (was loose ${loose} MB, ${packs} packs)"
      fi
      N_CACHE=$((N_CACHE + 1))
    done
  done
}

notify() {
  [ -n "$NTFY_URL" ] || return 0
  curl -fsS -m 10 -H "Title: $1" -H "Priority: ${3:-default}" -H "Tags: floppy_disk" \
    -d "$2" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || log "WARN: ntfy publish failed"
}

run_pass() {
  mkdir -p "$STATE_DIR"
  # one pass at a time (cron + the watchdog's aggressive call); a lock older than 2h is stale
  if ! mkdir "$STATE_DIR/.lock" 2>/dev/null; then
    if [ -n "$(find "$STATE_DIR/.lock" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rmdir "$STATE_DIR/.lock"; mkdir "$STATE_DIR/.lock" || return 0
    else log "another pass is running — exiting"; return 0; fi
  fi
  trap 'rmdir "$STATE_DIR/.lock" 2>/dev/null' EXIT
  # bound the janitor's own log (it is a volume on the very disk it protects)
  [ -f "$STATE_DIR/janitor.log" ] && [ "$(wc -c <"$STATE_DIR/janitor.log")" -gt 5242880 ] && tail -c 1048576 "$STATE_DIR/janitor.log" > "$STATE_DIR/janitor.log.tmp" && mv "$STATE_DIR/janitor.log.tmp" "$STATE_DIR/janitor.log"
  local before after
  before=$(free_kb)
  log "disk-janitor pass MODE=$MODE aggressive=$AGGRESSIVE — host / free $((before / 1048576)) GB ($(pct_used)% used)"
  log "images: dangling >${DANGLING_MIN_AGE_HOURS}h; unused >${IMAGE_MIN_AGE_HOURS}h beyond in-use + ${IMAGE_KEEP_PREVIOUS} previous/repo"; prune_images
  log "build cache: $([ "$AGGRESSIVE" = 1 ] && echo 'all unused' || echo ">${BUILD_CACHE_MIN_AGE_HOURS}h")"
  if [ "$AGGRESSIVE" = 1 ]; then bflt=(-af); else bflt=(-f --filter "until=${BUILD_CACHE_MIN_AGE_HOURS}h"); fi
  if [ $DRY = 1 ]; then log "  [dry-run] would run: docker builder prune ${bflt[*]}"
  else docker builder prune "${bflt[@]}" 2>&1 | tail -1 | while IFS= read -r l; do log "  $l"; done; fi
  log "volumes: anonymous+dangling+unlabelled, >${VOLUME_MIN_AGE_DAYS}d"; prune_volumes
  log "dispatch _work slots"; sweep_slots
  log "dispatch logs >${LOG_RETENTION_DAYS}d"; prune_logs
  log "github runners: self-update folders, _diag, _work >${RUNNER_WORK_MIN_AGE_DAYS}d"; sweep_runners
  log "gradle cache >${GRADLE_MAX_AGE_DAYS}d unused"; trim_gradle
  log "cgc lance volumes"; gc_lance_volumes
  log "caches: staging >${STAGING_MAX_AGE_HOURS}h, npm >${NPM_CACHE_MAX_MB}MB, git loose >${GIT_GC_LOOSE_MB}MB/packs >${GIT_GC_MAX_PACKS}"; trim_caches
  after=$(free_kb)
  local free_gb=$((after / 1048576)) used; used=$(pct_used)
  log "done — images=$N_IMG volumes=$N_VOL logs=$N_LOGS runner_paths=$N_RUNNER gradle_dirs=$N_GRADLE caches=$N_CACHE kept_slots='${KEPT_SLOTS# }' free ${free_gb} GB (${used}% used), reclaimed $(((after - before) / 1024)) MB"
  cat >"$STATE_DIR/metrics.json.tmp" <<EOF
{"ts":"$(date -u +%FT%TZ)","mode":"$MODE","free_gb":$free_gb,"used_pct":${used:-null},"reclaimed_mb":$(((after - before) / 1024)),"images":$N_IMG,"volumes":$N_VOL,"logs":$N_LOGS,"runner_paths":$N_RUNNER,"gradle_dirs":$N_GRADLE,"caches":$N_CACHE,"aggressive":$AGGRESSIVE,"kept_slots":"${KEPT_SLOTS# }","alert_free_gb":$ALERT_FREE_GB}
EOF
  mv "$STATE_DIR/metrics.json.tmp" "$STATE_DIR/metrics.json"
  if [ -n "$after" ] && [ "$free_gb" -lt "$ALERT_FREE_GB" ]; then
    notify "oci-apps disk low: ${free_gb} GB free" \
      "oci-apps / is ${used}% used, ${free_gb} GB free (< ${ALERT_FREE_GB} GB) after disk-janitor MODE=$MODE. Candidates: images=$N_IMG volumes=$N_VOL logs=$N_LOGS. Slots kept for unpushed/uncommitted work: ${KEPT_SLOTS:-none}." high
  fi
  rmdir "$STATE_DIR/.lock" 2>/dev/null
}

log "disk-janitor starting — schedule='$SCHEDULE' mode=$MODE"
if [ "${RUN_ONCE:-false}" = "true" ] || [ "$AGGRESSIVE" = 1 ] || ! command -v crond >/dev/null 2>&1; then
  run_pass; exit 0
fi
echo "$SCHEDULE $(readlink -f "$0") >> $STATE_DIR/janitor.log 2>&1" > /etc/crontabs/root
export RUN_ONCE=true
run_pass
log "handing off to cron ($SCHEDULE)"
exec crond -f -l 2
