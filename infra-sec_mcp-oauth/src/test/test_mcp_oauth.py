"""Unit tests: registration, PKCE, token exchange, refresh, introspection.

Run: python3 -m pytest -q infra-sec_mcp-oauth/src/test  (needs flask, pytest)
Also covers the introspect-proxy hook end to end (opaque token -> /auth 200).
"""
import base64
import hashlib
import importlib
import os
import secrets
import sys
import tempfile
from urllib.parse import parse_qs, urlsplit

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
CODE = os.path.join(HERE, "..", "code")
IPROXY = os.path.join(HERE, "..", "..", "..", "infra-sec_introspect-proxy", "src", "code")
CB = "https://claude.ai/api/mcp/auth_callback"


@pytest.fixture()
def srv(monkeypatch):
    d = tempfile.mkdtemp()
    monkeypatch.setenv("DB_PATH", os.path.join(d, "t.sqlite3"))
    monkeypatch.setenv("INTROSPECT_SECRET", "s3cret")
    monkeypatch.setenv("ALLOWED_USERS", "diego")
    monkeypatch.setenv("FORM_SECRET", "f" * 32)
    sys.path.insert(0, CODE)
    sys.modules.pop("main", None)
    m = importlib.import_module("main")
    sys.path.remove(CODE)
    sys.modules.pop("main", None)
    m.app.testing = True
    return m


def pkce():
    v = secrets.token_urlsafe(48)
    c = base64.urlsafe_b64encode(hashlib.sha256(v.encode()).digest()).rstrip(b"=").decode()
    return v, c


def register(c, uris=(CB,), **kw):
    return c.post("/register", json={"redirect_uris": list(uris), "client_name": "Claude", **kw})


def get_code(m, c, cid, challenge, user="diego", state="xyz", ruri=CB):
    args = {"response_type": "code", "client_id": cid, "redirect_uri": ruri, "state": state,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "resource": "https://mcp.diegonmarcos.com/cloud-infra/mcp"}
    r = c.get("/authorize", query_string=args, headers={"Remote-User": user})
    assert r.status_code == 200, r.data
    # Re-post the signed consent form exactly as the browser would.
    import re
    form = dict(re.findall(r'name="([^"]+)" value="([^"]*)"', r.data.decode()))
    import html
    form = {k: html.unescape(v) for k, v in form.items()}
    form["decision"] = "approve"
    r = c.post("/authorize", data=form, headers={"Remote-User": user})
    assert r.status_code == 302, r.data
    loc = urlsplit(r.headers["Location"])
    qs = parse_qs(loc.query)
    assert qs["state"] == [state]
    return qs["code"][0]


# ── discovery ──
def test_metadata(srv):
    c = srv.app.test_client()
    as_ = c.get("/.well-known/oauth-authorization-server").get_json()
    assert as_["code_challenge_methods_supported"] == ["S256"]
    assert as_["registration_endpoint"].endswith("/register")
    pr = c.get("/.well-known/oauth-protected-resource/cloud-infra/mcp").get_json()
    assert pr["resource"] == "https://mcp.diegonmarcos.com/cloud-infra/mcp"
    assert pr["authorization_servers"] == ["https://mcp.diegonmarcos.com"]
    assert c.get("/cloud-infra/.well-known/oauth-protected-resource").status_code == 200
    assert c.get("/.well-known/oauth-protected-resource").get_json()["resource"] == "https://mcp.diegonmarcos.com"


# ── registration ──
def test_register_ok_and_localhost(srv):
    c = srv.app.test_client()
    r = register(c)
    assert r.status_code == 201
    j = r.get_json()
    assert j["client_id"].startswith("mcpc_") and "client_secret" not in j
    assert register(c, uris=("http://localhost:33418/callback", "http://127.0.0.1:5000/cb")).status_code == 201
    assert register(c, uris=("https://claude.com/api/mcp/auth_callback",)).status_code == 201


@pytest.mark.parametrize("uri", [
    "https://evil.example/cb", "https://claude.ai.evil.com/api/mcp/auth_callback",
    "https://claude.ai/other", "http://claude.ai/api/mcp/auth_callback",
    "http://localhost.evil.com/cb", "https://localhost/cb", "javascript:alert(1)",
])
def test_register_rejects_redirect(srv, uri):
    r = register(srv.app.test_client(), uris=(uri,))
    assert r.status_code == 400 and r.get_json()["error"] == "invalid_redirect_uri"


