#!/usr/bin/env bash
# test-probe-targets.sh — assert every probe target in this crate points at
# something that actually answers on oci-mail.
#
# WHY this exists as a shell test and not a Rust test: the failures this crate
# has accumulated were never logic bugs. They were probes aimed at an address,
# port or file path that the architecture had moved away from — localhost:25
# after maddy went WG-only, port 4190 after Dovecot left, `maddy queue list`
# which is not a maddy subcommand, /opt/containers/maddy/maddy.conf.tpl after
# the deploy layout gained configs/. A Rust unit test cannot catch any of those;
# only dialling the real target can. Run this after changing any probe target.
#
# EXPECTED_PORTS is read out of constants.rs rather than repeated here, so this
# tester cannot drift from the list it is checking.
#
# Usage:
#   ./test-probe-targets.sh                        live, needs an ssh client
#   ./test-probe-targets.sh --emit-batch           print the remote half only
#   PROBE_OUTPUT=/tmp/batch.txt ./test-probe-targets.sh
#                                                  assert a captured transcript

set -uo pipefail

MAIL_ALIAS="${MAIL_ALIAS:-oci-mail}"
MAIL_WG_IP="10.0.0.3"
CONSTANTS="$(dirname "$0")/src/constants.rs"
FAILS=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILS=$((FAILS + 1)); }

[ -f "$CONSTANTS" ] || { echo "✗ $CONSTANTS missing"; exit 1; }

EXPECTED_PORTS=$(sed -n 's/^pub const EXPECTED_PORTS.*&\[\(.*\)\];/\1/p' "$CONSTANTS" | tr -d ' ' | tr ',' ' ')
[ -n "$EXPECTED_PORTS" ] || { echo "✗ could not parse EXPECTED_PORTS from constants.rs"; exit 1; }
echo "EXPECTED_PORTS from constants.rs: $EXPECTED_PORTS"

# The remote half. Fed to `ssh oci-mail bash -s` as stdin rather than passed as
# an argument: these lines are full of quotes, $-expansions and docker --format
# braces, and argument-passing them through ssh means escaping the same string
# twice. stdin needs no escaping at all.
remote_batch() {
cat <<'REMOTE'
echo ===smtp25===
echo QUIT | timeout 8 nc -w8 10.0.0.3 25 2>&1 | head -1
echo ===imapCap===
echo "a001 CAPABILITY" | timeout 3 openssl s_client -connect localhost:993 -quiet 2>/dev/null | head -3
echo ===stalwartImap===
echo "a001 CAPABILITY" | timeout 3 openssl s_client -connect 10.0.0.3:2993 -quiet 2>/dev/null | head -3
echo ===stalwartQueueDepth===
docker exec maddy sh -c 'ls -1 /data/queue-stalwart 2>/dev/null | wc -l' 2>/dev/null || echo QUEUE_FAIL
echo ===allLocalPorts===
sudo ss -tlnp 2>/dev/null || ss -tlnp 2>/dev/null
echo ===hostTpl===
md5sum /opt/containers/maddy/configs/maddy.conf.tpl 2>/dev/null | awk '{print $1}'
echo ===containerTpl===
docker exec maddy md5sum /etc/maddy/maddy.conf.tpl 2>/dev/null | awk '{print $1}'
echo ===relayTarget===
docker exec maddy grep -A1 'target.smtp stalwart_relay' /data/maddy.conf 2>/dev/null | grep targets
echo ===end===
REMOTE
}

# Emit just the remote half, for callers that own the transport.
if [ "${1:-}" = "--emit-batch" ]; then
  remote_batch
  exit 0
fi

