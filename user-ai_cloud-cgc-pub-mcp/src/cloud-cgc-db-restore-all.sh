#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-restore-all.sh — restore a full octocode home from the
#  per-repo GHCR images (multi-image consumer restore)
# ──────────────────────────────────────────────────────────────────────────
#  ARCHITECTURE (see cloud-cgc-db-package.sh header, which produces these
#  images): one GHCR image per repo — ghcr.io/diegonmarcos/cgc-db-<local_name>
#  — plus one shared base image ghcr.io/diegonmarcos/cgc-db-base:latest
#  carrying the octocode home ROOT state (config.toml + fastembed/ +
#  sentencetransformer/ model caches — never project data). Each image's
#  /octocode-db/. is exactly what a `docker cp` from a throwaway container
#  should drop into the target home: base → {config.toml, fastembed/,
#  sentencetransformer/}; a repo image → its single <project_id>/ dir.
#
#  This is the CONSUMER side of that split, replacing the single-image
#  cloud-cgc-db-pull.sh / cloud-cgc-db-restore.sh path once a target has
#  cut over to the matrix producer. Both old scripts are UNTOUCHED and stay
#  the default until cutover — see the callers (dagu DAG, compose.nix).
#
#  SEQUENCE (stage first, swap once):
#    1. base image  → STAGING          (hard error if missing — nothing to
#                                        seed from; see the seed instruction
#                                        printed below)
#    2. each repo image → STAGING      (missing image = bootstrap tolerance:
#                                        warn + skip, not fatal — a matrix
#                                        producer publishes repos one at a
#                                        time and the home is legitimately
#                                        incomplete until every job has run
#                                        at least once)
#    3. verify: (# project dirs staged) == (# repo images actually pulled).
#       This is what catches a name COLLISION between two repo images —
#       cp -a would silently merge two different <project_id>/ dirs into
#       one, and an aggregate count is the only thing that would ever
#       notice — as well as a corrupt or empty image.
#    4. ONLY once (1)-(3) all succeed: wipe TARGET once, cp -a STAGING in.
#  Every fallible step (network pulls, image extraction, the count check)
#  happens in STAGING before TARGET is touched at all, so any failure along
#  the way leaves TARGET exactly as it was — never half-wiped. Re-running is
#  safe: STAGING is always a fresh mktemp -d and TARGET is only ever touched
#  by the single final swap.
#
#  Per-image docker hygiene mirrors cloud-cgc-db-pull.sh: docker rm the
#  throwaway container AND docker rmi the transport image right after each
#  cp — the known 15G-pinning leak class documented there and in
#  cloud-cgc-db-package.sh (N images left tagged locally == N copies of the
#  DB pinned in the docker data-root at once; this restores potentially
#  index_repos-many images in one run, so the leak would be N-times worse
#  here than in the single-image path if left unfreed).
#
#  Args:    $1 = target octocode home dir (default: $OCTOCODE_HOME or
#           ~/.local/share/octocode — same default as cloud-cgc-db-pull.sh).
#           Ignored when CGC_DB_TARGET_VOLUME is set (see below).
#  Env:
#    CGC_DB_TARGET_VOLUME optional. When set, TARGET/$1 is ignored and the
#                         final swap writes into this docker NAMED VOLUME
#                         instead of a host path, via a throwaway container
#                         (`docker run -v $CGC_DB_TARGET_VOLUME:/dst ...`) —
#                         the SAME idiom cloud-cgc-db-restore.sh already uses
#                         and for the same reason: a named volume's host-side
#                         data dir is typically root-owned, and the oci-apps
#                         DAG runs this over SSH as a plain (non-root) user
#                         that only has docker-group socket access, not host
#                         root. The compose.nix db-restore path does not need
#                         this — compose mounts the volume INTO the container
#                         at oct.db_path, so from inside there it already IS
#                         a plain, directly-writable directory.
#    CGC_PRIVATE_REPOS    space-separated repos to EXCLUDE, because their GitHub
#                         source is private and their DB must never reach the
#                         volume the public MCP serves. Defaults to
#                         .runtime.octocode.private_repos from build.json;
#                         set explicitly where build.json is absent (the box).
#    CGC_INCLUDE_PRIVATE  set to 1 to disable that filter entirely. Only
#                         cloud-cgc-pvt-mcp may do this, and only together with
#                         its OWN CGC_DB_TARGET_VOLUME — never the public one.
#    CGC_DB_OWNER         optional "uid:gid" to chown -R the restored tree to.
#                         REQUIRED whenever the consumer runs as a different uid
#                         than whoever runs this script, which is the normal
#                         case: the images extract as the invoking user (1001
#                         over the oci-apps SSH path) while cloud-cgc-pub-mcp
#                         runs as appuser 10001:999, and octocode then fails
#                         with "Permission denied (os error 13)" because it
#                         opens the project dir read-write. Unset = no chown.
#    CGC_BUILD_JSON       override build.json path
#    CGC_INDEX_REPOS      space-separated repo list, overrides build.json
#                         .runtime.octocode.index_repos (mirrors
#                         cloud-cgc-db-update.sh's CGC_INDEX_REPOS — same
#                         override, same variable name, for one mental model)
#    CGC_DB_IMAGE_PREFIX  default build.json .per_repo_publish.image_prefix
#                         (falls back to ghcr.io/diegonmarcos/cgc-db-)
#    CGC_DB_BASE_IMAGE    default build.json .per_repo_publish.base_image
#                         (falls back to ${CGC_DB_IMAGE_PREFIX}base:${CGC_DB_TAG})
#    CGC_DB_TAG           default build.json .per_repo_publish.tag (falls
#                         back to latest)
#    CGC_BOOTSTRAP_TOLERANT  when "1": a MISSING base image (nothing published
#                         to GHCR yet — the very first scheduled run before any
#                         cloud-cgc-db-package.sh seed) prints a ::warning:: and
#                         exits 0 instead of the hard ::error::/exit 1 below,
#                         BEFORE any target (host dir or CGC_DB_TARGET_VOLUME)
#                         is touched. Set by the cgc-db-index.yml restore-all
#                         job (CI cron path) so the very first scheduled run —
#                         before any base image has ever been seeded — goes
#                         green instead of red and blocking the graphrag phase
#                         behind it. Unset (default) keeps the hard error for
#                         the dagu/manual restore path, where a missing base
#                         really is an operator mistake to surface loudly.
#
#  A per-repo image (cloud-cgc-db-package-repo.sh) also carries that repo's
#  OWN top-level .cgc-manifest-*.json / .cgc-index-manifest.json — producer
#  change-gate bookkeeping, not consumer state. Copying N repo images into
#  one staging tree would otherwise clobber that file N-1 times (same path,
#  last repo wins) with no signal anything was lost, since the count check
#  below only looks at directories. This script's callers (the oci-apps DAG
#  and the compose db-restore profile) are pure query consumers that never
#  read those manifests — the producer keeps its OWN authoritative copy via
#  cloud-cgc-db-pull.sh's CGC_PULL_MERGE (one repo + base at a time, so there
#  is nothing to clobber there) — so this script deliberately DROPS them
#  after staging each repo rather than leave one arbitrary repo's stale
#  bookkeeping sitting in a home it does not describe.
#    MCP_CONTAINER, NTFY_URL   optional — stop-for-the-swap, then restart +
#                         notify after a successful restore, same
#                         optional/no-op-if-unset contract as
#                         cloud-cgc-db-restore.sh. The container stays UP for
#                         the pull/stage phases (the slow ones) and is down
#                         only across the volume swap. Kept HERE
#                         rather than in the DAG/compose caller, because
#                         both of those carry zero logic of their own.
#                         MCP_CONTAINER set also triggers a kg-store
#                         (SurrealDB) export/ingest refresh via `docker exec`
#                         (OCTOCODE_SKIP_INDEX=1 reindex.sh) for the repos
#                         this run staged — the fix for the pipeline split
#                         where SurrealDB used to go stale by construction.
#                         BOTH stores get refreshed, not just the one whose
#                         volume this run swapped: cloud-cgc-pub-mcp (8002,
#                         PUBLIC repos only) and cloud-cgc-pvt-mcp (8001, ALL
#                         staged repos). See the kg-store block near the end
#                         of the script for the busybox exec-env password
#                         remap this needs — a plain `docker exec` does NOT
#                         pick up the pub container's entrypoint-time
#                         KG_STORE_PASS_PUB remap, so it must be redone here.
#    CGC_PUB_CONTAINER,
#    CGC_PVT_CONTAINER   optional container-name overrides for that kg-store
#                         refresh (default: build.json .containers.app /
#                         .containers.pvt .container_name).
#
#  Requires: docker, jq on PATH. GHCR auth (if any image is private) is the
#  caller's responsibility, same as every other cgc-db consumer script here.
# ──────────────────────────────────────────────────────────────────────────
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"

