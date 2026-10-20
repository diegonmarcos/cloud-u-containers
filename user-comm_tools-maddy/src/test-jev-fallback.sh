#!/bin/bash
# #882 S1 guard: Jev only ever FILES a fallback row on a confident, in-list opinion; every kind of "no
# opinion" (no sidecar, no_key, gate_closed, garbage, unconfident, folder not offered, MAIL_JEV=0) prints
# nothing, so apply-rules leaves the row in the fallback exactly as before. Runs the real jev_pick() from
# mail-sieve-subset-post-hoc.sh against a stub sidecar. Run: bash src/test-jev-fallback.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^# jev:begin/,/^# jev:end/p' "$HERE/mail-sieve-subset-post-hoc.sh")"
T="$(mktemp -d)"; trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
cat > "$T/srv.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = open(sys.argv[2]).read().encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=$((20000 + RANDOM % 20000)); python3 "$T/srv.py" "$PORT" "$T/ans" & SRV=$!
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
export JEV_SIDECAR_URL="http://127.0.0.1:$PORT" JEV_ASK_TIMEOUT=2
HDR=$'From: news@shop.example\nSubject: Your order'
CANDS=$'21 Shop\n22 News'
fail=0
check() { if [ "$2" != "$3" ]; then echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
ans() { printf '%s' "$1" > "$T/ans"; }
ans '{"ok":true,"use":"mail_fallback_folder","results":{"folder":{"type":"choice","pick":"21 Shop","p":0.93,"confident":true}}}'
check "confident in-list opinion files the row" "$(jev_pick "$HDR" "$CANDS")" "21 Shop"
ans '{"ok":true,"results":{"folder":{"type":"choice","pick":"21 Shop","p":0.5,"confident":false}}}'
check "unconfident -> no opinion" "$(jev_pick "$HDR" "$CANDS")" ""
ans '{"ok":true,"results":{"folder":{"type":"choice","pick":"99 Elsewhere","p":0.99,"confident":true}}}'
check "folder not offered -> no opinion" "$(jev_pick "$HDR" "$CANDS")" ""
ans '{"ok":false,"use":"mail_fallback_folder","reason":"no_key"}'
check "no_key -> no opinion" "$(jev_pick "$HDR" "$CANDS")" ""
ans '{"ok":false,"reason":"gate_closed"}'
check "gate_closed -> no opinion" "$(jev_pick "$HDR" "$CANDS")" ""
ans '<html>502</html>'
check "garbage -> no opinion" "$(jev_pick "$HDR" "$CANDS")" ""
ans '{"ok":true,"results":{"folder":{"type":"choice","pick":"21 Shop","p":0.93,"confident":true}}}'
check "fewer than two folders -> no call, no opinion" "$(jev_pick "$HDR" "21 Shop")" ""
check "MAIL_JEV=0 -> no opinion" "$(MAIL_JEV=0 jev_pick "$HDR" "$CANDS")" ""
check "sidecar down -> no opinion" "$(JEV_SIDECAR_URL=http://127.0.0.1:9 jev_pick "$HDR" "$CANDS")" ""
jev_pick "$HDR" "$CANDS" >/dev/null; check "jev_pick always returns 0" "$?" "0"
# the call site: Jev is asked for FALLBACK rows only
grep -q '\[ "\$target" = "\$FALLBACK_NAME" \]' "$HERE/mail-sieve-subset-post-hoc.sh" || { echo "FAIL fallback-only guard missing"; fail=1; }
[ $fail = 0 ] && echo PASS || { echo FAILED; exit 1; }
