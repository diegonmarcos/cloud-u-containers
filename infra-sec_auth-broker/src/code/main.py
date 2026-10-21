#!/usr/bin/env python3
"""Fleet auth broker (#1066): GitHub sign-in by the OAuth device flow (RFC 8628), Google by the
standard web authorization-code flow (PKCE S256 + state). A provider's `flow` in build.json picks one.

One process serves ONE provider (BROKER_PROVIDER); every instance validates the same signed
session cookie, so `<prefix>/auth` on any instance admits a session issued by any other.

  GET  <prefix>/start?rd=  sign-in page: asks the broker for a device code, shows the user code
                           and the provider's verification link, polls until approved
  POST <prefix>/device     request a device code from the provider (returns user code + link)
  POST <prefix>/poll       one poll of the provider token endpoint for a pending flow
  GET  <prefix>/start      (flow web) 302 to the provider with state + PKCE; <prefix>/callback finishes
  GET  <prefix>/auth       forward_auth target: 202 + X-Auth-Request-Email on a valid session, else 401
  GET  <prefix>/health     200 {"enabled": bool, "provider": id}

Identity: the provider's user is checked against the allowlist declared in build.json
(`auth_broker.allowed_emails` for Google, `auth_broker.allowed_github` for GitHub). Anyone else is
refused and gets no cookie. The session cookie is HMAC-SHA256 signed with AUTH_BROKER_COOKIE_SECRET.
Stdlib only. Config: build.json (path in BROKER_CONFIG); secrets only from the environment.
"""
import base64, hashlib, hmac, html, json, os, secrets, sys, threading, time
import urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UA = "diego-auth-broker/1"
MAX_FLOWS = 64
RATE_N, RATE_WINDOW = 10, 600          # device codes per client IP per window


