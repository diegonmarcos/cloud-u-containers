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
#   88 ended awaiting a wakeup (slots 498/500, #562 first run)   87 session limit mid-run (#508)
#   86 goose max-turns marker (wave-3 slot 444)
# and, for prep.sh (#487 worktree conversion): the workspace is a detached worktree on the
# SOURCE's object store — a .git FILE, kilobytes, nothing hardlinked or copied (#558) — its
# pre-push hook is wired per-worktree without touching the shared config, a prune never takes
# another engine's worktree, root chowns the shared metadata, and the brief is made 0644 or the
# slot aborts before any workspace is made.
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
# The stub also records the directory it was STARTED IN (#633): that is the only observable
# that distinguishes an agent isolated in its slot from one loose in the shared tree.
cat > "$T/bin/claude" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"; [ -n "${PWDLOG:-}" ] && pwd -P >> "$PWDLOG"
cat >> "${STDINLOG:-/dev/null}"
case " $* " in *" --max-turns 1 "*) printf '%s' "$PROBE_OUT"; exit "${PROBE_RC:-0}" ;; esac
printf '%s' "$MAIN_OUT"; exit "${MAIN_RC:-0}"
EOF
cat > "$T/bin/goose" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"; printf '%s' "$MAIN_OUT"; exit "${MAIN_RC:-0}"
EOF
chmod +x "$T/bin/claude" "$T/bin/goose"

# A source repo with loose objects and ~1MB of history, so a copying or hardlinking workspace is
# observable (links > 1, or megabytes where a worktree takes kilobytes). core.hooksPath is preset
# in the SHARED config the way cloud-infra and cloud-u-android set it, so a prep that clobbers it
# shows up.
git init -q -b main "$T/demo"
head -c 1048576 /dev/urandom > "$T/demo/blob"; echo hi > "$T/demo/f"; git -C "$T/demo" add f blob
git -C "$T/demo" -c user.name=t -c user.email=t@t commit -qm init
git -C "$T/demo" rm -q --cached blob; rm "$T/demo/blob"
git -C "$T/demo" -c user.name=t -c user.email=t@t commit -qm 'drop blob'
git -C "$T/demo" config core.hooksPath 0_git/dist/hooks
# ...and that shared hooksPath carries a post-checkout, as cloud-infra's does (it clones submodules).
mkdir -p "$T/demo/0_git/dist/hooks"
printf '#!/bin/sh\ntouch "%s"\n' "$T/post-checkout.ran" > "$T/demo/0_git/dist/hooks/post-checkout"
/bin/chmod 755 "$T/demo/0_git/dist/hooks/post-checkout"
# ...and a branch guard, the shape that makes main rewrite-proof across the three repos
# (#475/#489) and enforces Diego's no-branches rule. #633's isolation must not weaken it, so the
# suite exercises it directly: it has to keep refusing an ordinary branch creation.
cat > "$T/demo/0_git/dist/hooks/reference-transaction" <<'GUARD'
#!/bin/sh
while read -r old _new ref; do
  case "$ref" in refs/heads/main) continue ;; refs/heads/*) ;; *) continue ;; esac
  [ "$old" = 0000000000000000000000000000000000000000 ] || continue
  echo "branch-guard REFUSED: $ref — commit directly to main, never create branches" >&2
  exit 1
done
exit 0
GUARD
/bin/chmod 755 "$T/demo/0_git/dist/hooks/reference-transaction"

BRIEF=$T/_dispatch/dispatch-t510.md
OKREPORT="Done. Committed abc123, CI run 42 green. Nothing left unfinished."

# #633: run.sh now REFUSES a claude slot that is not an isolated worktree, so the run.sh cases
# get a dispatch root of their own — kept apart from $T/demo so the worktree-list assertions in
# the prep.sh section below still enumerate exactly the slots that section makes.
RT=$T/rt
mkdir -p "$RT/_dispatch/logs"
git init -q -b main "$RT/demo"; echo hi > "$RT/demo/f"; git -C "$RT/demo" add f
git -C "$RT/demo" -c user.name=t -c user.email=t@t commit -qm init

# run <engine> <slot>  (env PROBE_*/MAIN_* set by caller) -> "rc=<n> calls=<n>"
# Each slot is prepped first — with no brief, so the unreadable-brief cases still reach run.sh.
run() {
  : > "$T/calls"; L=$RT/_dispatch/logs/r-$2.log
  DISPATCH_ROOT=$RT sh "$T/_dispatch/prep.sh" claude "$2" demo "$RT/_dispatch/logs/p-$2.marker" \
    > /dev/null 2>&1
  : > "$T/stdin"
  PATH="$T/bin:$PATH" CALLS="$T/calls" PWDLOG="$T/pwds" STDINLOG="$T/stdin" DISPATCH_ROOT=$RT \
    sh "$T/_dispatch/run.sh" "$1" "$2" "$BRIEF" "$L" > "$L" 2>&1
  echo "rc=$? calls=$(wc -l < "$T/calls" | tr -d ' ')"
}
AUTH_ERR="Failed to authenticate: OAuth session expired and could not be refreshed · api_error"

