#!/usr/bin/env python3
"""Tests for the email one-time-code provider (#1118): unit (issue/verify/expiry/attempts/rate limit/allowlist,
delivery fallback) and an end-to-end flow over a real broker HTTP server with a fake mailer.
Run: python3 -I test/test-broker-email.py   (from infra-sec_auth-broker/src; stdlib only)"""
import json, os, re, sys, threading, time, urllib.error, urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "code"))
import main as broker  # noqa: E402

BJ = json.load(open(os.path.join(HERE, "..", "..", "build.json")))
OWNER = BJ["auth_broker"]["allowed_emails"][0]
ENV = {"AUTH_BROKER_COOKIE_SECRET": "z" * 40}
PASS = 0


def need(cond, msg):
    global PASS
    if not cond:
        print("FAIL:", msg); sys.exit(1)
    PASS += 1; print("ok:", msg)


class Mailer:
    def __init__(self): self.sent = []
    def __call__(self, to, code): self.sent.append((to, code))


def mk(env=ENV, **eo):
    cfg = json.loads(json.dumps(BJ))
    cfg["auth_broker"]["email_otp"].update(eo)
    b = broker.Broker(cfg, "email", env)
    b.mailer = Mailer()
    return b


# ---- unit ---------------------------------------------------------------------------------------
b = mk()
st, d = b.otp_request(OWNER, "1.1.1.1")
to, code = b.mailer.sent[-1]
need(st == 200 and to == OWNER and re.fullmatch(r"\d{6}", code), "issue: allowlisted address gets a 6-digit code")
need(code not in json.dumps(b.otp) and all(code not in str(v) for v in b.otp.values()), "issue: the code itself is not stored, only a hash")
need(b.otp_verify(d["sid"], "000000" if code != "000000" else "111111")[1]["status"] == "wrong", "verify: wrong code refused")
st, r, ck = b.otp_verify(d["sid"], code)
need(r["status"] == "ok" and ck and ck.startswith("_diego_sso=") and "Domain=.diegonmarcos.com" in ck and "HttpOnly" in ck, "verify: right code issues the shared session cookie")
need(b.check_cookie(ck.split(";")[0].split("=", 1)[1]) == OWNER, "verify: cookie validates on the broker's own check (same format as other providers)")
need(b.otp_verify(d["sid"], code)[1]["status"] == "expired", "single use: the spent code is refused")

st, d = b.otp_request(OWNER, "1.1.1.2"); code = b.mailer.sent[-1][1]
for i in range(4):
    b.otp_verify(d["sid"], "x%05d" % i)
need(b.otp_verify(d["sid"], "123456" if code != "123456" else "654321")[1]["status"] == "locked", "attempts: the 5th wrong code locks the flow")
need(b.otp_verify(d["sid"], code)[1]["status"] == "expired", "attempts: after the lock even the right code is refused")

st, d = b.otp_request(OWNER, "1.1.1.3"); code = b.mailer.sent[-1][1]
b.otp[d["sid"]]["exp"] = time.time() - 1
need(b.otp_verify(d["sid"], code)[1]["status"] == "expired", "expiry: a code past 10 minutes is refused")
need(b.otp_ttl == 600 and b.otp_attempts == 5 and b.otp_len == 6, "config: 10 minutes, 5 attempts, 6 digits")

b = mk()
st1, d1 = b.otp_request("mallory@example.com", "2.2.2.2")
st2, d2 = b.otp_request(OWNER, "2.2.2.3")
need(st1 == st2 == 200 and set(d1) == set(d2) and d1["status"] == d2["status"], "allowlist: unlisted and listed addresses get the same generic response")
need(len(b.mailer.sent) == 1 and b.mailer.sent[0][0] == OWNER, "allowlist: no mail goes to an unlisted address")
for a in ("ME@diegonmarcos.com.evil.example", "x@diegonmarcos.com", "me@diegonmarcos.com\nBcc: m@e.x", ""):
    b.otp_request(a, "2.2.2.4")
need(len(b.mailer.sent) == 1, "allowlist: lookalikes, other users, header injection and empty get no mail")
need(b.otp_verify(d1["sid"], "123456")[1]["status"] != "ok", "allowlist: an unlisted request can never verify")

b = mk(send_per_address=3)
for i in range(5):
    st, d = b.otp_request(OWNER, "3.3.3.%d" % i)
need(len(b.mailer.sent) == 3 and st == 200 and "sid" in d, "rate limit: per-address cap holds and the answer stays generic")
b = mk(send_per_ip=4)
sts = [b.otp_request("mallory@example.com", "4.4.4.4")[0] for _ in range(6)]
need(sts == [200] * 4 + [429] * 2, "rate limit: per-IP cap answers 429")

