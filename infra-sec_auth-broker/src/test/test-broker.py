#!/usr/bin/env python3
"""End-to-end test of the device-flow broker (#1066) against stub GitHub and Google providers.
Real broker HTTP servers, real HTTP to the stubs; nothing mocked inside the broker.
Run: python3 -I test/test-broker.py   (from infra-sec_auth-broker/src; stdlib only)"""
import copy, json, os, sys, threading, time, urllib.parse, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "code"))
import main as broker  # noqa: E402

BJ = json.load(open(os.path.join(HERE, "..", "..", "build.json")))
SECRET = "x" * 40
PASS = 0


def ok(msg):
    global PASS
    PASS += 1
    print("ok:", msg)


def need(cond, msg):
    if not cond:
        print("FAIL:", msg)
        sys.exit(1)
    ok(msg)


# ---- stub providers ---------------------------------------------------------------------------
class Stub:
    token_reply = {"error": "authorization_pending"}      # what the token endpoint answers next
    user = {}
    seen = []

STUB = Stub()


class SH(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, d):
        b = json.dumps(d).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        STUB.seen.append((self.path, {k: v[0] for k, v in form.items()}))
        if self.path.endswith("/device"):
            key = "verification_uri" if self.path.startswith("/gh") else "verification_url"
            return self.reply(200, {"device_code": "DEV123", "user_code": "ABCD-1234", key: "https://prov.example/device",
                                    "expires_in": 900, "interval": 1})
        r = STUB.token_reply
        return self.reply(400 if r.get("error") and self.path.startswith("/go") else 200, r)

    def do_GET(self):
        STUB.seen.append((self.path, {"auth": self.headers.get("Authorization")}))
        if self.headers.get("Authorization") != "Bearer TOK":
            return self.reply(401, {})
        return self.reply(200, STUB.user)


def serve(handler, port):
    s = ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s


SP, GP, GHP = 19621, 19622, 19623
serve(SH, SP)


def mkcfg(github_on=True, google_on=True):
    c = copy.deepcopy(BJ)
    for p in c["auth_broker"]["providers"]:
        base = "http://127.0.0.1:%d" % SP
        if p["id"] == "github":
            p.update(enabled=github_on, device_url=base + "/gh/device", token_url=base + "/gh/token", user_url=base + "/gh/user")
        else:
            p.update(enabled=google_on, auth_url="https://accounts.example/auth", token_url=base + "/go/token", userinfo_url=base + "/go/userinfo")
    return c


ENV = {"AUTH_BROKER_COOKIE_SECRET": SECRET, "AUTH_BROKER_GOOGLE_CLIENT_ID": "gid", "AUTH_BROKER_GOOGLE_CLIENT_SECRET": "gsec"}


def start(cfg, pid, port):
    b = broker.Broker(cfg, pid, ENV)
    s = ThreadingHTTPServer(("127.0.0.1", port), broker.make_handler(b))
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return b, "http://127.0.0.1:%d" % port


def http(url, method="GET", body=None, headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=json.dumps(body).encode() if body is not None else None)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


XHR = {"X-Requested-With": "sso", "Content-Type": "application/json"}


def post(base, prefix, op, body=None, headers=XHR):
    st, b, h = http(base + prefix + op, "POST", body or {}, headers)
    return st, (json.loads(b) if b else {}), h


def cookie_of(h):
    c = h.get("Set-Cookie") or ""
    return c.split(";")[0] if c else None


gh_b, GH = start(mkcfg(), "github", GHP)
go_b, GO = start(mkcfg(), "google", GP)
G, O = "/oauth2/github", "/oauth2/google"
OWNER_GH = {"login": "diegonmarcos", "id": 100614489}


def login(base, b, prefix, rd="/", user=None, token=None):
    STUB.user = user
    STUB.token_reply = {"error": "authorization_pending"}
    st, d, _ = post(base, prefix, "/device")
    assert st == 200, (st, d)
    sid = d["sid"]
    b.flows[sid]["next"] = 0
    st, r, h = post(base, prefix, "/poll", {"sid": sid, "rd": rd})
    assert r["status"] == "pending", r
    STUB.token_reply = token or {"access_token": "TOK", "token_type": "bearer"}
    b.flows[sid]["next"] = 0
    st, r, h = post(base, prefix, "/poll", {"sid": sid, "rd": rd})
    return sid, st, r, h