echo "── run.sh"
printf 'do the thing\n' > "$BRIEF"; chmod 0644 "$BRIEF"
export PROBE_OUT PROBE_RC MAIN_OUT MAIN_RC
PROBE_OUT=OK PROBE_RC=0 MAIN_OUT=$OKREPORT MAIN_RC=0
: > "$T/pwds"
ck "healthy run: probe + real run, rc 0"                "$(run claude h1)" "rc=0 calls=2"
# #633: the collision that started this. The old cd targeted _work/$SLOT — the slot directory,
# one level above the workspace — and forgave failure, so the agent ran in the SHARED tree.
ck "(#633) the engine started INSIDE the slot's own worktree, not the shared tree" \
   "$(tail -1 "$T/pwds")" "$(cd "$RT/_work/h1/demo" && pwd -P)"
# Inside a slot, positively — not merely "differs from the shared tree". The original fail-open
# left the engine in whatever directory fire.sh happened to be invoked from, which is neither.
WORKDIR=$(cd "$RT/_work" && pwd -P)
ck "(#633) ...and that is a dispatch slot, not the shared checkout or wherever fire.sh ran" \
   "$(case "$(tail -1 "$T/pwds")" in "$WORKDIR"/*) echo slot ;; *) echo elsewhere ;; esac)" "slot"
ck "(#633) --add-dir follows this dispatch root instead of a hardcoded shared path" \
   "$(grep -c -- "--add-dir $RT" "$T/calls")" "1"
# The declaration reaches the agent on STDIN — one shared copy, not per-brief prose.
ck "(#633) the engine is told its workspace path and the staging rules, every run" \
   "$(grep -c "Your workspace is $RT/_work/h1/demo" "$T/stdin")/$(grep -c "'git add -A', 'git add .' and 'git commit -a' are refused" "$T/stdin")" "1/1"
: > "$T/pwds"
run claude i1 > /dev/null; run claude i2 > /dev/null
ck "(#633) two slots never share a workspace" \
   "$(sort -u "$T/pwds" | wc -l | tr -d ' ')" "2"
PROBE_OUT=$AUTH_ERR PROBE_RC=1
ck "(a) auth expired: refused at pre-flight, real run never started" "$(run claude a1)" "rc=90 calls=1"
ck "(a) the banner carries the probe's own words" \
   "$(grep -c 'AUTH PRE-FLIGHT FAILED' "$RT/_dispatch/logs/r-a1.log")/$(grep -c 'OAuth session expired' "$RT/_dispatch/logs/r-a1.log")" "1/1"
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
MAIN_OUT="CI is still running on 56f57e334. The poller will wake me when it finishes."
ck "awaited wakeup, #562's first run (no wait/wakeup/polling words): rc 88" "$(run claude w2)" "rc=88 calls=2"
MAIN_OUT="Claude AI usage limit reached|1790000000"
ck "session limit mid-run (#508): rc 87"                "$(run claude s1)" "rc=87 calls=2"
MAIN_OUT="I've reached the maximum number of actions I can do without user input"
ck "goose max-turns marker: rc 86"                      "$(run goose m1)" "rc=86 calls=1"
MAIN_OUT=$OKREPORT

echo "── #633 a slot that is not isolated is refused, not fired"
# EXACTLY the state the old `cd .../_work/$SLOT || true` accepted: the slot directory exists,
# the workspace inside it does not. Two agents then met in the shared tree.
: > "$T/calls"; : > "$T/pwds"
DISPATCH_ROOT=$RT sh "$T/_dispatch/prep.sh" claude n1 demo "$RT/_dispatch/logs/p-n1.marker" \
  > /dev/null 2>&1
rm -rf "$RT/_work/n1/demo"
NL=$RT/_dispatch/logs/r-n1.log
PATH="$T/bin:$PATH" CALLS="$T/calls" PWDLOG="$T/pwds" DISPATCH_ROOT=$RT \
  sh "$T/_dispatch/run.sh" claude n1 "$BRIEF" "$NL" > "$NL" 2>&1