# build.json is read LAZILY, only for whichever of TAG/IMAGE_PREFIX/BASE_IMAGE/
# REPOS below the caller did NOT already supply via env. A deployed context
# with no repo checkout (the oci-apps DAG, the compose db-restore-multi
# service) supplies all four and never touches it — mirroring
# cloud-cgc-db-restore.sh's own env-first design ("the VM has no repo
# checkout"). A bare local invocation with none of those set still works
# exactly as before, resolving build.json from this script's own location.
BJ="${CGC_BUILD_JSON:-}"
need_bj() {
  [ -n "$BJ" ] && [ -f "$BJ" ] && return 0
  _root="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
  BJ="${_root:+$_root/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
  [ -n "$BJ" ] && [ -f "$BJ" ] && return 0
  echo "::error::cloud-cgc-pub-mcp build.json not found — needed because CGC_DB_TAG/CGC_DB_IMAGE_PREFIX/CGC_DB_BASE_IMAGE/CGC_INDEX_REPOS were not all supplied via env. Set CGC_BUILD_JSON, or supply every one of those (as the oci-apps DAG and the compose db-restore-multi service do)."
  exit 1
}

TARGET="${1:-${OCTOCODE_HOME:-$HOME/.local/share/octocode}}"
TAG="${CGC_DB_TAG:-}"
[ -n "$TAG" ] || { need_bj; TAG=$(jq -r '.per_repo_publish.tag // "latest"' "$BJ"); }
IMAGE_PREFIX="${CGC_DB_IMAGE_PREFIX:-}"
[ -n "$IMAGE_PREFIX" ] || { need_bj; IMAGE_PREFIX=$(jq -r '.per_repo_publish.image_prefix // "ghcr.io/diegonmarcos/cgc-db-"' "$BJ"); }
BASE_IMAGE="${CGC_DB_BASE_IMAGE:-}"
if [ -z "$BASE_IMAGE" ]; then
  need_bj
  BASE_IMAGE=$(jq -r '.per_repo_publish.base_image // empty' "$BJ")
