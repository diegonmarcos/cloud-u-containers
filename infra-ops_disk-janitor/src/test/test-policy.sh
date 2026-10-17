#!/usr/bin/env bash
# disk-janitor policy tester (#811): runs one dry-run pass against a stub docker
# and asserts exactly which objects the policy selects. Nothing real is touched.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/docker" <<'STUB'
case "$1 $2" in
"ps -aq") [ -z "$3" ] && echo c1;;
"inspect --format") echo sha256:aaa;;
"image ls") printf 'sha256:aaa\trepo/a\tlatest\nsha256:bbb\trepo/a\told1\nsha256:ccc\trepo/a\told2\nsha256:ddd\t<none>\t<none>\nsha256:eee\trepo/b\tnew\n';;
"image inspect") case "$5" in *aaa) echo 2026-10-01T00:00:00.1Z;; *bbb) echo 2026-09-01T00:00:00Z;; *ccc) echo 2026-08-01T00:00:00Z;; *ddd) echo 2026-08-01T00:00:00Z;; *eee) echo 2026-10-03T00:00:00Z;; esac;;
"volume ls") echo $(printf 'f%.0s' {1..64}); echo named_data;;
"volume inspect") if [ "$3" = "{{json .Labels}}" ]; then echo null; else echo "2026-09-01T00:00:00Z"; fi;;
"ps --format") echo nothing;;
"rmi "*|"builder prune") exit 0;;
"ps -aq"*) ;;
esac
STUB
chmod +x "$T/bin/docker"
# Gradle fixture: one stale and one fresh transform entry, one stale downloaded artifact.
G="$T/gradle"; mkdir -p "$G/caches/transforms-4/stale" "$G/caches/transforms-4/fresh" "$G/caches/modules-2/files-2.1/g/a/1.0/h"
touch "$G/caches/transforms-4/fresh/f" "$G/caches/transforms-4/stale/f" "$G/caches/modules-2/files-2.1/g/a/1.0/h/a.jar"
touch -d '90 days ago' "$G/caches/transforms-4/stale/f" "$G/caches/modules-2/files-2.1/g/a/1.0/h/a.jar"
# Staging fixture: one 3-day-old orphan, one live (fresh) staging dir.
S="$T/hostcache"; mkdir -p "$S/cgc-db-staging.OLD" "$S/cgc-db-staging.NEW"
touch "$S/cgc-db-staging.NEW/f"; touch -d '3 days ago' "$S/cgc-db-staging.OLD" "$S/cgc-db-staging.OLD"/. 
run() { STAGING_PARENT="$S" NPM_CACHE_HOMES="$T/nonpm" GIT_GC_ROOTS="$T/nogit" PATH="$T/bin:$PATH" HOST_ROOT=/ STATE_DIR="$T/state" RUN_ONCE=true NTFY_URL= ALERT_FREE_GB=0 \
  GRADLE_HOME_PATH="$G" LANCE_HOMES="$T/nolance" DISPATCH_CONTAINERS=none:claude "$@" bash "$HERE/../code/entrypoint.sh"; }
OUT=$(MODE=dry-run run env)
echo "$OUT"
fail() { echo "FAIL: $*"; exit 1; }
grep -q 'would rmi sha256:ddd' <<<"$OUT"   || fail "old dangling image not selected"
grep -q 'would rmi repo/a:old2' <<<"$OUT"  || fail "third-newest unused image not selected"
! grep -q 'rmi sha256:aaa\|repo/a:latest' <<<"$OUT" || fail "in-use image selected"
! grep -q 'repo/a:old1' <<<"$OUT"          || fail "keep-K image selected"
! grep -q 'repo/b:new' <<<"$OUT"           || fail "young image selected"
grep -q 'would remove anonymous volume ffffffffffff' <<<"$OUT" || fail "old anonymous volume not selected"
! grep -q 'named_data' <<<"$OUT"           || fail "named volume selected"
! grep -qE '\] +(rmi|removed) ' <<<"$OUT"  || fail "dry-run deleted something"
grep -q '"mode":"dry-run"' "$T/state/metrics.json" || fail "metrics not written"
grep -q 'would remove caches/transforms-4/stale' <<<"$OUT" || fail "stale gradle entry not selected"
! grep -q 'caches/transforms-4/fresh' <<<"$OUT"   || fail "fresh gradle entry selected"
[ -e "$G/caches/transforms-4/stale/f" ]    || fail "dry-run removed gradle data"
grep -q 'would remove staging orphan cgc-db-staging.OLD' <<<"$OUT" || fail "old staging orphan not selected"
! grep -q 'cgc-db-staging.NEW' <<<"$OUT" || fail "live staging dir selected"
# aggressive + enforce: same keep rules, deletion actually happens (stub docker rmi succeeds)
OUT2=$(MODE=enforce run env AGGRESSIVE=1)
echo "$OUT2" | grep -q 'aggressive=1'        || fail "aggressive flag not honoured"
grep -q 'rmi sha256:ddd' <<<"$OUT2"        || fail "aggressive: dangling image not removed"
! grep -q 'repo/a:old1\|repo/b:new\|rmi sha256:aaa' <<<"$OUT2" || fail "aggressive: previous/in-use image removed"
[ ! -e "$G/caches/transforms-4/stale" ]    || fail "enforce: stale gradle entry kept"
[ -e "$G/caches/transforms-4/fresh/f" ]    || fail "enforce: fresh gradle entry removed"
[ ! -e "$S/cgc-db-staging.OLD" ] && [ -e "$S/cgc-db-staging.NEW/f" ] || fail "enforce: staging sweep wrong"
echo "PASS disk-janitor dry-run policy"