# ── Static assertions ──────────────────────────────────────────────────────
# These need no network and run before the transport is chosen, so they still
# fire on a machine with no ssh client. They cover the two probe defects found
# on 2026-09-09 that dialling a target cannot catch, because in both cases the
# target was healthy and the probe never reached it:
#
#  * The report read the bearer from AUTHELIA_BEARER_TOKEN while entrypoint.sh
#    and both callers pass BEARER_TOKEN, so every OIDC check reported "no OIDC
#    token" and asserted nothing.
#  * "webmail.* redirect" overrode the request deadline to 5s — below the
#    crate's own HTTP_TIMEOUT — and expired at 5002ms against an endpoint that
#    answers in ~1-2s, reporting a transport error as an outage.
PHASES="$(dirname "$0")/src/phases.rs"
MAIN="$(dirname "$0")/src/main.rs"
CHECKS="$(dirname "$0")/src/checks.rs"

echo
echo "0. Static: the bearer env name matches the name the pipeline sets"
# Matched on the executable line, not on a mention: the previous wording was
# satisfied by a comment naming the constant while the code still read a
# hardcoded env name one line below.
BEARER_LOOP=$(grep -c 'for var in constants::BEARER_TOKEN_ENV_VARS' "$MAIN")
BEARER_LITERAL=$(grep -c 'env::var("[^"]*BEARER' "$MAIN")
BEARER_LISTED=$(sed -n 's/^pub const BEARER_TOKEN_ENV_VARS.*&\[\(.*\)\];/\1/p' "$CONSTANTS" | grep -c '"BEARER_TOKEN"')
if [ "$BEARER_LOOP" -ge 1 ] && [ "$BEARER_LITERAL" -eq 0 ] && [ "$BEARER_LISTED" -ge 1 ]; then
  pass "main.rs loops constants::BEARER_TOKEN_ENV_VARS (no literal env::var name), and BEARER_TOKEN is listed"
else
  fail "main.rs must read the bearer by looping constants::BEARER_TOKEN_ENV_VARS, which must list BEARER_TOKEN — entrypoint.sh and both callers set that name and nothing else (loop=$BEARER_LOOP literals=$BEARER_LITERAL listed=$BEARER_LISTED)"
fi

echo
echo "0b. Static: no probe deadline tighter than the crate's HTTP_TIMEOUT"
HTTP_TIMEOUT_SECS=$(sed -n 's/^pub const HTTP_TIMEOUT.*from_secs(\([0-9]*\)).*/\1/p' "$CHECKS")
[ -n "$HTTP_TIMEOUT_SECS" ] || { echo "✗ could not parse HTTP_TIMEOUT from checks.rs"; exit 1; }
TIGHT=$(grep -oE '\.timeout\(std::time::Duration::from_secs\([0-9]+\)\)' "$PHASES" \
        | grep -oE '[0-9]+' | awk -v lim="$HTTP_TIMEOUT_SECS" '$1 < lim' | sort -un | tr '\n' ' ')
if [ -z "$TIGHT" ]; then
  pass "every per-request timeout in phases.rs is >= HTTP_TIMEOUT (${HTTP_TIMEOUT_SECS}s)"
else
  fail "phases.rs overrides the deadline to ${TIGHT}s, below HTTP_TIMEOUT ${HTTP_TIMEOUT_SECS}s — a probe that expires early reports a healthy endpoint as unreachable"
fi

# PROBE_OUTPUT lets a caller without an ssh client (the api-runner container has
# none) supply a batch transcript collected some other way — the MCP ssh tool, a
# CI step, a paste. Same assertions either way; only the transport differs.
if [ -n "${PROBE_OUTPUT:-}" ]; then
  OUT=$(cat "$PROBE_OUTPUT")
  echo "batch transcript: $PROBE_OUTPUT"
elif command -v ssh >/dev/null; then
  OUT=$(remote_batch | ssh -o BatchMode=yes -o ConnectTimeout=5 "$MAIL_ALIAS" bash -s 2>/dev/null)
  echo "batch transcript: live ssh $MAIL_ALIAS"