NRC=$?
ck "no workspace in the slot: rc 91, nothing spent"     "rc=$NRC calls=$(wc -l < "$T/calls" | tr -d ' ')" "rc=91 calls=0"
ck "...and it says so, by message"                      "$(grep -c 'NOT ISOLATED' "$NL")/$(grep -c 'prep.sh never made one' "$NL")" "1/1"
# The staging guard is part of the workspace: losing it must refuse the slot too, or the
# enforcement below would fail open the same way the cd did.
mv "$RT/_dispatch/bin/git" "$T/git.away"
: > "$T/calls"; GL=$RT/_dispatch/logs/r-n2.log
PATH="$T/bin:$PATH" CALLS="$T/calls" DISPATCH_ROOT=$RT \
  sh "$T/_dispatch/run.sh" claude i1 "$BRIEF" "$GL" > "$GL" 2>&1
GRC=$?
ck "workspace fine but staging guard gone: rc 91"       "rc=$GRC calls=$(wc -l < "$T/calls" | tr -d ' ')" "rc=91 calls=0"
ck "...named in the banner"                             "$(grep -c 'no staging guard at' "$GL")" "1"
mv "$T/git.away" "$RT/_dispatch/bin/git"

echo "── #633 the staging guard prep.sh declares"
# Asserted through the guard's own MESSAGE. An exit-status-only check would pass on any
# failure at all, including a shim that cannot find git.
g() { ( cd "$RT/_work/i1/demo" && PATH="$RT/_dispatch/bin:$T/bin:$PATH" git "$@" 2>&1 ); }
echo drift >> "$RT/_work/i1/demo/f"; echo new > "$RT/_work/i1/demo/mine"
ck "git add -A refused"          "$(g add -A          | grep -c 'DISPATCH REFUSED')" "1"
ck "git add --all refused"       "$(g add --all       | grep -c 'DISPATCH REFUSED')" "1"
ck "git add . refused"           "$(g add .           | grep -c 'DISPATCH REFUSED')" "1"
ck "git commit -a refused"       "$(g commit -a -m x  | grep -c 'DISPATCH REFUSED')" "1"
ck "git commit -am refused"      "$(g commit -am x    | grep -c 'DISPATCH REFUSED')" "1"
ck "git -C <dir> add -A refused" "$(g -C . add -A     | grep -c 'DISPATCH REFUSED')" "1"
ck "...and the refusal names the path-scoped form to use instead" \
   "$(g add -A | grep -c 'git add -- <paths>')" "1"
# Over-blocking is its own failure: a guard that stops legitimate work gets bypassed.
ck "git add -- <path> passes through"    "$(g add -- mine > /dev/null 2>&1; echo $?)" "0"
ck "...and really staged only that path" "$(g diff --cached --name-only | tr '\n' ' ')" "mine "
ck "git commit --amend is not mistaken for -a" \
   "$(g commit --dry-run --amend -m x 2>&1 | grep -c 'DISPATCH REFUSED')" "0"
ck "git status passes through"           "$(g status --porcelain | wc -l | tr -d ' ')" "2"

echo "── prep.sh"
prep() { # prep <slot> [brief] -> rc
  DISPATCH_ROOT=$T PATH="${PREP_PATH:-$PATH}" sh "$T/_dispatch/prep.sh" claude "$1" demo "$T/_dispatch/logs/p-$1.marker" ${2:+"$2"}
  echo $?
}
chmod 0600 "$BRIEF"
ck "prep rc 0 with a 0600 brief"                         "$(prep p1 "$BRIEF")" "0"
ck "(b) prep made the brief 0644"                        "$(stat -c %a "$BRIEF")" "644"
W1=$T/_work/p1/demo
ck "(#487) workspace .git is a FILE, not a directory"    "$([ -f "$W1/.git" ] && echo file || echo not-a-file)" "file"
ck "(#487) HEAD is detached"                             "$(git -C "$W1" symbolic-ref -q HEAD || echo detached)" "detached"
ck "(#487) workspace is at the source's main"            "$(git -C "$W1" rev-parse HEAD)" "$(git -C "$T/demo" rev-parse main)"
ck "(#487) objects come from the SOURCE's store"         "$(cd "$(git -C "$W1" rev-parse --git-common-dir)" && pwd -P)" "$(cd "$T/demo/.git" && pwd -P)"
ck "(#558) the workspace has NO object store to link or copy" \
   "$(find "$W1" -path '*/objects/*' -type f | wc -l | tr -d ' ')" "0"
ck "(#487) workspace git data is kilobytes, not MBs (.git + metadata < 256KB)" \
   "$([ "$(du -sk "$W1/.git" "$(git -C "$W1" rev-parse --absolute-git-dir)" | awk '{t+=$1} END {print t}')" -lt 256 ] && echo small || echo big)" "small"
