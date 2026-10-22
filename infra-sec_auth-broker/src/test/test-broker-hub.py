#!/usr/bin/env python3
"""Tests for the two hub legs added to the broker (#1083): the GitHub OAuth App web redirect flow and the
Cloudflare Access JWT credential. Real broker HTTP servers; the stubs are the providers only.
Run: python3 -I test/test-broker-hub.py   (from infra-sec_auth-broker/src; stdlib only)"""
import copy, hashlib, json, os, random, sys, threading, time, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "code"))
import main as broker  # noqa: E402

BJ = json.load(open(os.path.join(HERE, "..", "..", "build.json")))
SECRET, PASS = "y" * 40, 0
b64e = broker.b64e


def need(cond, msg):
    global PASS
    if not cond:
        print("FAIL:", msg); sys.exit(1)
    PASS += 1; print("ok:", msg)


# ---- a throwaway RSA key (stdlib has no RSA) --------------------------------------------------
def prime(bits):
    while True:
        p = random.SystemRandom().getrandbits(bits) | (1 << (bits - 1)) | 1
        if all(pow(a, p - 1, p) == 1 for a in (2, 3, 5, 7, 11, 13, 17, 19, 23, 29)):
            return p


def rsa(bits=1024):
    while True:
        p, q = prime(bits // 2), prime(bits // 2)
        n, e = p * q, 65537
        try:
            d = pow(e, -1, (p - 1) * (q - 1))
        except ValueError:
            continue
        if p != q and n.bit_length() == bits:
            return n, e, d


def jwt(key, kid, claims, alg="RS256", tamper=False):
    n, e, d = key
    h = b64e(json.dumps({"alg": alg, "kid": kid, "typ": "JWT"}).encode())
    p = b64e(json.dumps(claims).encode())
    k = (n.bit_length() + 7) // 8
    t = b"\x00" + broker.Broker.SHA256_DI + hashlib.sha256((h + "." + p).encode()).digest()
    em = b"\x00\x01" + b"\xff" * (k - len(t) - 2) + t
    sig = pow(int.from_bytes(em, "big"), d, n).to_bytes(k, "big")
    if tamper:
        p = b64e(json.dumps({**claims, "email": "me@diegonmarcos.com"}).encode())
    return "%s.%s.%s" % (h, p, b64e(sig))


KEY, OTHER = rsa(), rsa()
KID = "kid-1"
AUD = BJ["auth_broker"]["cloudflare_access"]["aud"][0]
ISS = "https://" + BJ["auth_broker"]["cloudflare_access"]["team_domain"]
NOW = int(time.time())


class Stub:
    user, token_reply, certs_hits = {}, {"access_token": "TOK"}, 0
    seen = []


class SH(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, d):
        b = json.dumps(d).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        form = urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        Stub.seen.append({k: v[0] for k, v in form.items()})
        self.reply(Stub.token_reply)

    def do_GET(self):
        if self.path == "/certs":
            Stub.certs_hits += 1
            return self.reply({"keys": [{"kid": KID, "kty": "RSA", "alg": "RS256", "use": "sig",
                                         "n": b64e(KEY[0].to_bytes(128, "big")), "e": b64e(KEY[1].to_bytes(3, "big"))}]})
        self.reply(Stub.user) if self.headers.get("Authorization") == "Bearer TOK" else self.send_error(401)


def serve(h, port):
    s = ThreadingHTTPServer(("127.0.0.1", port), h)
    threading.Thread(target=s.serve_forever, daemon=True).start()


serve(SH, 19641)
STUBURL = "http://127.0.0.1:19641"


def cfg(web_on=True, cf_on=True):
    c = copy.deepcopy(BJ)
    for p in c["auth_broker"]["providers"]:
        if p["id"] == "github":
            p.update(device_url=STUBURL + "/dev", token_url=STUBURL + "/tok", user_url=STUBURL + "/user")
            p["web"].update(enabled=web_on, token_url=STUBURL + "/tok")
    c["auth_broker"]["cloudflare_access"].update(enabled=cf_on, certs_url=STUBURL + "/certs")
    return c


ENV = {"AUTH_BROKER_COOKIE_SECRET": SECRET, "AUTH_BROKER_GOOGLE_CLIENT_ID": "g", "AUTH_BROKER_GOOGLE_CLIENT_SECRET": "s"}
WEBENV = {**ENV, "AUTH_BROKER_GITHUB_APP_CLIENT_SECRET": "appsecret"}


def start(c, pid, port, env):
    b = broker.Broker(c, pid, env)
    s = ThreadingHTTPServer(("127.0.0.1", port), broker.make_handler(b))
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return b, "http://127.0.0.1:%d" % port


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None


OPENER = urllib.request.build_opener(NoRedirect)


def raw(url, headers=None):
    try:
        r = OPENER.open(urllib.request.Request(url, headers=headers or {}), timeout=5)
        return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


G, H = "/oauth2/github", "auth.diegonmarcos.com"
OWNER = {"login": "diegonmarcos", "id": 100614489}

# ---- GitHub OAuth App, web redirect flow ----------------------------------------------------------
web_b, W = start(cfg(), "github", 19642, WEBENV)
need(BJ["auth_broker"]["providers"][1]["web"]["client_id"] == "Ov23li1WLY8SoctMF2hp", "the owner's GitHub OAuth App client id is declared")
need(BJ["auth_broker"]["providers"][1]["web"]["redirect_uris"] == ["https://auth.diegonmarcos.com/oauth2/github/callback"], "web redirect URI is the auth. callback")


def start_web(rd="/"):
    st, _, h = raw(W + G + "/start?rd=" + urllib.parse.quote(rd), {"Host": H})
    if st != 302:
        return st, None, None
    loc = urllib.parse.urlsplit(h["Location"])
    return st, {k: v[0] for k, v in urllib.parse.parse_qs(loc.query).items()} | {"_netloc": loc.netloc + loc.path}, h["Set-Cookie"].split(";")[0]


def callback(state, ck, user=OWNER, token=None, error=None):
    Stub.user, Stub.token_reply = user, token or {"access_token": "TOK"}
    qs = {"state": state, **({"error": error} if error else {"code": "C1"})}
    return raw(W + G + "/callback?" + urllib.parse.urlencode(qs), {"Host": H, **({"Cookie": ck} if ck else {})})


st, q, ck = start_web("https://suite.diegonmarcos.com/p")
need(st == 302 and q["_netloc"] == "github.com/login/oauth/authorize" and q["client_id"] == "Ov23li1WLY8SoctMF2hp" and q["code_challenge_method"] == "S256"
     and q["redirect_uri"] == "https://auth.diegonmarcos.com/oauth2/github/callback" and q["scope"] == "read:user", "github web: /start redirects to GitHub authorize with PKCE, state, registered redirect URI")
Stub.seen.clear()
st, _, h = callback(q["state"], ck)
sent = Stub.seen[-1]
need(st == 302 and h["Location"] == "https://suite.diegonmarcos.com/p" and "_diego_sso=v1." in "".join(h.get_all("Set-Cookie")), "github web: owner callback -> session cookie, redirect to rd")
need(sent["client_secret"] == "appsecret" and sent["client_id"] == "Ov23li1WLY8SoctMF2hp" and broker.b64e(hashlib.sha256(sent["code_verifier"].encode()).digest()) == q["code_challenge"],
     "github web: code exchange carries the app secret from the environment and the PKCE verifier")
cookie = [c.split(";")[0] for c in h.get_all("Set-Cookie") if c.startswith("_diego_sso=")][0]
need(raw(W + G + "/auth", {"Cookie": cookie})[0] == 202, "github web: the issued session passes the gate")
need(callback(q["state"], ck)[0] == 400, "github web: state is single use")
st, q, ck = start_web()
need(callback(q["state"], None)[0] == 400 and callback("forged", ck)[0] == 400, "github web: missing binding cookie / forged state refused")
for who, why in [({"login": "mallory", "id": 1}, "non-owner"), ({"login": "diegonmarcos", "id": 7}, "owner login, other id"), ({"login": "x", "id": 100614489}, "owner id, other login")]:
    st, q, ck = start_web()
    st, _, h = callback(q["state"], ck, user=who)
    need(st == 403 and "_diego_sso" not in "".join(h.get_all("Set-Cookie") or []), "github web: %s rejected, no cookie" % why)
st, q, ck = start_web()
need(callback(q["state"], ck, error="access_denied")[0] == 403, "github web: user cancels -> no session")
st, q, ck = start_web()
need(callback(q["state"], ck, token={"error": "bad_verification_code"})[0] == 502, "github web: failed exchange -> no session")
need(raw(W + G + "/start", {"Host": "evil.example"})[0] == 400, "github web: unregistered Host refused")
need(raw(W + G + "/start?flow=device", {"Host": H})[0] == 200, "github: ?flow=device keeps the gh public client device page as fallback")

# without the secret the web leg is off and the device flow is what /start serves; no callback exists
nos_b, NOS = start(cfg(), "github", 19643, ENV)
need(nos_b.web_on is False and raw(NOS + G + "/start", {"Host": H})[0] == 200 and b"Sign in with GitHub" in raw(NOS + G + "/start", {"Host": H})[1],
     "github web: secret absent -> web leg off, device flow page served")
need(raw(NOS + G + "/callback?state=x&code=y", {"Host": H})[0] == 404, "github web: secret absent -> callback is not served")
dis_b, DIS = start(cfg(web_on=False), "github", 19644, WEBENV)
need(dis_b.web_on is False and raw(DIS + G + "/callback?state=x&code=y", {"Host": H})[0] == 404, "github web: web.enabled=false -> off even with the secret")
need("AUTH_BROKER_GITHUB_APP_CLIENT_SECRET" in open(os.path.join(HERE, "..", "secrets.yaml.example")).read(), "sops placeholder key AUTH_BROKER_GITHUB_APP_CLIENT_SECRET is declared")

# ---- Cloudflare Access JWT ---------------------------------------------------------------------
cf_b, CF = start(cfg(), "google", 19645, ENV)
good = {"iss": ISS, "aud": [AUD], "email": "me@diegonmarcos.com", "exp": NOW + 600, "iat": NOW, "type": "app"}


def cf(tok):
    return raw(CF + "/oauth2/google/cf-auth", {"Cf-Access-Jwt-Assertion": tok} if tok else {})


st, _, h = cf(jwt(KEY, KID, good))
need(st == 202 and h["X-Auth-Request-Email"] == "me@diegonmarcos.com", "cloudflare: owner JWT signed by the team key -> 202 + identity")
need(cf(None)[0] == 401 and cf("")[0] == 401 and cf("a.b.c")[0] == 401 and cf("garbage")[0] == 401, "cloudflare: no/garbage token -> 401")
need(cf(jwt(OTHER, KID, good))[0] == 401, "cloudflare: forged (signed by another key, same kid) -> 401")
need(cf(jwt(KEY, KID, {**good, "email": "mallory@example.com"}, tamper=True))[0] == 401, "cloudflare: payload tampered after signing -> 401")
need(cf(jwt(KEY, "unknown", good))[0] == 401, "cloudflare: unknown kid -> 401")
need(cf(jwt(KEY, KID, good, alg="none"))[0] == 401 and cf(jwt(KEY, KID, good, alg="HS256"))[0] == 401, "cloudflare: alg other than RS256 -> 401")
need(cf(jwt(KEY, KID, {**good, "email": "mallory@example.com"}))[0] == 401, "cloudflare: validly signed but non-owner email -> 401")
need(cf(jwt(KEY, KID, {**good, "email": "me@diegonmarcos.com.evil.example"}))[0] == 401, "cloudflare: lookalike email -> 401")
need(cf(jwt(KEY, KID, {k: v for k, v in good.items() if k != "email"} | {"common_name": "svc"}))[0] == 401, "cloudflare: service-token JWT (no email) -> 401")
need(cf(jwt(KEY, KID, {**good, "aud": ["0" * 64]}))[0] == 401 and cf(jwt(KEY, KID, {**good, "aud": []}))[0] == 401, "cloudflare: wrong/empty audience -> 401")
need(cf(jwt(KEY, KID, {**good, "iss": "https://evil.cloudflareaccess.com"}))[0] == 401, "cloudflare: wrong issuer -> 401")
need(cf(jwt(KEY, KID, {**good, "exp": NOW - 5}))[0] == 401, "cloudflare: expired -> 401")
need(cf(jwt(KEY, KID, {**good, "aud": AUD}))[0] == 202, "cloudflare: aud as a plain string is accepted")
before = Stub.certs_hits
for _ in range(5):
    cf(jwt(KEY, "unknown", good))
need(Stub.certs_hits - before <= 1, "cloudflare: unknown kid does not hammer the certs URL")
need(raw(CF + "/oauth2/google/cf-auth", {"Cookie": "_diego_sso=x"})[0] == 401, "cloudflare: a cookie alone is not a CF credential")
off_b, OFF = start(cfg(cf_on=False), "google", 19646, ENV)
need(raw(OFF + "/oauth2/google/cf-auth", {"Cf-Access-Jwt-Assertion": jwt(KEY, KID, good)})[0] == 401, "cloudflare: disabled -> a valid JWT is refused")
for mut, msg in [(lambda c: c["auth_broker"]["cloudflare_access"].update(aud=[]), "no aud"), (lambda c: c["auth_broker"]["cloudflare_access"].update(team_domain=""), "no team domain")]:
    c = cfg(); mut(c)
    try:
        broker.Broker(c, "google", ENV); need(False, "cloudflare enabled with " + msg + " must refuse")
    except SystemExit:
        need(True, "cloudflare: enabled with %s -> refuses to start (fail closed)" % msg)

# ---- Cloudflare One as a sign-in provider (flow "access"): start + callback ------------------------
CFP = next(p for p in BJ["auth_broker"]["providers"] if p["id"] == "cloudflare")
C = "/oauth2/cloudflare"
need(CFP["enabled"] is True and CFP["flow"] == "access" and CFP["login_url"].startswith("https://auth-cf.diegonmarcos.com" + C + "/"), "cloudflare provider: declared once in build.json with its own enabled flag and an https login_url")
need("cloudflare" in BJ["containers"] and BJ["containers"]["cloudflare"]["port"] == CFP["port"], "cloudflare provider: has its own container on the declared port")
ab_b, AB = start(cfg(), "cloudflare", 19647, ENV)
st, _, h = raw(AB + C + "/start?rd=" + urllib.parse.quote("https://suite.diegonmarcos.com/p"), {"Host": H})
loc = urllib.parse.urlsplit(h["Location"]) if st == 302 else None
need(st == 302 and loc.netloc == "auth-cf.diegonmarcos.com" and loc.path == C + "/callback" and urllib.parse.parse_qs(loc.query)["rd"] == ["https://suite.diegonmarcos.com/p"],
     "cloudflare start: 302 to the Access-protected callback host carrying rd")
st, _, h = raw(AB + C + "/start?rd=%2Fapp", {"Host": "account.diegonmarcos.com"})
need(st == 302 and urllib.parse.parse_qs(urllib.parse.urlsplit(h["Location"]).query)["rd"] == ["https://account.diegonmarcos.com/app"], "cloudflare start: a relative rd is resolved against the chooser host it came from")
st, _, h = raw(AB + C + "/start?rd=" + urllib.parse.quote("https://evil.example/x"), {"Host": H})
need(st == 302 and urllib.parse.parse_qs(urllib.parse.urlsplit(h["Location"]).query)["rd"] == ["https://auth.diegonmarcos.com/"], "cloudflare start: foreign rd is replaced")
need(raw(AB + C + "/start", {"Host": "evil.example"})[0] == 404, "cloudflare start: a Host that is not a declared chooser host is refused")
need(raw(AB + C + "/health")[0] == 200 and json.loads(raw(AB + C + "/health")[1]) == {"enabled": True, "provider": "cloudflare"}, "cloudflare: /health reports enabled")


def cb(tok, rd="https://suite.diegonmarcos.com/p"):
    return raw(AB + C + "/callback?rd=" + urllib.parse.quote(rd), {"Cf-Access-Jwt-Assertion": tok} if tok else {})


def minted(h): return "_diego_sso=v1." in "".join(h.get_all("Set-Cookie") or [])


st, _, h = cb(jwt(KEY, KID, good))
need(st == 302 and h["Location"] == "https://suite.diegonmarcos.com/p" and minted(h), "cloudflare callback: owner JWT -> _diego_sso cookie, 302 to rd")
ck = [c for c in h.get_all("Set-Cookie") if c.startswith("_diego_sso=")][0]
need("Domain=.diegonmarcos.com" in ck and "Secure" in ck and "HttpOnly" in ck, "cloudflare callback: cookie is the shared domain-wide Secure HttpOnly session")
need(raw(W + G + "/auth", {"Cookie": ck.split(";")[0]})[0] == 202 and raw(CF + "/oauth2/google/auth", {"Cookie": ck.split(";")[0]})[0] == 202, "cloudflare callback: the issued session passes the gate on the other instances")
st, _, h = cb(jwt(KEY, KID, good), "https://evil.example/x")
need(st == 302 and h["Location"] == "https://auth.diegonmarcos.com/", "cloudflare callback: foreign rd is not followed")
st, _, h = cb(jwt(KEY, KID, good), "//evil.example")
need(st == 302 and h["Location"] == "https://auth.diegonmarcos.com/", "cloudflare callback: protocol-relative rd is not followed")
for name, tok in [("no JWT", None), ("garbage", "a.b.c"), ("forged (other key)", jwt(OTHER, KID, good)),
                  ("tampered payload", jwt(KEY, KID, {**good, "email": "mallory@example.com"}, tamper=True)),
                  ("expired", jwt(KEY, KID, {**good, "exp": NOW - 5})), ("wrong AUD", jwt(KEY, KID, {**good, "aud": ["0" * 64]})),
                  ("wrong issuer", jwt(KEY, KID, {**good, "iss": "https://evil.cloudflareaccess.com"})),
                  ("non-owner email", jwt(KEY, KID, {**good, "email": "mallory@example.com"})),
                  ("service token (no email)", jwt(KEY, KID, {k: v for k, v in good.items() if k != "email"})),
                  ("alg none", jwt(KEY, KID, good, alg="none"))]:
    st, _, h = cb(tok)
    need(st == 401 and not minted(h) and "Location" not in h, "cloudflare callback: %s -> 401, no cookie" % name)
need(raw(AB + C + "/callback", {"Cookie": "CF_Authorization=x"})[0] == 401, "cloudflare callback: a CF_Authorization cookie alone is not a credential")
need(raw(AB + C + "/device", None)[0] in (403, 404), "cloudflare: no device endpoints")
dis_c, DISC = start({**cfg(), "auth_broker": {**cfg()["auth_broker"], "providers": [dict(p, enabled=False) if p["id"] == "cloudflare" else p for p in cfg()["auth_broker"]["providers"]]}}, "cloudflare", 19648, ENV)
need(raw(DISC + C + "/health")[0] == 200 and json.loads(raw(DISC + C + "/health")[1])["enabled"] is False, "cloudflare: provider flag off -> /health says disabled (chooser hides the button)")
st, _, h = raw(DISC + C + "/callback", {"Cf-Access-Jwt-Assertion": jwt(KEY, KID, good)})
need(raw(DISC + C + "/start", {"Host": H})[0] == 404 and st == 401 and not minted(h), "cloudflare: provider flag off -> start 404, a valid JWT gets no cookie")
nocf = cfg(cf_on=False)
try:
    broker.Broker(nocf, "cloudflare", ENV); need(False, "cloudflare provider enabled without cloudflare_access must refuse")
except SystemExit:
    need(True, "cloudflare: provider enabled while cloudflare_access is off -> refuses to start (fail closed)")
print("PASS: %d checks" % PASS)
