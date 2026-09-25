#!/bin/sh
# Dispatch runner — run one agent task and make a turn-capped run impossible to
# mistake for a finished one.
#
# Both engines end an exhausted run the same quiet way: they print a note and
# exit 0. hermes prints "Iteration budget exhausted (N/M)" or "Reached maximum
# iterations (M)"; goose prints "I've reached the maximum number of actions I can
# do without user input". To anything reading the log tail — and to the operator
# skimming it — a partial answer with rc=0 looks exactly like a delivered one.
# Wave-3 slot 444 burned 1 hour 57 minutes that way and reported nothing.
#
# So the run's own log is scanned afterwards, a hit is shouted in a banner, and
# the exit code becomes 86. Nothing about the engines changes; the loudness lives
# here, where every dispatched task already passes through.
#
# claude (#508) fails open a THIRD way, and it is the loudest one: on a session limit
# `claude -p` writes ONE ~53-byte line and exits 0. So for claude a SMALL log means broken and
# an EMPTY one means healthy — `-p` prints only the final text, and an agent that worked and
# answered tersely prints almost nothing. A size-only poll reads that exactly backwards, which
# is why the test below is size AND shape, never size alone.
#
# #510: this file is VERSIONED at cloud-u-containers/_dispatch/run.sh. The copy in
# ~/git/_dispatch/ is a one-line shim that execs this one, so a fix lands with `git pull` and
# the tester (test-dispatch-fail-opens.sh beside it) runs against the file that actually fires.
# Before #510 the only copy was unversioned, untested, and hand-edited beside `.bak512` backups.
#
# WHY a top-level _dispatch/ and not _shared/ or a service dir: cloud-infra's Ship deploys
# <dir>/src/** and <dir>/build.json, and fans ANY _shared/** change out to every engine
# consumer. A runner edit must never recreate the containers the agents are running in. The
# tester is therefore registered in cloud-infra's 9_others/test-registry.json (with `path`),
# whose CI checks this repo out as a_solutions/ — not in a service build.json.
#
# Exit codes — every one of them means "this run did NOT do its work; do not read it as done":
#   86 MAX_TURNS_EXHAUSTED  87 SESSION_LIMIT  88 AWAITED_WAKEUP
#   89 BRIEF_UNREADABLE     90 AUTH_PREFLIGHT_FAILED
#
# Usage: run.sh <hermes|goose|claude> <slot> <prompt-file> <log-file> [model]
# The caller must redirect this script's own output into <log-file>:
#   docker exec -d C sh -c "run.sh hermes 444 /…/hermes-444.md /…/hermes-444.log \
#                             > /…/hermes-444.log 2>&1"
#
# [model] applies to the claude engine only and DEFAULTS TO sonnet, so every existing
# four-argument call site keeps its current behaviour untouched. It exists because Diego
# names the engine per ticket ("deploy a fable agent", #512) and the alternative — a second
# copy of this script with one word changed — is the per-ticket-copy defect prep.sh's own
# header was written to kill. The model is an ARGUMENT, not a new file.
set -u