def test_register_confidential_client(srv):
    j = register(srv.app.test_client(), token_endpoint_auth_method="client_secret_post").get_json()
    assert j["client_secret"]


def test_register_bad_body(srv):
    c = srv.app.test_client()
    assert c.post("/register", data="x").status_code == 400
    assert register(c, grant_types=["client_credentials"]).status_code == 400


# ── authorize ──
def test_authorize_requires_authelia_session(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    _, ch = pkce()
    args = {"response_type": "code", "client_id": cid, "redirect_uri": CB,
            "code_challenge": ch, "code_challenge_method": "S256"}
    assert c.get("/authorize", query_string=args).status_code == 401
    assert c.get("/authorize", query_string=args, headers={"Remote-User": "mallory"}).status_code == 403


def test_authorize_requires_s256(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    args = {"response_type": "code", "client_id": cid, "redirect_uri": CB, "state": "s",
            "code_challenge": "a" * 43, "code_challenge_method": "plain"}
    r = c.get("/authorize", query_string=args, headers={"Remote-User": "diego"})
    assert r.status_code == 302 and "error=invalid_request" in r.headers["Location"]
    del args["code_challenge"]
    args["code_challenge_method"] = "S256"
    r = c.get("/authorize", query_string=args, headers={"Remote-User": "diego"})
    assert "error=invalid_request" in r.headers["Location"]


def test_authorize_unregistered_redirect_never_redirects(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    _, ch = pkce()
    r = c.get("/authorize", headers={"Remote-User": "diego"}, query_string={
        "response_type": "code", "client_id": cid, "redirect_uri": "https://claude.com/api/mcp/auth_callback",
        "code_challenge": ch, "code_challenge_method": "S256"})
    assert r.status_code == 400 and "Location" not in r.headers


def test_authorize_tampered_form(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    _, ch = pkce()
    r = c.post("/authorize", headers={"Remote-User": "diego"}, data={
        "client_id": cid, "redirect_uri": CB, "code_challenge": ch, "sub": "diego",
        "exp": "9999999999", "sig": "0" * 64, "decision": "approve"})
    assert r.status_code == 400


def test_deny(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    _, ch = pkce()
    r = c.get("/authorize", headers={"Remote-User": "diego"}, query_string={
        "response_type": "code", "client_id": cid, "redirect_uri": CB, "state": "q",
        "code_challenge": ch, "code_challenge_method": "S256"})
    import html, re
    form = {k: html.unescape(v) for k, v in re.findall(r'name="([^"]+)" value="([^"]*)"', r.data.decode())}
    form["decision"] = "deny"
    r = c.post("/authorize", data=form, headers={"Remote-User": "diego"})
    assert "error=access_denied" in r.headers["Location"]


# ── token exchange + PKCE ──
def test_full_flow_and_introspection(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    v, ch = pkce()
    code = get_code(srv, c, cid, ch)
    r = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": cid,
                               "redirect_uri": CB, "code_verifier": v})
    assert r.status_code == 200, r.data
    tok = r.get_json()
    assert tok["access_token"].startswith("mcpat_") and tok["refresh_token"].startswith("mcprt_")
    assert r.headers["Cache-Control"] == "no-store"

    # code is single-use
    r2 = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": cid,
                                "redirect_uri": CB, "code_verifier": v})
    assert r2.get_json()["error"] == "invalid_grant"

    # introspection
    hd = {"X-Introspect-Secret": "s3cret"}
    j = c.post("/introspect", data={"token": tok["access_token"]}, headers=hd).get_json()
    assert j["active"] and j["sub"] == "diego" and j["client_id"] == cid
    assert j["aud"] == "https://mcp.diegonmarcos.com/cloud-infra/mcp"
    assert c.post("/introspect", data={"token": tok["refresh_token"]}, headers=hd).get_json() == {"active": False}
    assert c.post("/introspect", data={"token": "mcpat_nope"}, headers=hd).get_json() == {"active": False}
    assert c.post("/introspect", data={"token": tok["access_token"]}).status_code == 401

    # refresh rotates and revokes the old pair
    r = c.post("/token", data={"grant_type": "refresh_token", "refresh_token": tok["refresh_token"], "client_id": cid})
    assert r.status_code == 200
    tok2 = r.get_json()
    assert c.post("/introspect", data={"token": tok["access_token"]}, headers=hd).get_json()["active"] is False
    assert c.post("/introspect", data={"token": tok2["access_token"]}, headers=hd).get_json()["active"] is True
    r = c.post("/token", data={"grant_type": "refresh_token", "refresh_token": tok["refresh_token"], "client_id": cid})
    assert r.get_json()["error"] == "invalid_grant"


def test_pkce_wrong_verifier(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    _, ch = pkce()
    code = get_code(srv, c, cid, ch)
    r = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": cid,
                               "redirect_uri": CB, "code_verifier": secrets.token_urlsafe(48)})
    assert r.status_code == 400 and r.get_json()["error"] == "invalid_grant"


def test_code_bound_to_client(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    other = register(c).get_json()["client_id"]
    v, ch = pkce()
    code = get_code(srv, c, cid, ch)
    r = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": other,
                               "redirect_uri": CB, "code_verifier": v})
    assert r.get_json()["error"] == "invalid_grant"