# delivery: Stalwart first, Resend as fallback, neither -> error (never a leaked code)
calls = []
b = mk(env={**ENV, "AUTH_BROKER_SMTP_USER": "u", "AUTH_BROKER_SMTP_PASSWORD": "p", "AUTH_BROKER_RESEND_API_KEY": "k"})
b.send_smtp = lambda *a: calls.append("smtp")
b.send_resend = lambda *a: calls.append("resend")
need(b.deliver(OWNER, "123456") == "stalwart" and calls == ["smtp"], "delivery: Stalwart is tried first")
def boom(*a): raise OSError("down")
b.send_smtp = boom
need(b.deliver(OWNER, "123456") == "resend" and calls == ["smtp", "resend"], "delivery: Resend is the fallback when Stalwart fails")
b.send_resend = boom
try:
    b.deliver(OWNER, "123456"); need(False, "delivery: both paths down must raise")
except RuntimeError as e:
    need("123456" not in str(e), "delivery: both paths down -> error without the code")
b = mk()
try:
    b.deliver(OWNER, "123456"); need(False, "delivery: no secrets must raise")
except RuntimeError:
    need(True, "delivery: no mail path configured -> error (request still answers generically)")
dis = json.loads(json.dumps(BJ))
for p in dis["auth_broker"]["providers"]:
    if p["id"] == "email": p["enabled"] = False
bd = broker.Broker(dis, "email", ENV)
need(bd.otp_request(OWNER, "5.5.5.5")[0] == 404 and bd.otp_verify("x", "1")[0] == 404, "flag: disabled provider refuses requests")

# ---- integration: real HTTP server, fake mailer ---------------------------------------------------
b = mk()
srv = ThreadingHTTPServer(("127.0.0.1", 0), broker.make_handler(b))
threading.Thread(target=srv.serve_forever, daemon=True).start()
URL = "http://127.0.0.1:%d" % srv.server_address[1]
P = "/oauth2/email"


def call(path, body=None, headers=None):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Requested-With": "sso", "Content-Type": "application/json", **(headers or {})})
    try:
        r = urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        r = e
    return r.status, r.read(), r.headers


st, body, _ = call(P + "/health")
need(st == 200 and json.loads(body)["enabled"] is True, "e2e: health enabled")
st, body, _ = call(P + "/start")
need(st == 200 and b"Email code" in body and b"/request" in body, "e2e: start serves the address form")
need(call(P + "/auth")[0] == 401, "e2e: no session before sign-in")
st, body, _ = call(P + "/request", {"email": "mallory@example.com"})
need(st == 200 and not b.mailer.sent, "e2e: unlisted address answered 200, nothing mailed")
st, body, _ = call(P + "/request", {"email": OWNER})
sid = json.loads(body)["sid"]
need(st == 200 and len(b.mailer.sent) == 1, "e2e: owner request mails one code through the fake mailer")
code = b.mailer.sent[0][1]
st, body, h = call(P + "/verify", {"sid": sid, "code": "abcdef"})
need(json.loads(body)["status"] == "wrong" and not h.get("Set-Cookie"), "e2e: wrong code, no cookie")
st, body, h = call(P + "/verify", {"sid": sid, "code": code, "rd": "https://auth.diegonmarcos.com/x"})
ck = h.get("Set-Cookie", "")
need(json.loads(body)["status"] == "ok" and json.loads(body)["rd"] == "https://auth.diegonmarcos.com/x" and ck.startswith("_diego_sso="), "e2e: right code -> cookie and safe rd")
st, _, _ = call(P + "/auth", headers={"Cookie": ck.split(";")[0]})
need(st == 202, "e2e: the issued cookie passes the gate's /auth check")
other = broker.Broker(json.loads(json.dumps(BJ)), "google", {**ENV, "AUTH_BROKER_GOOGLE_CLIENT_ID": "id", "AUTH_BROKER_GOOGLE_CLIENT_SECRET": "s"})
need(other.session_email(ck.split(";")[0]) == OWNER, "e2e: another provider instance (same secret) accepts the same cookie")
st, body, h = call(P + "/verify", {"sid": sid, "code": code})
need(json.loads(body)["status"] == "expired" and not h.get("Set-Cookie"), "e2e: replay of the code refused")
need(call(P + "/request", {"email": OWNER}, {"X-Requested-With": "x"})[0] == 403, "e2e: cross-site POST refused")
st, body, h = call(P + "/request", {"email": OWNER}); sid = json.loads(body)["sid"]
st, body, h = call(P + "/verify", {"sid": sid, "code": code, "rd": "https://evil.example/"})
need(json.loads(body)["status"] in ("wrong", "locked"), "e2e: a fresh flow does not accept the old code")
print("PASS: %d checks" % PASS)
