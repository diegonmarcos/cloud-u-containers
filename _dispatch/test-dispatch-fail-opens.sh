#!/bin/sh
# #510 — every way a dispatched agent ends having done nothing must end NON-ZERO.
#
# Drives the REAL fire.sh -> prep.sh -> run.sh in this directory, reached through the same
# one-line shim ~/git/_dispatch/ carries (SHIM below is that file's content), against a
# scratch tree with `claude`/`goose` stubbed on PATH. Each case simulates one fail-open seen
# in production and asserts the exit code the runner gives it:
#   90 auth expired (2026-09-24: seven agents, rc=1, ~190-byte logs, 9s each)
#   90 session limit already hit at pre-flight
#   89 brief unreadable (2026-09-24: uid 1001 mode 0600 briefs, agents exited rc=0)
#   88 ended awaiting a wakeup (slot 498/500)   87 session limit mid-run (#508)
#   86 goose max-turns marker (wave-3 slot 444)
# and, for prep.sh: the clone hardlinks nothing (cloud-infra EPERM, #558) and the brief is
# made 0644 or the slot aborts before the clone.
#
# Usage: sh test-dispatch-fail-opens.sh
# Registered in cloud-infra 9_others/test-registry.json (path a_solutions/_dispatch/...), run by
# lint-pipeline's registered-testers job — see run.sh's header for why not a service build.json.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
ck() { if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"; \
       else fail=$((fail+1)); echo "  FAIL $1 (want '$3', got '$2')"; fi; }
if [ "$(id -u)" = 0 ]; then
  echo "FAIL: must not run as root — root reads a mode-000 brief, so the unreadable-brief cases would pass vacuously"
  exit 1
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/_dispatch/logs" "$T/bin" "$T/cloud-u-containers"
ln -s "$HERE" "$T/cloud-u-containers/_dispatch"

# The production shim, verbatim — the header in each script says ~/git/_dispatch/ holds this.
SHIM='#!/bin/sh
# #510: SHIM. The dispatch runner is versioned at cloud-u-containers/_dispatch/ and
# tested there; this execs it so `git pull` of the shared tree is the deploy. No logic here.
exec sh "$(dirname "$0")/../cloud-u-containers/_dispatch/$(basename "$0")" "$@"'
for f in fire.sh prep.sh run.sh; do printf '%s\n' "$SHIM" > "$T/_dispatch/$f"; done

# Stub engines: record each call, answer the pre-flight probe (--max-turns 1) and the real
# run from separate env knobs.
cat > "$T/bin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"; cat > /dev/null
case " $* " in *" --max-turns 1 "*) printf '%s' "$PROBE_OUT"; exit "${PROBE_RC:-0}" ;; esac
printf '%s' "$MAIN_OUT"; exit "${MAIN_RC:-0}"
EOF
cat > "$T/bin/goose" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"; printf '%s' "$MAIN_OUT"; exit "${MAIN_RC:-0}"
EOF
chmod +x "$T/bin/claude" "$T/bin/goose"

# A source repo with loose objects, so a hardlinking clone is observable (links > 1).
git init -q "$T/demo"
echo hi > "$T/demo/f"; git -C "$T/demo" add f
git -C "$T/demo" -c user.name=t -c user.email=t@t commit -qm init

BRIEF=$T/_dispatch/dispatch-t510.md
OKREPORT="Done. Committed abc123, CI run 42 green. Nothing left unfinished."

# run <engine> <slot>  (env PROBE_*/MAIN_* set by caller) -> "rc=<n> calls=<n>"
run() {
  : > "$T/calls"; L=$T/_dispatch/logs/r-$2.log
  PATH="$T/bin:$PATH" CALLS="$T/calls" sh "$T/_dispatch/run.sh" "$1" "$2" "$BRIEF" "$L" > "$L" 2>&1
  echo "rc=$? calls=$(wc -l < "$T/calls" | tr -d ' ')"
}
AUTH_ERR="Failed to authenticate: OAuth session expired and could not be refreshed · api_error"

echo "── run.sh"
printf 'do the thing\n' > "$BRIEF"; chmod 0644 "$BRIEF"
export PROBE_OUT PROBE_RC MAIN_OUT MAIN_RC
PROBE_OUT=OK PROBE_RC=0 MAIN_OUT=$OKREPORT MAIN_RC=0
ck "healthy run: probe + real run, rc 0"                "$(run claude h1)" "rc=0 calls=2"
PROBE_OUT=$AUTH_ERR PROBE_RC=1
ck "(a) auth expired: refused at pre-flight, real run never started" "$(run claude a1)" "rc=90 calls=1"
ck "(a) the banner carries the probe's own words" \
   "$(grep -c 'AUTH PRE-FLIGHT FAILED' "$T/_dispatch/logs/r-a1.log")/$(grep -c 'OAuth session expired' "$T/_dispatch/logs/r-a1.log")" "1/1"