else
  # Static-only run. The live half is skipped, but the static assertions above
  # have already executed and their verdict is the exit code — otherwise a
  # transportless environment (the api-runner container has no ssh client)
  # would report "cannot test" for checks it just finished running.
  echo "✗ no ssh client and no PROBE_OUTPUT set — LIVE PROBES SKIPPED, static assertions above still apply"
  echo "  collect the batch with:  ./test-probe-targets.sh --emit-batch | <your ssh transport> > /tmp/batch.txt"
  echo "  then re-run with:        PROBE_OUTPUT=/tmp/batch.txt ./test-probe-targets.sh"
  [ "$FAILS" -eq 0 ] && { echo "PASS (static only) — $FAILS static failure(s)"; exit 0; }
  echo "FAIL (static only) — $FAILS static assertion(s) failed"
  exit 1
fi

[ -n "$OUT" ] || { echo "✗ SSH to $MAIL_ALIAS returned nothing"; exit 1; }

section() { awk -v s="===$1===" '$0==s{f=1;next} /^===/{f=0} f' <<<"$OUT"; }

echo
echo "1. SMTP :25 answers on the WG IP (maddy.conf binds wg0/wg-public, no loopback)"
if grep -q '220' <<<"$(section smtp25)"; then
  pass "220 banner on $MAIL_WG_IP:25"
else
  fail "no 220 banner on $MAIL_WG_IP:25 — got: $(section smtp25 | head -1)"
fi

echo
echo "2. Both stores answer IMAP — they are written by two non-atomic legs"
if grep -qE 'IMAP4|OK' <<<"$(section imapCap)"; then
  pass "maddy IMAP on localhost:993"
else
  fail "maddy IMAP silent on localhost:993"
fi
if grep -qE 'IMAP4|OK' <<<"$(section stalwartImap)"; then
  pass "stalwart IMAP on $MAIL_WG_IP:2993 (the store the user reads)"
else
  fail "stalwart IMAP silent on $MAIL_WG_IP:2993 — docker-proxy binds WG only, never loopback"
fi

echo
echo "3. Every EXPECTED_PORTS entry is really bound"
PORTS_OUT=$(section allLocalPorts)
for p in $EXPECTED_PORTS; do
  if grep -qE ":${p}[[:space:]]" <<<"$PORTS_OUT"; then
    pass "port $p bound"
  else
    fail "port $p in EXPECTED_PORTS but not bound — probe asserts a port nothing serves"
  fi
done

echo
echo "4. Stalwart relay backlog is countable (not a swallowed error)"
DEPTH=$(section stalwartQueueDepth | tr -d ' ')
if [[ "$DEPTH" =~ ^[0-9]+$ ]]; then
  pass "/data/queue-stalwart depth = $DEPTH"
else
  fail "queue depth not numeric ('$DEPTH') — the check would degrade to a false green"
fi

echo
echo "5. Config-drift chain hashes the path the deploy pipeline actually ships"
HOST_TPL=$(section hostTpl | tr -d ' ')
CONTAINER_TPL=$(section containerTpl | tr -d ' ')
if [ -n "$HOST_TPL" ] && [ "$HOST_TPL" = "$CONTAINER_TPL" ]; then
  pass "configs/maddy.conf.tpl == container /etc/maddy/maddy.conf.tpl ($HOST_TPL)"
else
  fail "host '$HOST_TPL' != container '$CONTAINER_TPL' — either real drift, or the wrong host path"
fi

echo
echo "6. stalwart_relay still targets a port EXPECTED_PORTS covers"
RELAY=$(section relayTarget)
RELAY_PORT=$(grep -oE '[0-9]+$' <<<"$RELAY" | head -1)
if [ -n "$RELAY_PORT" ] && grep -qw "$RELAY_PORT" <<<"$EXPECTED_PORTS"; then
  pass "maddy.conf relays to :$RELAY_PORT and EXPECTED_PORTS covers it"
else
  fail "maddy.conf relay target '$RELAY' not covered by EXPECTED_PORTS — the dual-write hop would go unwatched"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "PASS — every probe target answers"
  exit 0
fi
echo "FAIL — $FAILS probe target(s) aimed at nothing"
exit 1