fi
[ -n "$BASE_IMAGE" ] || BASE_IMAGE="${IMAGE_PREFIX}base:${TAG}"

if [ -n "${CGC_INDEX_REPOS:-}" ]; then
  REPOS="$CGC_INDEX_REPOS"
else
  need_bj
  REPOS=$(jq -r '.runtime.octocode.index_repos[]' "$BJ")
fi
[ -n "$REPOS" ] || { echo "::error::no repos to restore — empty .runtime.octocode.index_repos and CGC_INDEX_REPOS unset"; exit 1; }
# PUBLIC/PRIVATE SPLIT — a private repo's DB must never land in the volume the
# PUBLIC MCP mounts. Two guards exist and only one of them is visible:
#
#   1. Structural: oci-apps carries NO ghcr.io credentials ("auths": {} in its
#      ~/.docker/config.json) and pulls anonymously, so a package that really is
#      private cannot be fetched there at all. Genuine, but implicit — a single
#      `docker login` on that box silently retires it with nothing to notice.
#   2. This filter: declared in build.json, greppable, credential-independent.
#
# Deliberately applied to CGC_INDEX_REPOS as well as the build.json list. The
# manual/DAG path passes an explicit repo list, and that is precisely the path
# most likely to be handed "all 8" by a human who has lost track of which are
# private — this run of the restore was handed exactly that.
#
# cloud-cgc-pvt-mcp opts in with CGC_INCLUDE_PRIVATE=1, which MUST be paired
# with its own CGC_DB_TARGET_VOLUME — never the public one.
if [ "${CGC_INCLUDE_PRIVATE:-0}" = "1" ]; then
  # Enforced, not merely documented. Until now the "never the public one" pairing
  # above was a comment, and a comment does not stop `CGC_INCLUDE_PRIVATE=1` from
  # being set on the PUBLIC restore service — one copy-paste and every private
  # repo's DB lands in the volume the internet-facing MCP reads. The whole
  # public/private split is "the private DBs are not in that volume", so this is
  # the one invariant the split rests on; it gets a check, not a comment.
  #
  # Resolved from build.json when the caller did not name it, because the
  # container that runs this has no checkout and the env is all it has. If we
  # cannot determine the public volume name we refuse as well: an unverifiable
  # target is exactly the case where failing open loses the private repos.
  _pub_vol="${CGC_PUBLIC_DB_VOLUME:-}"
  if [ -z "$_pub_vol" ]; then
    # Same resolution the rest of the script uses (need_bj), but deliberately
    # non-fatal: when build.json is unreachable we refuse with the specific
    # message below rather than need_bj's generic "build.json not found".
    _ibj="${BJ:-}"
    if [ -z "$_ibj" ] || [ ! -f "$_ibj" ]; then
      _iroot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
      _ibj="${_iroot:+$_iroot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
    fi
    [ -n "$_ibj" ] && [ -f "$_ibj" ] \
      && _pub_vol=$(jq -r '.runtime.octocode.db_volume // empty' "$_ibj" 2>/dev/null)
  fi
  _eff_target="${CGC_DB_TARGET_VOLUME:-}"
  if [ -z "$_eff_target" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 requires an explicit CGC_DB_TARGET_VOLUME (the private volume). Refusing to write private repo DBs to the default target '$TARGET'."
    exit 1
  fi
  if [ -z "$_pub_vol" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 but the PUBLIC volume name is unknown (set CGC_PUBLIC_DB_VOLUME or make build.json readable) — cannot prove '$_eff_target' is not the public volume. Refusing."
    exit 1
  fi
  if [ "$_eff_target" = "$_pub_vol" ]; then
    echo "::error::[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 with CGC_DB_TARGET_VOLUME='$_eff_target', which IS the public volume. That would put every private repo's DB in the volume the public MCP serves. Refusing."
    exit 1
  fi
  echo "[cgc-db-restore-all] CGC_INCLUDE_PRIVATE=1 — private repos NOT filtered (target $_eff_target, public volume $_pub_vol untouched)"
else
  PRIVATE_REPOS="${CGC_PRIVATE_REPOS:-}"
  # Resolved independently of need_bj: that one only runs when the caller left
  # REPOS unset, so relying on it would silently disable this filter on exactly
  # the callers that pass an explicit repo list. A security control must not
  # fail open because of an unrelated lazy-load path.
  if [ -z "$PRIVATE_REPOS" ]; then
    _pbj="${BJ:-}"
    if [ -z "$_pbj" ] || [ ! -f "$_pbj" ]; then
      _proot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd)}"
      _pbj="${_proot:+$_proot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
    fi
    [ -n "$_pbj" ] && [ -f "$_pbj" ] \
      && PRIVATE_REPOS=$(jq -r '.runtime.octocode.private_repos[]?' "$_pbj" 2>/dev/null)
  fi
  # Fail LOUD, not silent. A deployed context legitimately has no build.json
  # (that is why compose passes CGC_PRIVATE_REPOS), so this cannot hard-error
  # without breaking the box — but an unfiltered restore into a public volume
  # must never pass unremarked.
  if [ -z "$PRIVATE_REPOS" ]; then
    echo "::warning::[cgc-db-restore-all] no private-repo list available (CGC_PRIVATE_REPOS unset and build.json unreadable) — restoring UNFILTERED; if this volume is served by the public MCP, confirm no private repo landed in it"
  fi
  if [ -n "$PRIVATE_REPOS" ]; then
    _kept=""
    for _r in $REPOS; do
      _skip=0
      for _p in $PRIVATE_REPOS; do
        [ "$_r" = "$_p" ] && { _skip=1; break; }
      done
      if [ "$_skip" = 1 ]; then
        echo "[cgc-db-restore-all] skipping PRIVATE repo $_r — not for the public volume"
      else
        _kept="$_kept $_r"
      fi
    done
    REPOS="${_kept# }"
    [ -n "$REPOS" ] || { echo "::error::[cgc-db-restore-all] every requested repo is private and CGC_INCLUDE_PRIVATE is not set — nothing to restore"; exit 1; }
  fi