# ---- GitHub -----------------------------------------------------------------------------------
STUB.seen.clear()
st, d, _ = post(GH, G, "/device")
need(st == 200 and d["user_code"] == "ABCD-1234" and d["verification_uri"] == "https://prov.example/device" and "device_code" not in d,
     "github: device code issued (user code + link), device_code never leaves the broker")
need(STUB.seen[0][1]["client_id"] == "178c6fc778ccc68e1d6a", "github: the public gh CLI client id is what is sent, no secret")
need("client_secret" not in STUB.seen[0][1], "github: no client secret in the request")
need(post(GH, G, "/poll", {"sid": d["sid"]})[1]["status"] == "pending", "github: poll before the interval answers pending without hitting the provider")

sid, st, r, h = login(GH, gh_b, G, rd="https://suite.diegonmarcos.com/x", user=OWNER_GH)
c = cookie_of(h)
need(r == {"status": "ok", "rd": "https://suite.diegonmarcos.com/x"} and c and c.startswith("_diego_sso=v1."), "github: owner approves -> status ok and a session cookie")
sc = h["Set-Cookie"]
need(all(x in sc for x in ("Domain=.diegonmarcos.com", "Secure", "HttpOnly", "SameSite=Lax", "Max-Age=43200")), "session cookie is Domain=.diegonmarcos.com, Secure, HttpOnly, SameSite=Lax, 12h")
st, _, hh = http(GH + G + "/auth", headers={"Cookie": c})
need(st == 202 and hh["X-Auth-Request-Email"] == "me@diegonmarcos.com", "owner session passes /auth (202 + identity header)")
st, _, hh = http(GO + O + "/auth", headers={"Cookie": "a=b; " + c})
need(st == 202, "the same session is accepted by the Google instance (shared cookie secret)")
need(http(GH + G + "/auth")[0] == 401, "no cookie -> 401")
need(http(GH + G + "/auth", headers={"Cookie": c[:-3] + "AAA"})[0] == 401, "tampered signature -> 401")
need(http(GH + G + "/auth", headers={"Cookie": "_diego_sso=v1.e30.x"})[0] == 401, "garbage cookie -> 401")
import base64, hashlib, hmac
body = broker.b64e(json.dumps({"sub": "me@diegonmarcos.com", "p": "github", "iat": 1, "exp": int(time.time()) - 5}).encode())
expired = "_diego_sso=v1.%s.%s" % (body, gh_b.sign("v1." + body))
need(http(GH + G + "/auth", headers={"Cookie": expired})[0] == 401, "expired (correctly signed) cookie -> 401")
need(post(GH, G, "/poll", {"sid": sid})[0] == 404, "a spent flow cannot be polled again (device code is one use)")

for who, why in [({"login": "mallory", "id": 1}, "non-owner account"),
                 ({"login": "diegonmarcos", "id": 999}, "owner login with a different account id"),
                 ({"login": "someone", "id": 100614489}, "owner id with a different login")]:
    sid, st, r, h = login(GH, gh_b, G, user=who)
    need(r["status"] == "forbidden" and not h.get("Set-Cookie"), "github: %s rejected, no cookie" % why)
sid, st, r, h = login(GH, gh_b, G, user=OWNER_GH, token={"error": "access_denied"})
need(r["status"] == "denied" and not h.get("Set-Cookie"), "github: user denies on the provider -> denied")
sid, st, r, h = login(GH, gh_b, G, user=OWNER_GH, token={"error": "expired_token"})
need(r["status"] == "expired", "github: provider says the code expired -> expired")
STUB.token_reply = {"error": "slow_down"}; STUB.user = OWNER_GH
_, d, _ = post(GH, G, "/device"); gh_b.flows[d["sid"]]["next"] = 0
need(post(GH, G, "/poll", {"sid": d["sid"]})[1]["status"] == "pending" and gh_b.flows[d["sid"]]["iv"] == 6, "github: slow_down widens the poll interval")