ck "(#487) prep ran none of the source repo's own hooks" "$([ -e "$T/post-checkout.ran" ] && echo ran || echo none)" "none"
ck "(#487) prep declared the github remote"              "$(git -C "$W1" remote get-url github)" "https://github.com/diegonmarcos/demo.git"
ck "(#487) the SHARED config's hooksPath is untouched"   "$(git -C "$T/demo" config core.hooksPath)" "0_git/dist/hooks"
# #633: isolation needs NO branch — the slot is a DETACHED worktree — so nothing here relaxes
# the branch guard, and the suite proves the guard is still armed rather than assuming it.
ck "(#633) the branch guard still refuses an ordinary branch creation" \
   "$(git -C "$T/demo" checkout -q -b feature 2>&1 | grep -q 'branch-guard REFUSED' && echo refused || echo created)" "refused"
ck "(#633) ...and prep's workspace added no branch at all" \
   "$(git -C "$T/demo" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ')" "refs/heads/main "
# The pre-push hook, exercised through the exact push form agents are told to use.
git init -q --bare "$T/remote.git"; git -C "$T/demo" push -q "$T/remote.git" main
git -C "$W1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'MUTATION: drop the guard'
ck "(#481) MUTATION commit refused from the worktree"    "$(git -C "$W1" push -q "$T/remote.git" HEAD:main 2>/dev/null; echo $?)" "1"
git -C "$W1" reset -q --hard HEAD~1
git -C "$W1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'fix the MUTATION guard'
ck "(#487) push HEAD:main from the detached worktree lands on main" \
   "$(git -C "$W1" push -q "$T/remote.git" HEAD:main 2>/dev/null; git -C "$T/remote.git" rev-parse main)" "$(git -C "$W1" rev-parse HEAD)"
ck "re-prep of a live slot is rc 0 and keeps its commit"  "$(prep p1)/$(git -C "$W1" log -1 --format=%s)" "0/fix the MUTATION guard"
# Prune: another engine's worktree looks MISSING from here (its absolute path is in the other
# mount). It must survive. One of OUR slots whose directory is really gone must be pruned.
git -C "$T/demo" worktree add -q --detach --lock --reason 'dispatch root=/opt/data/git' "$T/elsewhere/w" main
rm -rf "$T/elsewhere"
prep p3 > /dev/null; rm -rf "$T/_work/p3"
ck "prep p4 rc 0"                                        "$(prep p4)" "0"
ck "(#487) prune kept the other engine's worktree, dropped our deleted slot" \
   "$(git -C "$T/demo" worktree list --porcelain | awk '/^worktree /{print $2}' | awk -F/ '{print $(NF-1)"/"$NF}' | sort | tr '\n' ' ')" \
   "$(printf '%s\n' "$(basename "$T")/demo" elsewhere/w p1/demo p4/demo | sort | tr '\n' ' ')"
# ...and the reverse: from the OTHER engine, OUR slot's path is the missing one. Its plain prune
# (or any agent's) must not take our live slot — that is what prep's lock is for.
mv "$T/_work/p4" "$T/_work/p4.away"; git -C "$T/demo" worktree prune; mv "$T/_work/p4.away" "$T/_work/p4"
ck "(#487) our slot survives a prune run where its path does not resolve" \
   "$(git -C "$T/_work/p4/demo" rev-parse --is-inside-work-tree 2>/dev/null || echo pruned)" "true"
# docker exec is root: the new worktree metadata in the SHARED .git must be chowned to the tree's
# owner. The suite refuses to run as root, so root is simulated: `id -u` says 0, chown records.
mkdir -p "$T/rootbin"
printf '#!/bin/sh
[ "$1" = -u ] && { echo 0; exit 0; }; exec /usr/bin/id "$@"
' > "$T/rootbin/id"
printf '#!/bin/sh
echo "$*" >> "%s"
' "$T/chown.log" > "$T/rootbin/chown"
/bin/chmod 755 "$T/rootbin/id" "$T/rootbin/chown"; : > "$T/chown.log"
PREP_PATH="$T/rootbin:$PATH" prep p5 > /dev/null
ck "(#487) as root, the shared worktree metadata is chowned to the source's owner" \
   "$(grep -c -- "-R --reference=$T/demo .* $T/demo/.git/worktrees" "$T/chown.log")" "1"
# A brief prep cannot repair (foreign owner, simulated by a chmod that fails as EPERM would):
printf '#!/bin/sh\necho "chmod: Operation not permitted" >&2; exit 1\n' > "$T/bin/chmod"; chmod 755 "$T/bin/chmod" 2>/dev/null || /bin/chmod 755 "$T/bin/chmod"
/bin/chmod 000 "$BRIEF"
ck "(b) unrepairable brief: prep aborts rc 67"           "$(PREP_PATH="$T/bin:$PATH" prep p2 "$BRIEF")" "67"
ck "(b) ...before spending a workspace on it"                "$([ -d "$T/_work/p2/demo" ] && echo cloned || echo none)" "none"
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