fi

set -- $REPOS
TOTAL=$#

STAGING=$(mktemp -d)
CURRENT_CID=""
cleanup() {
  [ -n "$CURRENT_CID" ] && docker rm -f "$CURRENT_CID" >/dev/null 2>&1
  CURRENT_CID=""
  [ -n "${STAGING:-}" ] && [ -d "$STAGING" ] && rm -rf "$STAGING" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Extract one already-pulled image's /octocode-db/. into STAGING. Always
# removes the throwaway container (including on a failed `docker cp`, via
# CURRENT_CID + the EXIT trap above); the transport image is the caller's
# call (base: drop once after staging; repo: drop after every pull — see
# the loop below and the header comment on why that matters here).
stage_image() { # $1 = image ref
  CURRENT_CID=$(docker create "$1")
  docker cp "$CURRENT_CID:/octocode-db/." "$STAGING/"
  docker rm -f "$CURRENT_CID" >/dev/null 2>&1 || true
  CURRENT_CID=""
}

# Directories in STAGING that hold PROJECT data — everything except the
# base-mode root-state entries. Deliberately the SAME exclusion set as
# cloud-cgc-db-package.sh's find_project_dir(); keep the two in sync.
count_project_dirs() {
  _n=0
  for _e in "$STAGING"/*/; do
    [ -d "$_e" ] || continue
    case "${_e%/}" in
      */fastembed | */sentencetransformer) continue ;;
    esac
    _n=$((_n + 1))
  done
  echo "$_n"
}