# ---- request hygiene --------------------------------------------------------------------------
need(post(GH, G, "/device", headers={"Content-Type": "application/json"})[0] == 403, "POST without the X-Requested-With header is refused")
need(post(GH, G, "/device", headers={**XHR, "Origin": "https://evil.example"})[0] == 403, "POST with a foreign Origin is refused")
sid, st, r, h = login(GH, gh_b, G, rd="https://evil.example/", user=OWNER_GH)
need(r["rd"] == "/", "open redirect: foreign https rd is replaced by /")
for bad in ("//evil.example", "https://diegonmarcos.com.evil.example/", "http://suite.diegonmarcos.com/", "javascript:alert(1)", "/\\evil"):
    need(gh_b.safe_rd(bad) == "/", "rd refused: %s" % bad)
need(gh_b.safe_rd("/a/b?c=d") == "/a/b?c=d" and gh_b.safe_rd("https://auth.diegonmarcos.com/p") == "https://auth.diegonmarcos.com/p", "rd accepted: relative path and *.diegonmarcos.com over https")
st, page, _ = http(GH + G + "/start")
need(st == 200 and b"Sign in with GitHub" in page and b"/oauth2/github" in page, "start page served")
need(json.loads(http(GH + G + "/health")[1]) == {"enabled": True, "provider": "github"}, "health reports enabled")
n0 = len(STUB.seen); ip = {"X-Real-IP": "9.9.9.9"}
codes = [post(GH, G, "/device", headers={**XHR, **ip})[0] for _ in range(12)]
need(codes.count(200) == 10 and codes[-1] == 429, "device-code requests are rate limited per client IP (10 per window)")

# ---- Google (web authorization-code flow, PKCE S256 + state) ----------------------------------
import hashlib
AUTH_H = "auth.diegonmarcos.com"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


OPENER = urllib.request.build_opener(NoRedirect)


def raw(url, headers=None):
    try:
        r = OPENER.open(urllib.request.Request(url, headers=headers or {}), timeout=5)
        return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


def g_start(rd="/", host=AUTH_H):
    st, _, h = raw(GO + O + "/start?rd=" + urllib.parse.quote(rd), {"Host": host})
    if st != 302:
        return st, None, None, None
    loc = urllib.parse.urlsplit(h["Location"]); q = {k: v[0] for k, v in urllib.parse.parse_qs(loc.query).items()}
    return st, loc, q, h["Set-Cookie"].split(";")[0]


def g_callback(state, cookie, code="CODE1", user=None, token=None, error=None):
    STUB.user = user or {}
    STUB.token_reply = token or {"access_token": "TOK"}
    qs = {"state": state}
    if error: qs["error"] = error
    else: qs["code"] = code
    return raw(GO + O + "/callback?" + urllib.parse.urlencode(qs), {"Host": AUTH_H, **({"Cookie": cookie} if cookie else {})})


STUB.seen.clear()
st, loc, q, ck = g_start("https://suite.diegonmarcos.com/x")
need(st == 302 and loc.netloc == "accounts.example" and q["client_id"] == "gid" and q["response_type"] == "code" and q["scope"] == "openid email",
     "google: /start redirects to the provider authorization endpoint (code flow, identity-only scope)")
need(q["code_challenge_method"] == "S256" and len(q["code_challenge"]) == 43 and q["state"] and q["redirect_uri"] == "https://auth.diegonmarcos.com/oauth2/google/callback",
     "google: PKCE S256 challenge, state and the registered redirect URI are sent")