def test_confidential_client_needs_secret(srv):
    c = srv.app.test_client()
    j = register(c, token_endpoint_auth_method="client_secret_post").get_json()
    v, ch = pkce()
    code = get_code(srv, c, j["client_id"], ch)
    base = {"grant_type": "authorization_code", "code": code, "client_id": j["client_id"],
            "redirect_uri": CB, "code_verifier": v}
    assert c.post("/token", data=base).status_code == 401
    auth = base64.b64encode(f'{j["client_id"]}:{j["client_secret"]}'.encode()).decode()
    assert c.post("/token", data=base, headers={"Authorization": "Basic " + auth}).status_code == 200


def test_expired_access_token_inactive(srv, monkeypatch):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    v, ch = pkce()
    code = get_code(srv, c, cid, ch)
    at = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": cid,
                                "redirect_uri": CB, "code_verifier": v}).get_json()["access_token"]
    real = srv.now
    monkeypatch.setattr(srv, "now", lambda: real() + srv.ACCESS_TTL + 1)
    assert srv.lookup_access(at) is None


def test_unsupported_grant(srv):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    assert c.post("/token", data={"grant_type": "password", "client_id": cid}).get_json()["error"] == "unsupported_grant_type"


# ── introspect-proxy hook ──
def test_introspect_proxy_accepts_minted_token(srv, monkeypatch):
    c = srv.app.test_client()
    cid = register(c).get_json()["client_id"]
    v, ch = pkce()
    code = get_code(srv, c, cid, ch)
    at = c.post("/token", data={"grant_type": "authorization_code", "code": code, "client_id": cid,
                                "redirect_uri": CB, "code_verifier": v}).get_json()["access_token"]

    monkeypatch.setenv("MCP_OAUTH_INTROSPECT_URL", "http://mcp-oauth.test/introspect")
    monkeypatch.setenv("MCP_OAUTH_INTROSPECT_SECRET", "s3cret")
    sys.path.insert(0, IPROXY)
    sys.modules.pop("main", None)
    ip = importlib.import_module("main")
    sys.path.remove(IPROXY)
    sys.modules.pop("main", None)

    # Route the proxy's urllib call into the oauth app's test client.
    import io, json, urllib.request

    class R(io.BytesIO):
        def __enter__(self): return self
        def __exit__(self, *a): pass

    def fake_urlopen(req, timeout=None):
        resp = c.post("/introspect", data=req.data, headers=dict(req.header_items()),
                      content_type="application/x-www-form-urlencoded")
        if resp.status_code != 200:
            raise OSError(resp.status_code)
        return R(resp.data)

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    pc = ip.app.test_client()
    r = pc.get("/auth", headers={"Authorization": "Bearer " + at})
    assert r.status_code == 200 and r.headers["X-Auth-User"] == "diego"
    assert pc.get("/auth", headers={"Authorization": "Bearer mcpat_forged"}).status_code == 401

    # Feature off -> opaque tokens are refused, never sent to the JWKS path.
    ip.MCP_OAUTH_INTROSPECT_URL = ""
    ip._mcp_cache.clear()
    assert pc.get("/auth", headers={"Authorization": "Bearer " + at}).status_code == 401
