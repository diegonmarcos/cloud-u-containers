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
"ps -aq"*) ;;
esac
STUB
chmod +x "$T/bin/docker"
OUT=$(PATH="$T/bin:$PATH" HOST_ROOT=/ STATE_DIR="$T/state" RUN_ONCE=true NTFY_URL= ALERT_FREE_GB=0 \
  DISPATCH_CONTAINERS=none:claude bash "$HERE/../code/entrypoint.sh")
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
echo "PASS disk-janitor dry-run policy"
