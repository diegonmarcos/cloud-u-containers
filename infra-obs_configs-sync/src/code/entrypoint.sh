#!/bin/bash
# configs-sync (#1148): regenerate the consolidated + derived fleet JSONs and publish them to the
# data repo (repo as db). Loop: every SCHEDULE_MIN minutes. ONE pass: `entrypoint.sh once`.
# Token: GH_TOKEN from the env file; never logged, never put in a URL that is printed.
set -uo pipefail
W=/work
APP=/app
log() { printf '[%s] configs-sync: %s\n' "$(date '+%F %T')" "$*"; }

clone() { # repo dir
  local url="https://x-access-token:${GH_TOKEN:-}@github.com/$1.git"
  if [ -d "$2/.git" ]; then git -C "$2" fetch -q --depth 1 origin main && git -C "$2" reset -q --hard origin/main
  else git clone -q --depth 1 "$url" "$2"; fi
}

pass() {
  mkdir -p "$W"
  clone "$CONTAINERS_REPO" "$W/containers" || { log "clone containers failed"; return 1; }
  clone "$DATA_REPO" "$W/data" || { log "clone data failed"; return 1; }
  OUT="$W/out"; rm -rf "${OUT:?}"; mkdir -p "$OUT"
  node "$APP/containers-declared.mjs" "$W/containers" "$OUT/containers-declared.json" || return 1
  # guard BEFORE publishing: no stale or overlapping container names ever reach the data repo
  node "$APP/containers-guard.mjs" "$W/containers" "$OUT/containers-declared.json" || { log "guard failed; nothing published"; return 1; }
  if [ "${MODE:-full}" = full ]; then
    clone "$INFRA_REPO" "$W/infra" || { log "clone infra failed"; return 1; }
    rm -rf "$W/infra/a_solutions"; ln -s "$W/containers" "$W/infra/a_solutions"
    (cd "$W/infra" && bash 1_cloud-configs/build.sh all) || { log "1_cloud-configs derive failed"; return 1; }
    D="$W/infra/1_cloud-configs/dist"
    cp "$D"/_cloud-data-consolidated.json "$D"/cloud-fleet-*.json "$D"/mesh-snapshot.json "$D"/watchdog.json "$OUT/" 2>/dev/null
    mkdir -p "$OUT/build"; cp "$D"/build-*.json "$OUT/build/" 2>/dev/null
  fi
  # replace the published files; keep README and .git
  rm -rf "$W/data/build"; cp -r "$OUT"/. "$W/data/"
  cd "$W/data" || return 1
  git add -A
  if git diff --cached --quiet; then log "no change"; touch "$W/last-ok"; return 0; fi
  git -c user.name="configs-sync" -c user.email="configs-sync@users.noreply.github.com" \
    commit -q -m "configs-sync: regenerate fleet JSONs" && git push -q origin HEAD:main || { log "push failed"; return 1; }
  log "published"; touch "$W/last-ok"
}

if [ "${1:-}" = once ]; then pass; exit $?; fi
while true; do pass || true; sleep $(( ${SCHEDULE_MIN:-15} * 60 )); done