PROBE_OUT="Claude AI usage limit reached|1790000000" PROBE_RC=0
ck "(a) session limit at pre-flight: refused, rc 90" "$(run claude a2)" "rc=90 calls=1"
PROBE_OUT="" PROBE_RC=0
ck "(a) probe rc 0 but no OK: refused, rc 90"          "$(run claude a3)" "rc=90 calls=1"
PROBE_OUT=OK PROBE_RC=1
ck "(a) probe said OK but exited 1: refused, rc 90"    "$(run claude a4)" "rc=90 calls=1"
PROBE_OUT=OK PROBE_RC=0
chmod 000 "$BRIEF"
ck "(b) unreadable brief: rc 89, no engine started (not even the probe)" "$(run claude b1)" "rc=89 calls=0"
ck "(b) unreadable brief refused for goose too"         "$(run goose b2)" "rc=89 calls=0"
chmod 0644 "$BRIEF"
MAIN_OUT="I'll pause here and wait for the CI polling task to complete or the scheduled wakeup to fire."
ck "awaited wakeup (slot 498): rc 88"                   "$(run claude w1)" "rc=88 calls=2"
MAIN_OUT="Claude AI usage limit reached|1790000000"
ck "session limit mid-run (#508): rc 87"                "$(run claude s1)" "rc=87 calls=2"
MAIN_OUT="I've reached the maximum number of actions I can do without user input"
ck "goose max-turns marker: rc 86"                      "$(run goose m1)" "rc=86 calls=1"
MAIN_OUT=$OKREPORT

echo "── prep.sh"
prep() { # prep <slot> [brief] -> rc
  DISPATCH_ROOT=$T PATH="${PREP_PATH:-$PATH}" sh "$T/_dispatch/prep.sh" claude "$1" demo "$T/_dispatch/logs/p-$1.marker" ${2:+"$2"}
  echo $?
}
chmod 0600 "$BRIEF"
ck "prep rc 0 with a 0600 brief"                         "$(prep p1 "$BRIEF")" "0"
ck "(b) prep made the brief 0644"                        "$(stat -c %a "$BRIEF")" "644"
ck "cloned workspace exists"                             "$([ -d "$T/_work/p1/demo/.git" ] && echo yes)" "yes"
ck "(#558) the clone hardlinked NO object (links>1 count)" \
   "$(find "$T/_work/p1/demo/.git/objects" -type f -links +1 | wc -l | tr -d ' ')" "0"
# A brief prep cannot repair (foreign owner, simulated by a chmod that fails as EPERM would):
printf '#!/bin/sh\necho "chmod: Operation not permitted" >&2; exit 1\n' > "$T/bin/chmod"; chmod 755 "$T/bin/chmod" 2>/dev/null || /bin/chmod 755 "$T/bin/chmod"
/bin/chmod 000 "$BRIEF"
ck "(b) unrepairable brief: prep aborts rc 67"           "$(PREP_PATH="$T/bin:$PATH" prep p2 "$BRIEF")" "67"
ck "(b) ...before spending a clone on it"                "$([ -d "$T/_work/p2/demo" ] && echo cloned || echo none)" "none"
rm -f "$T/bin/chmod"; /bin/chmod 0644 "$BRIEF"

echo "── fire.sh (end to end, through the shims)"
fire() { # fire <slot> -> "FIRE exit rc=<n>" line from the marker
  cp "$BRIEF" "$T/_dispatch/dispatch-$1.md"; /bin/chmod 0600 "$T/_dispatch/dispatch-$1.md"
  DISPATCH_ROOT=$T PATH="$T/bin:$PATH" CALLS="$T/calls" sh "$T/_dispatch/fire.sh" claude "$1" demo >/dev/null 2>&1
  grep -o 'FIRE exit rc=[0-9]*' "$T/_dispatch/logs/dispatch-$1.marker"
}
: > "$T/calls"; PROBE_OUT=OK PROBE_RC=0
ck "fire: healthy slot"                                  "$(fire f1)" "FIRE exit rc=0"
ck "fire: handed the brief to prep, which made it 0644"  "$(stat -c %a "$T/_dispatch/dispatch-f1.md")" "644"
PROBE_OUT=$AUTH_ERR PROBE_RC=1
ck "fire: expired auth surfaces as rc 90, not 0 or 1"    "$(fire f2)" "FIRE exit rc=90"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
