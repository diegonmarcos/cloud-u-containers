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
  GET  <prefix>/start      (github, when the OAuth App secret is present) web flow; ?flow=device keeps the device flow
  GET  <prefix>/start      (flow access, Cloudflare One) 302 to the Access-protected callback host `login_url`
  GET  <prefix>/callback   (flow access) reached through Cloudflare Access: verifies Cf-Access-Jwt-Assertion, issues the
                           session cookie, 302 to rd; no/forged/expired/wrong-AUD/non-owner JWT -> 401, no cookie
  GET  <prefix>/start      (flow email) address form, then 6-digit code form; POST <prefix>/request {email} and
                           POST <prefix>/verify {sid, code}; recovery path with no vault/Authelia/TOTP dependency (#1118)
  GET  <prefix>/cf-auth    forward_auth target: 202 + X-Auth-Request-Email for a valid Cloudflare Access JWT, else 401
  GET  <prefix>/auth       forward_auth target: 202 + X-Auth-Request-Email on a valid session, else 401
  GET  <prefix>/health     200 {"enabled": bool, "provider": id}

Identity: the provider's user is checked against the allowlist declared in build.json
(`auth_broker.allowed_emails` for Google, `auth_broker.allowed_github` for GitHub). Anyone else is
refused and gets no cookie. The session cookie is HMAC-SHA256 signed with AUTH_BROKER_COOKIE_SECRET.
Stdlib only. Config: build.json (path in BROKER_CONFIG); secrets only from the environment.
"""
import base64, hashlib, hmac, html, json, os, secrets, smtplib, ssl, socket, sys, threading, time
from email.message import EmailMessage
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
        self.states = {}                     # web flow: state -> pending authorization
        self.cookie_name = ab["cookie_name"]
        self.cookie_domain = ab.get("cookie_domain", "")
        self.ttl = int(ab.get("cookie_expire_seconds", 43200))
        self.rd_domain = ab.get("rd_domain", "diegonmarcos.com")
        self.emails = [e.strip().lower() for e in ab.get("allowed_emails", [])]
        self.gh = [{"login": a["login"].lower(), "id": int(a["id"]), "email": a["email"]}
                   for a in ab.get("allowed_github", [])]
        if not (self.gh if self.p["provider"] == "github" else self.emails):
            raise SystemExit("allowlist for provider %s is empty: refusing to run open" % provider_id)
        self.secret = env.get("AUTH_BROKER_COOKIE_SECRET", "")
        if len(self.secret) < 32:
            raise SystemExit("AUTH_BROKER_COOKIE_SECRET missing or shorter than 32 chars")
        pre = self.p.get("secret_prefix", "")
        self.client_id = self.p.get("client_id") or env.get(pre + "_CLIENT_ID", "")
        self.client_secret = env.get(pre + "_CLIENT_SECRET", "") if pre else ""
        if self.enabled and not self.client_id and self.flow not in ("access", "email"):
            raise SystemExit("provider %s is enabled but has no client id" % provider_id)
        self.flows, self.hits, self.lock = {}, {}, threading.Lock()
        # Web authorization-code flow: a provider with flow "web" (Google), or a device-flow provider
        # that also declares a `web` block (GitHub OAuth App). The web leg is live only when enabled,
        # the provider is enabled and its client secret is present in the environment.
        w = self.p if self.flow == "web" else (self.p.get("web") or None)
        self.w = w or {}
        wpre = self.w.get("secret_prefix", "")
        self.web_cid = self.w.get("client_id") or env.get(wpre + "_CLIENT_ID", "")
        self.web_sec = env.get(wpre + "_CLIENT_SECRET", "") if wpre else ""
        if self.flow == "web":
            self.web_on = self.enabled
        else:
            self.web_on = bool(w) and self.enabled and bool(w.get("enabled", False)) and bool(self.web_cid) and bool(self.web_sec)
        self.redirect_uris = list(self.w.get("redirect_uris", []))
        # Cloudflare Access: verify the Access JWT (Cf-Access-Jwt-Assertion) against the team certs.
        cf = ab.get("cloudflare_access") or {}
        self.cf = cf
        self.cf_on = bool(cf.get("enabled", False))
        self.cf_keys, self.cf_keys_at = {}, 0.0
        if self.cf_on and not (cf.get("team_domain") and cf.get("aud") and self.emails):
            raise SystemExit("cloudflare_access is enabled without team_domain, aud and an email allowlist")
        # Cloudflare One as a sign-in provider (flow "access"): live only when the provider and the JWT check are both on.
        self.access_on = self.flow == "access" and self.enabled and self.cf_on
        if self.flow == "access" and self.enabled and not (self.cf_on and self.p.get("login_url") and self.p.get("hosts")):
            raise SystemExit("provider %s is enabled but cloudflare_access, login_url or hosts is missing" % provider_id)

        # Email one-time code (flow "email", #1118): in-memory hashed codes, generic answers, pluggable mailer.
        eo = ab.get("email_otp") or {}
        self.eo = eo
        self.otp, self.otp_hits = {}, {}
        self.otp_len = int(eo.get("code_length", 6))
        self.otp_ttl = int(eo.get("ttl_seconds", 600))
        self.otp_attempts = int(eo.get("max_attempts", 5))
        self.otp_addr_n, self.otp_win = int(eo.get("send_per_address", 3)), int(eo.get("send_window_seconds", 600))
        self.otp_ip_n = int(eo.get("send_per_ip", 10))
        self.email_on = self.flow == "email" and self.enabled
        if self.email_on and not eo:
            raise SystemExit("provider %s is enabled but auth_broker.email_otp is missing" % provider_id)
        self.env = env
        self.mailer = self.deliver

    # ---- email one-time code ---------------------------------------------------------------
    def otp_hash(self, sid, code):
        return hmac.new(self.secret.encode(), ("otp|%s|%s" % (sid, code)).encode(), hashlib.sha256).hexdigest()

    def _window(self, table, key, limit, now):
        h = [t for t in table.get(key, []) if now - t < self.otp_win]
        ok = len(h) < limit
        if ok:
            h.append(now)
        table[key] = h
        return ok

    def otp_request(self, address, ip):
        """(status, body). The answer never depends on the allowlist or the per-address limit."""
        if not self.email_on:
            return 404, {"error": "disabled"}
        now = time.time()
        addr = str(address or "").strip().lower()[:254]
        sid = secrets.token_urlsafe(24)
        with self.lock:
            for k in [k for k, f in self.otp.items() if f["exp"] <= now]:
                self.otp.pop(k)
            if not self._window(self.otp_hits, "ip:" + ip, self.otp_ip_n, now):
                return 429, {"error": "rate_limited"}
            if len(self.otp) >= MAX_FLOWS * 4:
                return 429, {"error": "busy"}
            send = addr in self.emails and self._window(self.otp_hits, "addr:" + addr, self.otp_addr_n, now)
            code = "%0*d" % (self.otp_len, secrets.randbelow(10 ** self.otp_len))
            # Unlisted or throttled addresses get a live-looking sid with a hash nobody knows the code for.
            self.otp[sid] = {"h": self.otp_hash(sid, code) if send else self.otp_hash(sid, secrets.token_hex(8)),
                             "exp": now + self.otp_ttl, "n": 0, "email": addr if send else ""}
        if send:
            try:
                self.mailer(addr, code)
            except Exception as e:
                print("otp delivery failed: %s" % type(e).__name__, flush=True)
        return 200, {"sid": sid, "status": "sent", "expires_in": self.otp_ttl}

    def otp_verify(self, sid, code):
        """(status, body, set_cookie). Single use; the flow dies after max_attempts wrong codes."""
        if not self.email_on:
            return 404, {"status": "disabled"}, None
        sid, code = str(sid or ""), str(code or "").strip()
        with self.lock:
            f = self.otp.get(sid)
            if not f or f["exp"] <= time.time():
                self.otp.pop(sid, None)
                return 200, {"status": "expired"}, None
            f["n"] += 1
            ok = bool(f["email"]) and code.isdigit() and len(code) == self.otp_len and hmac.compare_digest(self.otp_hash(sid, code), f["h"])
            if ok:
                self.otp.pop(sid)
            elif f["n"] >= self.otp_attempts:
                self.otp.pop(sid)
                return 200, {"status": "locked"}, None
        if not ok:
            return 200, {"status": "wrong"}, None
        return 200, {"status": "ok"}, self.set_cookie(self.make_cookie(f["email"], self.p["id"]), self.ttl)

    def deliver(self, to, code):
        """Stalwart over the mesh first, the Resend API as fallback. Raises when both fail."""
        eo, errs = self.eo, []
        subject = eo.get("subject", "Your sign-in code")
        body = "Your sign-in code is %s. It is valid for %d minutes and works once.\nIf you did not ask for it, ignore this message.\n" % (code, self.otp_ttl // 60)
        sm = eo.get("smtp") or {}
        user, pw = self.env.get(sm.get("user_env", ""), ""), self.env.get(sm.get("password_env", ""), "")
        if sm.get("host") and user and pw:
            try:
                self.send_smtp(sm, user, pw, to, subject, body)
                return "stalwart"
            except Exception as e:
                errs.append("smtp:" + type(e).__name__)
        rs = eo.get("resend") or {}
        key = self.env.get(rs.get("api_key_env", ""), "")
        if rs.get("url") and key:
            try:
                self.send_resend(rs, key, to, subject, body)
                return "resend"
            except Exception as e:
                errs.append("resend:" + type(e).__name__)
        raise RuntimeError(",".join(errs) or "no mail path configured")

    def send_smtp(self, sm, user, pw, to, subject, body):
        m = EmailMessage()
        m["From"], m["To"], m["Subject"] = sm.get("from") or user, to, subject
        m.set_content(body)
        ctx = ssl.create_default_context()
        if sm.get("allow_invalid_certs"):
            ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
        name = sm.get("tls_server_name") or sm["host"]

        class S(smtplib.SMTP_SSL):          # connect by mesh IP, verify the public hostname
            def _get_socket(self, host, port, timeout):
                return ctx.wrap_socket(socket.create_connection((host, port), timeout), server_hostname=name)
        with S(sm["host"], int(sm["port"]), timeout=15, context=ctx) as c:
            c.login(user, pw)
            c.send_message(m)

    def send_resend(self, rs, key, to, subject, body):
        req = urllib.request.Request(rs["url"], method="POST", data=json.dumps(
            {"from": rs["from"], "to": [to], "subject": subject, "text": body}).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=15) as r:
            if r.status >= 300:
                raise RuntimeError("resend status %s" % r.status)

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

    # ---- Cloudflare Access JWT (RS256) ------------------------------------------------------------
    SHA256_DI = bytes.fromhex("3031300d060960864801650304020105000420")

    def cf_load_keys(self, force=False):
        now = time.time()
        if not force and self.cf_keys and now - self.cf_keys_at < 3600:
            return
        if force and now - self.cf_keys_at < 60:      # unknown kid must not make us hammer the certs URL
            return
        st, d = self.call(self.cf.get("certs_url") or "https://%s/cdn-cgi/access/certs" % self.cf["team_domain"])
        if st != 200:
            return
        keys = {}
        for k in d.get("keys", []):
            if k.get("kty") == "RSA" and k.get("kid"):
                keys[k["kid"]] = (int.from_bytes(b64d(k["n"]), "big"), int.from_bytes(b64d(k["e"]), "big"))
        if keys:
            self.cf_keys, self.cf_keys_at = keys, now

    def cf_email(self, tok):
        """Owner email for a valid Cloudflare Access JWT, else None. Verified: RS256 signature against the
        team certs, issuer, audience, expiry, and the email against the allowlist (service tokens carry no email)."""
        if not self.cf_on or not tok or len(tok) > 8192:
            return None
        try:
            h64, p64, s64 = tok.split(".")
            hdr = json.loads(b64d(h64))
            if hdr.get("alg") != "RS256":
                return None
            kid = hdr.get("kid", "")
            self.cf_load_keys()
            if kid not in self.cf_keys:
                self.cf_load_keys(force=True)
            if kid not in self.cf_keys:
                return None
            n, e = self.cf_keys[kid]
            k = (n.bit_length() + 7) // 8
            sig = b64d(s64)
            if len(sig) != k or int.from_bytes(sig, "big") >= n:
                return None
            em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
            digest = hashlib.sha256((h64 + "." + p64).encode()).digest()
            tail = b"\x00" + self.SHA256_DI + digest
            if not hmac.compare_digest(em, b"\x00\x01" + b"\xff" * (k - len(tail) - 2) + tail):
                return None
            c = json.loads(b64d(p64))
            now = time.time()
            aud = c.get("aud")
            aud = [aud] if isinstance(aud, str) else list(aud or [])
            if c.get("iss") != "https://" + self.cf["team_domain"] or not set(aud) & set(self.cf["aud"]):
                return None
            if float(c["exp"]) <= now or float(c.get("nbf", 0)) > now + 60:
                return None
            em_ = str(c.get("email", "")).strip().lower()
            return em_ if em_ in self.emails else None
        except Exception:
            return None

    # ---- Cloudflare One sign-in (flow "access") ------------------------------------------------------
    def access_start(self, host, rd):
        """Location of the Access-protected callback, with rd made absolute and validated, or None."""
        host = (host or "").lower().split(":")[0]
        if not self.access_on or host not in self.p["hosts"]:
            return None
        rd = self.safe_rd(rd)
        if rd.startswith("/"):
            rd = "https://%s%s" % (host, rd)
        return self.p["login_url"] + "?" + urllib.parse.urlencode({"rd": rd})

    def access_callback(self, jwt_header, rd):
        """(location, set_cookie) for a valid owner Access JWT, else None. The JWT is verified in full."""
        e = self.cf_email(jwt_header) if self.access_on else None
        if not e:
            return None
        rd = self.safe_rd(rd)
        if rd.startswith("/"):
            rd = self.p["home_url"]
        return rd, self.set_cookie(self.make_cookie(e, self.p["id"]), self.ttl)

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
        if not self.web_on:
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
        q = {"client_id": self.web_cid, "redirect_uri": ru, "response_type": "code", "scope": self.w.get("scope", self.p["scope"]),
             "state": state, "code_challenge": b64e(hashlib.sha256(verifier.encode()).digest()),
             "code_challenge_method": "S256", "prompt": "select_account"}
        cookie = "%s=%s; Path=%s; Max-Age=600; Secure; HttpOnly; SameSite=Lax" % (self.STATE_COOKIE, bind, self.prefix)
        return 302, self.w["auth_url"] + "?" + urllib.parse.urlencode(q), cookie

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
        if not self.web_on:
            return 404, "Sign-in is not available.", clear
        data = {"client_id": self.web_cid, "client_secret": self.web_sec, "code": q["code"],
                "code_verifier": st["v"], "redirect_uri": st["ru"], "grant_type": "authorization_code"}
        code, d = self.call(self.w.get("token_url") or self.p["token_url"], data)
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


EMAIL_PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>Sign in with Email code</title><style>
:root{--bg:#f6f7f9;--fg:#15171a;--card:#fff;--line:#d9dde3;--acc:#2b6cb0}
@media (prefers-color-scheme:dark){:root{--bg:#101215;--fg:#e8eaed;--card:#181b20;--line:#2c3139;--acc:#7fb2ee}}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,sans-serif}
main{width:min(92vw,380px);background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px}
h1{font-size:1.15rem;margin:0 0 12px}input,button{font:inherit;width:100%;box-sizing:border-box;padding:10px;margin:6px 0;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}
button{background:var(--acc);color:#fff;border:0;cursor:pointer}a{color:var(--acc)}#st{font-size:.85rem;opacity:.85;min-height:1.2em}</style></head><body><main>
<h1>Sign in with Email code</h1>
<form id="f1"><label>Email address<input id="em" type="email" autocomplete="email" required></label><button type="submit">Send code</button></form>
<form id="f2" hidden><label>6-digit code<input id="cd" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required></label><button type="submit">Sign in</button></form>
<div id="st" role="status"></div></main>
<script>(function(){
var P="__PREFIX__",RD=new URLSearchParams(location.search).get("rd")||"/",$=function(i){return document.getElementById(i)},sid="";
function post(u,b){return fetch(P+u,{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json","X-Requested-With":"sso"},body:JSON.stringify(b)}).then(function(r){return r.json().then(function(j){j._s=r.status;return j})})}
$("f1").onsubmit=function(e){e.preventDefault();$("st").textContent="Sending…";
 post("/request",{email:$("em").value}).then(function(d){
  if(!d.sid){$("st").textContent=d._s===429?"Too many requests. Try later.":"Could not start sign-in.";return}
  sid=d.sid;$("f1").hidden=true;$("f2").hidden=false;$("cd").focus();
  $("st").textContent="If the address is allowed, a code was sent. It is valid for 10 minutes."}).catch(function(){$("st").textContent="Network error."})};
$("f2").onsubmit=function(e){e.preventDefault();
 post("/verify",{sid:sid,code:$("cd").value,rd:RD}).then(function(r){
  if(r.status==="ok"){$("st").textContent="Signed in.";location.href=r.rd||"/";return}
  if(r.status==="wrong"){$("st").textContent="Wrong code.";return}
  $("st").innerHTML='Code expired or locked. <a href="'+P+'/start?rd='+encodeURIComponent(RD)+'">Start again</a>';$("f2").hidden=true
 }).catch(function(){$("st").textContent="Network error."})};
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
            if op == "/cf-auth":
                e = b.cf_email(self.headers.get("Cf-Access-Jwt-Assertion"))
                return self.send(202, b"", "text/plain", [("X-Auth-Request-Email", e)]) if e else self.send(401, b"", "text/plain")
            if b.flow == "access" and op in ("/start", "/callback"):
                qs = urllib.parse.parse_qs(u.query)
                rd = (qs.get("rd") or [""])[0]
                if op == "/start":
                    loc = b.access_start(self.headers.get("Host"), rd)
                    return self.send(302, b"", "text/plain", [("Location", loc)]) if loc else self.send(404, "<p>Sign-in is not available.</p>", "text/html; charset=utf-8")
                out = b.access_callback(self.headers.get("Cf-Access-Jwt-Assertion"), rd)
                if not out:
                    return self.send(401, "<p>Cloudflare One sign-in was not verified.</p>", "text/html; charset=utf-8")
                return self.send(302, b"", "text/plain", [("Location", out[0]), ("Set-Cookie", out[1])])
            device_forced = op == "/start" and (urllib.parse.parse_qs(u.query).get("flow") or [""])[0] == "device" and b.flow == "device"
            if b.web_on and op in ("/start", "/callback") and not device_forced:
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
            if op == "/start" and b.flow == "email":
                if not b.email_on:
                    return self.send(404, "<p>This sign-in method is not enabled.</p>", "text/html; charset=utf-8")
                return self.send(200, EMAIL_PAGE.replace("__PREFIX__", b.prefix), "text/html; charset=utf-8", [("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'")])
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
            if b.flow == "email":
                if op == "/request":
                    code, d = b.otp_request(body.get("email", ""), self.ip())
                    return self.send(code, d)
                if op == "/verify":
                    code, d, cookie = b.otp_verify(body.get("sid", ""), body.get("code", ""))
                    if cookie:
                        d["rd"] = b.safe_rd(body.get("rd", ""))
                    return self.send(code, d, extra=[("Set-Cookie", cookie)] if cookie else None)
                return self.send(404, {"error": "not_found"})
            if b.flow in ("web", "access"):
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