# ── 1) base image — hard error: no base means nothing to restore onto ─────
#    EXCEPT under CGC_BOOTSTRAP_TOLERANT=1 (see header): the very first
#    scheduled run before any base has ever been seeded is not an operator
#    error, it is bootstrap — warn and exit 0 BEFORE touching TARGET at all.
echo "[cgc-db-restore-all] base: $BASE_IMAGE"
# Keep the probe's stderr. It used to be thrown away with `2>&1 >/dev/null`, so
# EVERY failure mode — DNS, auth, TLS, rate limit, genuinely-absent image — printed
# the same "not found on GHCR", which sent us seeding an image that already existed.
# The real message on 2026-08-22 was `lookup ghcr.io on 127.0.0.11:53: i/o timeout`:
# a compose-bridge DNS fault, not a missing image (see compose.nix network_mode).
_base_err=$(docker manifest inspect "$BASE_IMAGE" 2>&1 >/dev/null) || {
  if [ "${CGC_BOOTSTRAP_TOLERANT:-}" = "1" ]; then
    echo "::warning::[cgc-db-restore-all] base image $BASE_IMAGE not readable on GHCR — bootstrap: nothing to propagate yet"
    echo "::warning::[cgc-db-restore-all] docker said: ${_base_err:-<no output>}"
    exit 0
  fi
  echo "::error::[cgc-db-restore-all] base image $BASE_IMAGE not readable on GHCR."
  echo "::error::[cgc-db-restore-all] docker said: ${_base_err:-<no output>}"
  echo "::error::[cgc-db-restore-all] if that is a DNS/network error the image is probably fine — check egress before re-seeding."
  echo "::error::[cgc-db-restore-all] otherwise seed it once from an existing octocode home's root state: sh $HERE/cloud-cgc-db-package.sh <octocode-home-dir> $BASE_IMAGE latest"
  exit 1
}
docker pull -q "$BASE_IMAGE" >/dev/null
stage_image "$BASE_IMAGE"
docker rmi "$BASE_IMAGE" >/dev/null 2>&1 || true
echo "[cgc-db-restore-all] base staged"