need(ck.startswith("_sso_state="), "google: a browser-binding state cookie is set")
OWNER_G = {"email": "me@diegonmarcos.com", "email_verified": True}
st, body, h = g_callback(q["state"], ck, user=OWNER_G)
form = [p for p in STUB.seen if p[0] == "/go/token"][-1][1]
need(st == 302 and h["Location"] == "https://suite.diegonmarcos.com/x" and "_diego_sso=v1." in "".join(h.get_all("Set-Cookie")), "google: owner callback -> session cookie and redirect to rd")
ver = form["code_verifier"]
need(b64e_ok := broker.b64e(hashlib.sha256(ver.encode()).digest()) == q["code_challenge"], "google: the code exchange carries the verifier matching the S256 challenge")
need(form["client_secret"] == "gsec" and form["redirect_uri"] == q["redirect_uri"] and form["grant_type"] == "authorization_code", "google: client secret and redirect URI sent to the token endpoint")
c2 = [c.split(";")[0] for c in h.get_all("Set-Cookie") if c.startswith("_diego_sso=")][0]
need(http(GH + G + "/auth", headers={"Cookie": c2})[0] == 202, "a Google session is accepted by the GitHub instance")
need(g_callback(q["state"], ck, user=OWNER_G)[0] == 400, "google: state is single use (replay refused)")
st, _, q, ck = g_start()
need(g_callback(q["state"], None, user=OWNER_G)[0] == 400, "google: callback without the binding cookie refused (login CSRF)")
st, _, q, ck = g_start()
need(g_callback(q["state"], "_sso_state=other", user=OWNER_G)[0] == 400, "google: callback with another browser's cookie refused")
need(g_callback("forged", ck, user=OWNER_G)[0] == 400, "google: unknown state refused")
st, _, q, ck = g_start()
st, body, h = g_callback(q["state"], ck, error="access_denied")
need(st == 403 and "_diego_sso" not in "".join(h.get_all("Set-Cookie") or []), "google: user cancels at the provider -> no session")
st, _, q, ck = g_start()
need(g_callback(q["state"], ck, token={"error": "invalid_grant"})[0] == 502, "google: failed code exchange -> no session")
for who, why in [({"email": "mallory@example.com", "email_verified": True}, "non-owner email"),
                 ({"email": "me@diegonmarcos.com", "email_verified": False}, "owner email unverified"),
                 ({"email": "me@diegonmarcos.com.evil.example", "email_verified": True}, "lookalike domain"),
                 ({"email": "ME@diegonmarcos.com ", "email_verified": "true"}, "non-boolean verified flag")]:
    st, _, q, ck = g_start()
    st, body, h = g_callback(q["state"], ck, user=who)
    need(st == 403 and "_diego_sso" not in "".join(h.get_all("Set-Cookie") or []), "google: %s rejected, no cookie" % why)
need(g_start(host="evil.example")[0] == 400, "google: a Host that is not a registered redirect host is refused")
need(g_start("https://evil.example/")[3] is not None and urllib.parse.urlsplit(raw(GO + O + "/start?rd=https%3A%2F%2Fevil.example%2F", {"Host": "account.diegonmarcos.com"})[2]["Location"]).query.find("account.diegonmarcos.com") > 0,
     "google: account.diegonmarcos.com redirect URI is used for that host")
need(post(GO, O, "/device")[0] == 404, "google: device endpoints do not exist on the web flow")

# ---- flags and fail-closed startup ------------------------------------------------------------
off_b, OFF = start(mkcfg(google_on=False), "google", GP + 10)
need(raw(OFF + O + "/start", {"Host": AUTH_H})[0] == 404 and http(OFF + O + "/start")[0] == 404, "disabled provider: no device code, no sign-in page")
need(json.loads(http(OFF + O + "/health")[1])["enabled"] is False, "disabled provider reports enabled=false")
need(http(OFF + O + "/auth", headers={"Cookie": c})[0] == 202, "disabled provider still validates an existing session")
for mut, msg in [(lambda c: c["auth_broker"].update(allowed_emails=[]), "empty google allowlist"),
                 (lambda c: c["auth_broker"].update(allowed_github=[]), "empty github allowlist")]:
    cfg = mkcfg(); mut(cfg)
    try:
        broker.Broker(cfg, "google" if "google" in msg else "github", ENV); need(False, msg + " must refuse to start")
    except SystemExit:
        ok("%s: refuses to start" % msg)
try:
    broker.Broker(mkcfg(), "github", {"AUTH_BROKER_COOKIE_SECRET": "short"}); need(False, "short cookie secret must refuse")
except SystemExit:
    ok("short cookie secret: refuses to start")
try:
    broker.Broker(mkcfg(), "google", {"AUTH_BROKER_COOKIE_SECRET": SECRET}); need(False, "enabled google without a client id must refuse")
except SystemExit:
    ok("enabled provider without a client id: refuses to start")
need(len(json.dumps(BJ["auth_broker"]["allowed_github"])) < 200 and [a["login"] for a in BJ["auth_broker"]["allowed_github"]] == ["diegonmarcos"],
     "declared GitHub allowlist is exactly the owner")
print("PASS: %d checks" % PASS)