ENGINE=$1
SLOT=$2
PROMPT=$3
LOG=$4
# #510 fix: LOG (and everything derived from it — .raw, .preflight, .outer) must survive the
# later `cd _work/$SLOT`. A relative logs/ path resolved post-cd lands in the worktree, the
# preflight redirect fails (rc=2), and the auth guard misreads its own broken pen as a dead
# login — four slots refused on 2026-09-25 with auth fully alive. Absolutize at entry.
case "$LOG" in /*) ;; *) LOG=$PWD/$LOG ;; esac
mkdir -p "$(dirname "$LOG")"
MODEL=${5:-sonnet}

echo "=== $ENGINE $SLOT START $(date -u +%FT%TZ)"

# #510 (b): the engine cannot read its brief. 2026-09-24 the briefs were docker-cp'd in as uid
# 1001 mode 0600 while every agent runs as 10001: each agent read "Permission denied", said so
# in a ~1.5KB log, and exited rc=0. Nothing downstream can tell that from a terse success, so
# test the precondition HERE, as the uid the engine will run as, before anything is spent.
# prep.sh repairs ownership when it can (it is the one declaration for workspace scaffolding);
# this is the backstop for when it could not, or was never given the brief.
if [ ! -r "$PROMPT" ]; then
  echo
  echo "################################################################"
  echo "##  BRIEF UNREADABLE — $ENGINE $SLOT NEVER RAN"
  echo "##  $(ls -ln "$PROMPT" 2>&1)"
  echo "##  runner uid=$(id -u). Fix ownership (prep.sh <..> <brief> as root)"
  echo "##  and re-fire. No engine was started."
  echo "################################################################"
  echo "=== $ENGINE $SLOT END rc=89 BRIEF_UNREADABLE $(date -u +%FT%TZ)"
  exit 89
fi

# No pipe into tee: this script's stdout IS the log, and a pipeline would hand
# back tee's exit status instead of the engine's under a shell with no pipefail.
case "$ENGINE" in
  hermes)
    /opt/hermes/bin/hermes --yolo --in /opt/data/git \
      -z "Read $PROMPT in full and carry out exactly what it specifies. That file is your complete instruction set." 2>&1
    RC=$?
    ;;
  goose)
    goose run --no-session -i "$PROMPT" 2>&1
    RC=$?
    ;;
  claude)
    # Capture the ENGINE's own output apart from this script's banners, so the size test below
    # measures claude and not the decoration around it. Then replay it into the log unchanged.
    # NOT mktemp. #442's /tmp reaper deleted this file out from under slot 496 mid-run: the fd
    # stayed valid so claude kept writing into an UNLINKED inode, then `cat "$OUT"` found
    # nothing and 18 minutes of output was unrecoverable. rc was still 0, so the slot read as a
    # terse success. The capture file must live beside the log, which nothing reaps.
    OUT=$(dirname "$LOG")/dispatch-$SLOT.raw
    : > "$OUT"
    # Recorded because a slot's model is otherwise unrecoverable after the fact, and "which
    # engine actually ran this?" is a question I have had to answer from log shape alone.
    echo "--- claude model=$MODEL effort=high"
    cd /home/appuser/git/_work/"$SLOT" 2>/dev/null || true
    # #510 (a): PRE-FLIGHT the credential before spending the slot. 2026-09-24 the OAuth login
    # had expired and seven agents each died in 9 seconds with rc=1 and a ~190-byte log; it was
    # seen only because Diego read the logs by hand. One tiny haiku turn with no MCP servers
    # (measured 5s, prints "OK") proves the SAME credential the real run will use. Anything
    # else — non-zero rc, or no OK (which covers the rc=0 session-limit line) — refuses to fire,
    # loudly, with the probe's own words in the banner ("Failed to authenticate" shows up there).
    PF=$(dirname "$LOG")/dispatch-$SLOT.preflight
    printf '%s' "Reply with the single word OK." \
      | claude -p --model haiku --max-turns 1 --strict-mcp-config > "$PF" 2>&1
    PRC=$?
    if [ "$PRC" -ne 0 ] || ! grep -qw OK "$PF"; then
      echo
      echo "################################################################"
      echo "##  AUTH PRE-FLIGHT FAILED — claude $SLOT NOT FIRED (probe rc=$PRC)"
      echo "##  Probe said: $(head -c 300 "$PF" | tr '\n' ' ')"
      echo "##  Every slot fired now would die the same way. Re-login"
      echo "##  (my-ai_claude-api /auth/login) or wait for the reset, re-fire."
      echo "################################################################"
      echo "=== $ENGINE $SLOT END rc=90 AUTH_PREFLIGHT_FAILED $(date -u +%FT%TZ)"
      exit 90
    fi
    # The prompt goes on STDIN, not as a positional argument. `--add-dir` is VARIADIC, so a
    # trailing positional is parsed as one more directory and claude then dies with
    # "Input must be provided either through stdin or as a prompt argument" — measured on the
    # first #508 smoke test (slot 497, rc=1 in 2 seconds). stdin has no such ambiguity.
    printf '%s' "Read $PROMPT in full and carry out exactly what it specifies. That file is your complete instruction set." \
      | claude -p --model "$MODEL" --effort high --permission-mode bypassPermissions \
          --add-dir /home/appuser/git \
      > "$OUT" 2>&1
    RC=$?
    cat "$OUT"
    SZ=$(wc -c < "$OUT")
    if [ "$SZ" -lt 400 ] && grep -qiE 'limit reached|usage limit|session limit' "$OUT"; then
      echo
      echo "################################################################"
      echo "##  SESSION LIMIT — claude $SLOT NEVER RAN (rc=$RC, ${SZ} bytes)"
      echo "##  Nothing above is an answer. Re-fire this slot after the reset."
      echo "################################################################"
      echo "=== $ENGINE $SLOT END rc=87 SESSION_LIMIT $(date -u +%FT%TZ)"
      exit 87
    fi
    # #510: a FOURTH fail-open, and the quietest yet. Slot 498's ENTIRE run was 94 bytes:
    #   "I'll pause here and wait for the CI polling task to complete or the scheduled wakeup
    #    to fire."
    # `claude -p` is ONE-SHOT. There is no next turn, no wakeup, no background task that keeps
    # running. The agent committed, pushed, then ended its turn expecting to be re-invoked — and
    # exited rc=0 having never watched the CI it had just turned RED.
    #
    # The rc=87 guard above cannot catch this: it requires a "limit" string and this output has
    # none. Size cannot catch it either — for claude an EMPTY log is HEALTHY (see the header),
    # so a size threshold reads exactly backwards. So match the SHAPE: the run's LAST WORDS are
    # a promise to continue later. A run that actually finished ends with its report.
    #
    # Both greps must hit, which makes the test order-independent ("wait for the wakeup" and
    # "the wakeup will fire, so I'll pause") without matching a report that merely says "wait".
    # WIDENED after slot 500 walked straight through the first version of this guard. Its whole
    # 175-byte run was:
    #   "I'll wait for the background `gh run watch` task to notify me when the CI run finishes."
    # The literal alternate `background task` did not match, because the qualifier and its noun
    # are separated by the command name. Twenty-one minutes, rc=0, nothing done. So the qualifier
    # and the noun are matched with a gap between them, and "notify me" — the other half of the
    # same false belief, that something will call back — is matched in its own right.
    TAIL=$(tail -c 400 "$OUT" 2>/dev/null | tr '\n' ' ')
    #
    # WIDENED AGAIN after #562's first run walked through this guard too. It ended:
    #   "CI is still running on 56f57e334. The poller will wake me ..."
    # No "pause"/"wait" and no "wakeup"/"polling" — the promise is "wakes me" and the mechanism
    # is a "poller". Same false belief, third spelling. "wakes? me" and "poller" now count on their
    # own side of the pair; a report that merely mentions a poller still needs a promise beside it.
    if echo "$TAIL" | grep -qiE '(pause|wait|stand(s|ing)? by|check back|will continue|wakes? me)' \
       && echo "$TAIL" | grep -qiE 'wakeup|wake-up|wakes? me|poller|re-invok|next turn|resumed later|notif(y|ies) me|(background|polling|scheduled|async)[^.]{0,40}(task|job|run|watch)'; then
      echo
      echo "################################################################"
      echo "##  ENDED AWAITING A WAKEUP THAT NEVER FIRES — claude $SLOT (rc=$RC, ${SZ} bytes)"
      echo "##  \`claude -p\` is one-shot: there is no next turn. This agent"
      echo "##  stopped mid-task expecting to be resumed. Its work is NOT"
      echo "##  finished and its CI was NEVER watched. Re-fire this slot."
      echo "##  Last words: $(echo "$TAIL" | tail -c 160)"
      echo "################################################################"
      echo "=== $ENGINE $SLOT END rc=88 AWAITED_WAKEUP $(date -u +%FT%TZ)"
      exit 88
    fi
    # $OUT is deliberately KEPT. It is the engine's own output with none of this script's
    # banners around it, and it is the only copy that survives if the outer log is truncated.
    ;;
  *)
    echo "unknown engine: $ENGINE" >&2
    exit 64
    ;;
esac

# #455: the caller is supposed to redirect our stdout INTO $LOG, but every fire script
# passes .log as $4 while redirecting to .outer — so this grep read a file nothing ever
# created, 2>/dev/null ate the error, and rc was silently 0 on a turn-exhausted run.
# Scan the file fd 1 REALLY points at. MUST be /proc/$$/fd/1, never /proc/self: inside a
# command substitution `self` is the SUBSHELL, whose fd 1 is the substitution pipe, so the
# lookup silently returns a pipe: path and falls back to the broken $LOG. Proven 2026-09-18.
SCAN=$(readlink /proc/$$/fd/1 2>/dev/null)
[ -f "$SCAN" ] || SCAN=$LOG
MARKERS='Iteration budget exhausted|Reached maximum iterations|reached the maximum number of actions'
if grep -qiE "$MARKERS" "$SCAN" 2>/dev/null; then
  echo
  echo "################################################################"
  echo "##  MAX TURNS EXHAUSTED — $ENGINE $SLOT DID NOT FINISH"
  echo "##  The answer above is PARTIAL. Do not read it as delivered."
  echo "##  Raise the cap (hermes: agent.max_turns in config.yaml,"
  echo "##  goose: GOOSE_MAX_TURNS) or split the task, then re-run."
  echo "################################################################"
  grep -ihE "$MARKERS" "$LOG" | tail -3
  echo "=== $ENGINE $SLOT END rc=86 MAX_TURNS_EXHAUSTED $(date -u +%FT%TZ)"
  exit 86
fi

echo "=== $ENGINE $SLOT END rc=$RC $(date -u +%FT%TZ)"
exit "$RC"