def b64e(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def b64d(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class Broker:
    def __init__(self, cfg, provider_id, env):
        ab = cfg["auth_broker"]
        self.ab = ab
        self.p = next(p for p in ab["providers"] if p["id"] == provider_id)
        self.enabled = bool(self.p.get("enabled", False))
        self.prefix = self.p["prefix"]
        self.flow = self.p.get("flow", "device")
        self.redirect_uris = list(self.p.get("redirect_uris", []))
        self.states = {}                     # web flow: state -> pending authorization
        self.cookie_name = ab["cookie_name"]
        self.cookie_domain = ab.get("cookie_domain", "")
        self.ttl = int(ab.get("cookie_expire_seconds", 43200))
        self.rd_domain = ab.get("rd_domain", "diegonmarcos.com")
        self.emails = [e.strip().lower() for e in ab.get("allowed_emails", [])]
        self.gh = [{"login": a["login"].lower(), "id": int(a["id"]), "email": a["email"]}
                   for a in ab.get("allowed_github", [])]
        if not (self.emails if self.p["provider"] == "google" else self.gh):
            raise SystemExit("allowlist for provider %s is empty: refusing to run open" % provider_id)
        self.secret = env.get("AUTH_BROKER_COOKIE_SECRET", "")
        if len(self.secret) < 32:
            raise SystemExit("AUTH_BROKER_COOKIE_SECRET missing or shorter than 32 chars")
        pre = self.p.get("secret_prefix", "")
        self.client_id = self.p.get("client_id") or env.get(pre + "_CLIENT_ID", "")
        self.client_secret = env.get(pre + "_CLIENT_SECRET", "") if pre else ""
        if self.enabled and not self.client_id:
            raise SystemExit("provider %s is enabled but has no client id" % provider_id)
        self.flows, self.hits, self.lock = {}, {}, threading.Lock()

    # ---- session cookie -------------------------------------------------------------------
    def sign(self, body):
        return b64e(hmac.new(self.secret.encode(), body.encode(), hashlib.sha256).digest())

    def make_cookie(self, email, provider):
        now = int(time.time())
        body = b64e(json.dumps({"sub": email, "p": provider, "iat": now, "exp": now + self.ttl}).encode())
        return "v1.%s.%s" % (body, self.sign("v1." + body))

    def check_cookie(self, value):
        try:
            v, body, sig = value.split(".")
            if v != "v1" or not hmac.compare_digest(sig, self.sign("v1." + body)):
                return None
            d = json.loads(b64d(body))
            if int(d["exp"]) <= time.time():
                return None
            return d["sub"]
        except Exception:
            return None

    def session_email(self, cookie_header):
        for part in (cookie_header or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == self.cookie_name:
                e = self.check_cookie(v)
                if e:
                    return e
        return None

    def set_cookie(self, value, max_age):
        a = ["%s=%s" % (self.cookie_name, value), "Path=/", "Max-Age=%d" % max_age, "Secure", "HttpOnly", "SameSite=Lax"]
        if self.cookie_domain:
            a.insert(1, "Domain=" + self.cookie_domain)
        return "; ".join(a)

    # ---- redirect target ------------------------------------------------------------------
    def safe_rd(self, rd):
        if not rd:
            return "/"
        if rd.startswith("/") and not rd.startswith("//") and "\\" not in rd:
            return rd
        u = urllib.parse.urlsplit(rd)
        h = (u.hostname or "").lower()
        if u.scheme == "https" and (h == self.rd_domain or h.endswith("." + self.rd_domain)):
            return rd
        return "/"

    # ---- provider calls -------------------------------------------------------------------
    def call(self, url, data=None, headers=None):
        req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": UA, **(headers or {})},
                                     data=urllib.parse.urlencode(data).encode() if data is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:      # Google answers pending/denied with 4xx + JSON
            try:
                return e.code, json.loads(e.read() or b"{}")
            except Exception:
                return e.code, {}

    def rate_ok(self, ip):
        now = time.time()
        with self.lock:
            h = [t for t in self.hits.get(ip, []) if now - t < RATE_WINDOW]
            ok = len(h) < RATE_N
            if ok:
                h.append(now)
            self.hits[ip] = h
            for k in [k for k, v in self.hits.items() if not v or now - v[-1] > RATE_WINDOW]:
                self.hits.pop(k, None)
            return ok

    def new_device(self, ip):
        if not self.enabled:
            return 404, {"error": "disabled"}
        if not self.rate_ok(ip):
            return 429, {"error": "rate_limited"}
        with self.lock:
            now = time.time()
            for k in [k for k, f in self.flows.items() if f["exp"] <= now]:
                self.flows.pop(k)
            if len(self.flows) >= MAX_FLOWS:
                return 429, {"error": "busy"}
        data = {"client_id": self.client_id, "scope": self.p["scope"]}
        st, d = self.call(self.p["device_url"], data)
        if st != 200 or "device_code" not in d:
            print("device code request failed: status=%s error=%s" % (st, d.get("error")), flush=True)
            return 502, {"error": "provider_error", "detail": d.get("error", "")}
        sid = secrets.token_urlsafe(24)
        iv = max(int(d.get("interval", 5)), 1)
        with self.lock:
            self.flows[sid] = {"dc": d["device_code"], "exp": time.time() + int(d.get("expires_in", 900)),
                               "iv": iv, "next": time.time() + iv}
        return 200, {"sid": sid, "user_code": d["user_code"], "interval": iv, "expires_in": int(d.get("expires_in", 900)),
                     "verification_uri": d.get("verification_uri") or d.get("verification_url")}

    def identity(self, token):
        """Return the allowlisted email for this provider token, or None."""
        auth = {"Authorization": "Bearer " + token}
        if self.p["provider"] == "github":
            st, u = self.call(self.p["user_url"], headers=auth)
            if st != 200 or "id" not in u:
                return None
            for a in self.gh:
                if int(u["id"]) == a["id"] and str(u.get("login", "")).lower() == a["login"]:
                    return a["email"]
            print("github account not on the allowlist: %s" % u.get("login"), flush=True)
            return None
        st, u = self.call(self.p["userinfo_url"], headers=auth)
        em = str(u.get("email", "")).strip().lower()
        if st == 200 and u.get("email_verified") is True and em in self.emails:
            return em
        print("google account not on the allowlist: %s" % em, flush=True)
        return None

    def poll(self, sid):
        with self.lock:
            f = self.flows.get(sid)
            if not f:
                return 404, {"status": "unknown"}, None
            now = time.time()
            if f["exp"] <= now:
                self.flows.pop(sid, None)
                return 200, {"status": "expired"}, None
            if now < f["next"]:
                return 200, {"status": "pending"}, None
            f["next"] = now + f["iv"]
            dc = f["dc"]
        data = {"client_id": self.client_id, "device_code": dc, "grant_type": "urn:ietf:params:oauth:grant-type:device_code"}
        if self.client_secret:
            data["client_secret"] = self.client_secret
        st, d = self.call(self.p["token_url"], data)
        err = d.get("error")
        if err == "authorization_pending":
            return 200, {"status": "pending"}, None
        if err == "slow_down":
            with self.lock:
                if sid in self.flows:
                    self.flows[sid]["iv"] += 5
                    self.flows[sid]["next"] = time.time() + self.flows[sid]["iv"]
            return 200, {"status": "pending"}, None
        if err or not d.get("access_token"):
            with self.lock:
                self.flows.pop(sid, None)
            return 200, {"status": "expired" if err == "expired_token" else "denied"}, None
        with self.lock:
            self.flows.pop(sid, None)            # one use: the device code is spent either way
        email = self.identity(d["access_token"])
        if not email:
            return 200, {"status": "forbidden"}, None
        return 200, {"status": "ok"}, self.set_cookie(self.make_cookie(email, self.p["id"]), self.ttl)

    # ---- web authorization-code flow (PKCE S256 + state) ----------------------------------------
    STATE_COOKIE = "_sso_state"

    def web_redirect_uri(self, host):
        """The registered redirect URI for this request's Host, or None (never built from input)."""
        host = (host or "").lower()
        for u in self.redirect_uris:
            if urllib.parse.urlsplit(u).netloc == host:
                return u
        return None

    def web_start(self, host, rd):
        if not self.enabled or self.flow != "web":
            return 404, None, None
        ru = self.web_redirect_uri(host)
        if not ru:
            return 400, None, None
        now = time.time()
        with self.lock:
            for k in [k for k, v in self.states.items() if v["exp"] <= now]:
                self.states.pop(k)
            if len(self.states) >= MAX_FLOWS * 4:
                return 429, None, None
            state, verifier, bind = secrets.token_urlsafe(24), secrets.token_urlsafe(48), secrets.token_urlsafe(16)
            self.states[state] = {"v": verifier, "bind": bind, "ru": ru, "rd": self.safe_rd(rd), "exp": now + 600}
        q = {"client_id": self.client_id, "redirect_uri": ru, "response_type": "code", "scope": self.p["scope"],
             "state": state, "code_challenge": b64e(hashlib.sha256(verifier.encode()).digest()),
             "code_challenge_method": "S256", "prompt": "select_account"}
        cookie = "%s=%s; Path=%s; Max-Age=600; Secure; HttpOnly; SameSite=Lax" % (self.STATE_COOKIE, bind, self.prefix)
        return 302, self.p["auth_url"] + "?" + urllib.parse.urlencode(q), cookie

    def web_callback(self, query, cookie_header):
        """Returns (status, location_or_message, set_cookie). State is single use and bound to the browser."""
        q = {k: v[0] for k, v in urllib.parse.parse_qs(query).items()}
        with self.lock:
            st = self.states.pop(q.get("state", ""), None)
        bind = ""
        for part in (cookie_header or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == self.STATE_COOKIE:
                bind = v
        clear = "%s=; Path=%s; Max-Age=0; Secure; HttpOnly; SameSite=Lax" % (self.STATE_COOKIE, self.prefix)
        if not st or st["exp"] <= time.time() or not bind or not hmac.compare_digest(bind, st["bind"]):
            return 400, "Sign-in expired or invalid. Start again.", clear
        if q.get("error") or not q.get("code"):
            return 403, "Sign-in was cancelled or denied.", clear
        data = {"client_id": self.client_id, "client_secret": self.client_secret, "code": q["code"],
                "code_verifier": st["v"], "redirect_uri": st["ru"], "grant_type": "authorization_code"}
        code, d = self.call(self.p["token_url"], data)
        if code != 200 or not d.get("access_token"):
            print("code exchange failed: status=%s error=%s" % (code, d.get("error")), flush=True)
            return 502, "Sign-in failed at the provider.", clear
        email = self.identity(d["access_token"])
        if not email:
            return 403, "This account is not allowed.", clear
        return 302, st["rd"], [clear, self.set_cookie(self.make_cookie(email, self.p["id"]), self.ttl)]


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Sign in with __LABEL__</title><style>
:root{--bg:#f6f7f9;--fg:#15171a;--card:#fff;--line:#d9dde3;--acc:#2b6cb0}
@media (prefers-color-scheme:dark){:root{--bg:#101215;--fg:#e8eaed;--card:#181b20;--line:#2c3139;--acc:#7fb2ee}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,sans-serif}
main{width:min(92vw,380px);background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px}
h1{font-size:1.15rem;margin:0 0 12px}#code{font:700 2rem/1.2 ui-monospace,monospace;letter-spacing:.12em;text-align:center;margin:14px 0}
a{color:var(--acc)}#st{font-size:.85rem;opacity:.8;min-height:1.2em}</style></head><body><main>
<h1>Sign in with __LABEL__</h1><div id="body">Requesting a code&hellip;</div><div id="st"></div></main>
<script>(function(){
var P="__PREFIX__",RD=new URLSearchParams(location.search).get("rd")||"/",$=function(i){return document.getElementById(i)};
function post(u,b){return fetch(P+u,{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Requested-With":"sso"},body:JSON.stringify(b||{})}).then(function(r){return r.json().then(function(j){j._s=r.status;return j})})}
function fail(m){$("st").textContent=m;$("body").innerHTML='<a href="'+P+'/start?rd='+encodeURIComponent(RD)+'">Try again</a>'}
post("/device").then(function(d){
 if(!d.sid){return fail("Could not start sign-in ("+(d.error||d._s)+").")}
 $("body").innerHTML='Open <a id="l" target="_blank" rel="noopener"></a> and enter this code:<div id="code"></div>';
 $("l").href=d.verification_uri;$("l").textContent=d.verification_uri;$("code").textContent=d.user_code;
 $("st").textContent="Waiting for approval…";
 var t=setInterval(function(){post("/poll",{sid:d.sid,rd:RD}).then(function(r){
  if(r.status==="pending")return;clearInterval(t);
  if(r.status==="ok"){$("st").textContent="Signed in.";location.href=r.rd||"/";return}
  fail(r.status==="forbidden"?"This account is not allowed.":r.status==="expired"?"The code expired.":"Sign-in was denied.")
 }).catch(function(){})},Math.max(d.interval,3)*1000+500)
}).catch(function(){fail("Network error.")});
})();</script></body></html>"""


def make_handler(b):
    class H(BaseHTTPRequestHandler):
        server_version = "auth-broker"

        def log_message(self, *a): pass

        def send(self, code, body=b"", ctype="application/json", extra=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for k, v in (extra or []):
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def ip(self): return self.headers.get("X-Real-IP") or self.client_address[0]

        def same_origin(self):
            # State-changing calls come only from our own sign-in page: custom header + no foreign Origin.
            if self.headers.get("X-Requested-With") != "sso":
                return False
            o = self.headers.get("Origin")
            return not o or urllib.parse.urlsplit(o).netloc == self.headers.get("Host")

        def do_GET(self):
            u = urllib.parse.urlsplit(self.path)
            path = u.path
            if not path.startswith(b.prefix + "/"):
                return self.send(404, {"error": "not_found"})
            op = path[len(b.prefix):]
            if op == "/health":
                return self.send(200, {"enabled": b.enabled, "provider": b.p["id"]})
            if op == "/auth":
                e = b.session_email(self.headers.get("Cookie"))
                return self.send(202, b"", "text/plain", [("X-Auth-Request-Email", e)]) if e else self.send(401, b"", "text/plain")
            if b.flow == "web" and op in ("/start", "/callback"):
                if op == "/start":
                    qs = urllib.parse.parse_qs(u.query)
                    code, loc, ck = b.web_start(self.headers.get("Host"), (qs.get("rd") or [""])[0])
                    if code != 302:
                        return self.send(code, "<p>Sign-in is not available.</p>", "text/html; charset=utf-8")
                    return self.send(302, b"", "text/plain", [("Location", loc), ("Set-Cookie", ck)])
                code, out, ck = b.web_callback(u.query, self.headers.get("Cookie"))
                cks = [("Set-Cookie", c) for c in (ck if isinstance(ck, list) else [ck])]
                if code == 302:
                    return self.send(302, b"", "text/plain", [("Location", out)] + cks)
                return self.send(code, "<p>%s</p><p><a href=\"%s/start\">Try again</a></p>" % (html.escape(out), b.prefix), "text/html; charset=utf-8", cks)
            if op == "/start":
                if not b.enabled:
                    return self.send(404, "<p>This sign-in method is not enabled.</p>", "text/html; charset=utf-8")
                page = PAGE.replace("__LABEL__", b.p.get("label", b.p["id"])).replace("__PREFIX__", b.prefix)
                return self.send(200, page, "text/html; charset=utf-8", [("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")])
            return self.send(404, {"error": "not_found"})

        def do_POST(self):
            path = urllib.parse.urlsplit(self.path).path
            if not path.startswith(b.prefix + "/") or not self.same_origin():
                return self.send(403, {"error": "forbidden"})
            op = path[len(b.prefix):]
            try:
                n = min(int(self.headers.get("Content-Length") or 0), 4096)
                body = json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                return self.send(400, {"error": "bad_request"})
            if b.flow == "web":
                return self.send(404, {"error": "not_found"})
            if op == "/device":
                code, d = b.new_device(self.ip())
                return self.send(code, d)
            if op == "/poll":
                if not b.enabled:
                    return self.send(404, {"status": "disabled"})
                code, d, cookie = b.poll(str(body.get("sid", "")))
                if cookie:
                    d["rd"] = b.safe_rd(body.get("rd", ""))
                return self.send(code, d, extra=[("Set-Cookie", cookie)] if cookie else None)
            return self.send(404, {"error": "not_found"})
    return H


def main():
    cfg = json.load(open(os.environ.get("BROKER_CONFIG", "/app/build.json")))
    pid = os.environ["BROKER_PROVIDER"]
    b = Broker(cfg, pid, os.environ)
    host, port = os.environ.get("BIND_HOST", "0.0.0.0"), int(os.environ.get("PORT", b.p["port"]))
    print("auth-broker %s enabled=%s listening %s:%s" % (pid, b.enabled, host, port), flush=True)
    ThreadingHTTPServer((host, port), make_handler(b)).serve_forever()


if __name__ == "__main__":
    main()