# The base image's config.toml is whatever the phase that seeded it happened to
# have, and the SEMANTIC phase writes `[graphrag] enabled = false` (it skips
# graph building on purpose). That flag then rides into every consumer volume,
# which is why the box carried 45MB of graphrag_nodes.lance +
# graphrag_relationships.lance and still answered every graphrag call with
# "GraphRAG is not enabled in your configuration".
#
# A consumer is a READ-ONLY query surface: it never builds a graph, it only
# reads tables that already shipped, so `enabled` here means nothing more than
# "may I read what is present" and must be true. `use_llm` is deliberately NOT
# touched — that controls query-time LLM calls and would need a key on the box.
# Scoped by section so the identical `enabled = false` lines under
# [search.reranker] / [search.hybrid] / [graphrag.llm] are left alone.
if [ -f "$STAGING/config.toml" ]; then
  awk '
    /^\[/ { sec = $0 }
    sec == "[graphrag]" && /^enabled[[:space:]]*=[[:space:]]*false/ { print "enabled = true"; next }
    { print }
  ' "$STAGING/config.toml" > "$STAGING/config.toml.new" \
    && mv "$STAGING/config.toml.new" "$STAGING/config.toml" \
    && echo "[cgc-db-restore-all] graphrag reads enabled in consumer config.toml"
fi

# ── 2) each repo image — bootstrap tolerance: missing = warn + continue ────
FOUND=0
MISSING=""
# Repos actually staged this run — data-driven input to the kg-store
# (SurrealDB) export/ingest hook below; never a hardcoded list.
STAGED_REPOS=""
for r in "$@"; do
  img="${IMAGE_PREFIX}${r}:${TAG}"
  if ! docker manifest inspect "$img" >/dev/null 2>&1; then
    echo "::warning::[cgc-db-restore-all] $img not published yet — skipping $r (bootstrap tolerance)"
    MISSING="$MISSING $r"
    continue
  fi
  docker pull -q "$img" >/dev/null
  stage_image "$img"
  # Drop this repo's own change-gate manifest (see header) — it would silently
  # clobber the next repo's at the same path otherwise, and neither consumer
  # wired to this script reads it.
  rm -f "$STAGING"/.cgc-manifest-*.json "$STAGING"/.cgc-index-manifest.json 2>/dev/null || true
  docker rmi "$img" >/dev/null 2>&1 || true
  FOUND=$((FOUND + 1))
  STAGED_REPOS="$STAGED_REPOS $r"
  echo "[cgc-db-restore-all] staged $r ($FOUND/$TOTAL)"
done

# ── 3) verify before TARGET is touched at all ───────────────────────────────
STAGED=$(count_project_dirs)
if [ "$STAGED" -ne "$FOUND" ]; then
  echo "::error::[cgc-db-restore-all] staged project-dir count ($STAGED) != repo images pulled ($FOUND) — refusing to swap into $TARGET"
  echo "::error::[cgc-db-restore-all] a name collision between two repo images (cp -a silently merging two different <project_id>/ dirs), or a malformed image, produces exactly this mismatch"
  exit 1
fi
if [ -n "$MISSING" ]; then
  echo "[cgc-db-restore-all] verified: $FOUND/$TOTAL repos staged (missing:$MISSING)"
else
  echo "[cgc-db-restore-all] verified: $FOUND/$TOTAL repos staged"
fi

# Down ONLY for the swap. Sections 1-3 pull every image and assemble the whole
# tree in $STAGING with the consumer still serving from the old volume, and that
# is the part that takes ~50 min. Stopping the container for the entire restore
# (which the GHA propagation step used to do, from the outside) turns a scheduled
# refresh into a 50-minute outage to save a swap that takes seconds.
#
# The restart is NOT done here: the MCP_CONTAINER block at the end of this file
# already runs `docker restart`, which starts a stopped container. Restarting
# rather than starting is also what the consumer needs — octocode caches open
# LanceDB handles, so a container that merely kept running through the swap
# would serve from unlinked inodes.
if [ -n "${MCP_CONTAINER:-}" ]; then
  docker stop "$MCP_CONTAINER" >/dev/null 2>&1 \
    && echo "[cgc-db-restore-all] stopped $MCP_CONTAINER for the swap" \
    || echo "[cgc-db-restore-all] WARN stop $MCP_CONTAINER failed (continuing)"
fi

# ── 4) swap: everything fallible already happened in STAGING ───────────────
if [ -n "${CGC_DB_TARGET_VOLUME:-}" ]; then
  # Container-mediated write — see CGC_DB_TARGET_VOLUME in the header. busybox
  # is always pullable; -v NAME:/dst auto-creates the volume if it somehow
  # doesn't exist yet, matching plain `docker run -v name:...` behaviour.
  # chmod 0755 AFTER the cp is load-bearing, not tidiness. `cp -a /src/. /dst/`
  # stamps the SOURCE directory's mode and owner onto /dst, and $STAGING comes
  # from `mktemp -d`, which is 0700 owned by whoever ran this (uid 1001 over the
  # oci-apps SSH path). The app container runs as a different uid (10001), so the
  # volume root came back 0700 1001:1001 and octocode could not even traverse in:
  # every tool call died with "Permission denied (os error 13)" while every child
  # dir sat there readable at 0755. Consumers mount this volume read-only as an
  # unrelated uid, so the root has to be world-traversable.
  docker run --rm -e CGC_DB_OWNER="${CGC_DB_OWNER:-}" \
    -v "$CGC_DB_TARGET_VOLUME:/dst" -v "$STAGING:/src:ro" busybox \
    sh -c 'rm -rf /dst/* /dst/.[!.]* 2>/dev/null; cp -a /src/. /dst/; chmod 0755 /dst
           [ -n "$CGC_DB_OWNER" ] && chown -R "$CGC_DB_OWNER" /dst; :'
  echo "[cgc-db-restore-all] restored $FOUND repo(s) + base into volume $CGC_DB_TARGET_VOLUME"
else
  mkdir -p "$TARGET"
  rm -rf "$TARGET"/* "$TARGET"/.[!.]* 2>/dev/null || true
  cp -a "$STAGING"/. "$TARGET"/
  # Same reason as the volume branch above: cp -a copies mktemp -d's 0700 onto
  # TARGET, which locks out any consumer running as a different uid.
  chmod 0755 "$TARGET"
  [ -n "${CGC_DB_OWNER:-}" ] && chown -R "$CGC_DB_OWNER" "$TARGET" 2>/dev/null
  :
  echo "[cgc-db-restore-all] restored $FOUND repo(s) + base into $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
fi

# ── optional: restart + notify (mirrors cloud-cgc-db-restore.sh; kept here
# because the DAG and the compose caller both carry zero logic of their own)
CONTAINER="${MCP_CONTAINER:-}"
NTFY="${NTFY_URL:-}"
if [ -n "$CONTAINER" ]; then
  if docker restart "$CONTAINER" >/dev/null 2>&1; then
    echo "[cgc-db-restore-all] restarted $CONTAINER"
    # ── kg-store (SurrealDB) refresh — closes the split-pipeline gap ─────────
    # Both MCP containers run the SAME binaries image (python3 + node +
    # octocode-export.py + kg-ingest.mjs baked in) and both just came back up
    # on the LanceDB tree swapped in above, so both get the cheap
    # OCTOCODE_SKIP_INDEX=1 export→ingest tail — not just $CONTAINER, the one
    # this run happened to restart for the volume swap. Without this, only
    # whichever store's password happened to already be correct for a plain
    # `docker exec` ever received data (see the remap note below), which is
    # exactly the "pvt gets data, pub stays empty" bug this closes.
    #
    # BUSYBOX EXEC-ENV PASSWORD REMAP: cloud-cgc-pub-mcp and cloud-cgc-pvt-mcp
    # are the SAME image run twice. Each container's own entrypoint remaps its
    # KG_STORE_PASS_PUB (pub) onto KG_STORE_PASS for the server PROCESS it
    # starts — but that remap happens once, inside that entrypoint shell, and
    # is invisible to a fresh `docker exec`, which only ever sees the
    # container's ORIGINAL env_file. Both containers ship the SAME base
    # KG_STORE_PASS (the pvt password), so an un-remapped `docker exec` into
    # the pub container hits kg_store_pub (8002) with the pvt password →
    # HTTP 401, silently swallowed by the best-effort warning below. The pvt
    # container needs no remap: its base KG_STORE_PASS is already correct for
    # kg_store_pvt (8001). The fix re-does the remap ourselves for the pub
    # call only, evaluated INSIDE the container via `sh -c` so the real
    # secret is read from the container's own env and never touches this
    # script or its logs.
    #
    # PUBLIC/PRIVATE FILTER: kg_store_pub (feeds the public MCP) must never
    # carry a private repo's graph — same invariant as the LanceDB volume
    # split above. STAGED_REPOS is whatever THIS run actually staged (already
    # private-filtered on the default path, or every repo under
    # CGC_INCLUDE_PRIVATE=1); the pub tail additionally strips
    # CGC_PRIVATE_REPOS/build.json private_repos from it so a pvt-mode run
    # (CGC_INCLUDE_PRIVATE=1) can never leak a private repo into 8002.
    # kg_store_pvt (full store) always gets STAGED_REPOS as-is.
    if [ -n "$STAGED_REPOS" ]; then
      _kbj="${BJ:-}"
      if [ -z "$_kbj" ] || [ ! -f "$_kbj" ]; then
        _kroot="${CLOUD_ROOT:-$(cd "$HERE/../../.." 2>/dev/null && pwd || echo "")}"
        _kbj="${_kroot:+$_kroot/a_solutions/user-ai_cloud-cgc-pub-mcp/build.json}"
      fi
      KG_PRIVATE_REPOS="${CGC_PRIVATE_REPOS:-}"
      if [ -z "$KG_PRIVATE_REPOS" ] && [ -n "$_kbj" ] && [ -f "$_kbj" ]; then
        KG_PRIVATE_REPOS=$(jq -r '.runtime.octocode.private_repos[]?' "$_kbj" 2>/dev/null)
      fi
      PUB_CONTAINER="${CGC_PUB_CONTAINER:-}"
      [ -n "$PUB_CONTAINER" ] || [ -z "$_kbj" ] || [ ! -f "$_kbj" ] \
        || PUB_CONTAINER=$(jq -r '.containers.app.container_name // empty' "$_kbj" 2>/dev/null)
      PVT_CONTAINER="${CGC_PVT_CONTAINER:-}"
      [ -n "$PVT_CONTAINER" ] || [ -z "$_kbj" ] || [ ! -f "$_kbj" ] \
        || PVT_CONTAINER=$(jq -r '.containers.pvt.container_name // empty' "$_kbj" 2>/dev/null)
      # Final fallback: on the BOX neither the CGC_*_CONTAINER env nor the build.json
      # ($_kbj) is available, so derive both names from the already-resolved $CONTAINER
      # (=MCP_CONTAINER, e.g. cloud-cgc-pub-mcp) by the pub<->pvt name swap. Without
      # this the tail skipped ("container name unresolved") and NEITHER store refreshed.
      [ -n "$PUB_CONTAINER" ] || PUB_CONTAINER=$(printf '%s' "$CONTAINER" | sed 's/-pvt-/-pub-/')
      [ -n "$PVT_CONTAINER" ] || PVT_CONTAINER=$(printf '%s' "$CONTAINER" | sed 's/-pub-/-pvt-/')

      KG_PUBLIC_REPOS="$STAGED_REPOS"
      if [ -n "$KG_PRIVATE_REPOS" ]; then
        _kept=""
        for _r in $STAGED_REPOS; do
          _skip=0
          for _p in $KG_PRIVATE_REPOS; do
            [ "$_r" = "$_p" ] && { _skip=1; break; }
          done
          [ "$_skip" = 1 ] || _kept="$_kept $_r"
        done
        KG_PUBLIC_REPOS="${_kept# }"
      fi

      kg_refresh() { # $1 = container, $2 = repos, $3 = in-container wrapper cmd (or "sh /app/reindex.sh")
        _c="$1"; _repos="$2"; _cmd="$3"
        if [ -z "$_c" ]; then
          echo "[cgc-db-restore-all] kg-store refresh skipped — container name unresolved"
          return 0
        fi
        if [ -z "$_repos" ]; then
          echo "[cgc-db-restore-all] kg-store refresh skipped for $_c — no eligible repos"
          return 0
        fi
        if docker exec -e OCTOCODE_REPOS="$_repos" -e OCTOCODE_SKIP_INDEX=1 "$_c" sh -c "$_cmd"; then
          echo "[cgc-db-restore-all] kg-store refresh OK ($_c)"
        else
          echo "::warning::[cgc-db-restore-all] kg-store refresh failed for $_c (continuing — LanceDB restore already succeeded)"
        fi
      }

      kg_refresh "$PUB_CONTAINER" "$KG_PUBLIC_REPOS" 'KG_STORE_PASS="$KG_STORE_PASS_PUB" sh /app/reindex.sh'
      kg_refresh "$PVT_CONTAINER" "${STAGED_REPOS# }" 'sh /app/reindex.sh'
    else
      echo "[cgc-db-restore-all] kg-store refresh skipped — no repos staged this run"
    fi
  else
    echo "[cgc-db-restore-all] WARN restart $CONTAINER failed"
  fi
fi
if [ -n "$NTFY" ]; then
  if [ -n "$MISSING" ]; then
    _msg="cloud-cgc octocode DB restored (multi-image) — $FOUND/$TOTAL repos, missing:$MISSING"
  else
    _msg="cloud-cgc octocode DB restored (multi-image) — $FOUND/$TOTAL repos"
  fi
  [ -n "$CONTAINER" ] && _msg="$_msg + $CONTAINER restarted"
  curl -sf -d "$_msg" -H "Title: cgc-db restore-all" -H "Tags: arrow_down,white_check_mark" "$NTFY/ops" >/dev/null 2>&1 || true
fi
echo "[cgc-db-restore-all] RESTORE COMPLETE"
