"""introspect-proxy x token engine: revocation reaches the edge within the cache window; fail modes."""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "code"))
os.environ.setdefault("TOKENS_VERIFY_URL", "http://engine.invalid/v1/verify")
os.environ.setdefault("TOKENS_VERIFY_SECRET", "s")
import main  # noqa: E402


class FakeEngine:
    """Stands in for tokens-api: a live set of active tokens plus a switch to make it unreachable."""

    def __init__(self):
        self.active, self.down, self.calls = set(), False, 0

    def ask(self, token, host, adopt=None):
        self.calls += 1
        if self.down:
            raise OSError("down")
        return {"active": token in self.active, "id": "tk_1", "name": "ci", "scopes": ["a"], "reason": "revoked"}


@pytest.fixture()
def eng(monkeypatch):
    e, now = FakeEngine(), [1000.0]
    main._tokens_cache.clear()
    main._engine_down_until[0] = 0.0

    import io
    import json

    class Resp(io.BytesIO):
        status = 200

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_open(req, timeout=0):
        body = json.loads(req.data)
        return Resp(json.dumps(e.ask(body["token"], body["host"], body.get("adopt"))).encode())

    monkeypatch.setattr("urllib.request.urlopen", fake_open)
    monkeypatch.setattr(main.time, "time", lambda: now[0])
    return e, now


def call(token):
    with main.app.test_request_context("/auth", headers={"Authorization": "Bearer " + token}):
        return main.auth()


def test_fleet_token_active_then_revoked_within_cache_window(eng):
    e, now = eng
    e.active.add("ft_abc")
    assert call("ft_abc").status_code == 200
    e.active.clear()                       # owner revokes
    assert call("ft_abc").status_code == 200   # still inside the cache window
    now[0] += main.TOKENS_CACHE_TTL + 1
    assert call("ft_abc").status_code == 401   # rejected once the window passes
    assert main.TOKENS_CACHE_TTL <= 60


def test_unknown_fleet_token_rejected(eng):
    assert call("ft_nope").status_code == 401


def test_fleet_token_fails_closed_when_engine_down(eng):
    e, now = eng
    e.down = True
    assert call("ft_abc").status_code == 503


def test_stale_answer_serves_briefly_then_closes(eng):
    e, now = eng
    e.active.add("ft_abc")
    assert call("ft_abc").status_code == 200
    e.down = True
    now[0] += main.TOKENS_CACHE_TTL + 1
    assert call("ft_abc").status_code == 200       # engine blip: last answer
    now[0] += main.TOKENS_STALE_MAX
    assert call("ft_abc").status_code == 503       # too old: closed


def test_headers_carry_name_and_scopes(eng):
    e, _ = eng
    e.active.add("ft_abc")
    r = call("ft_abc")
    assert r.headers["X-Auth-User"] == "ci" and r.headers["X-Auth-Scopes"] == "a"


def test_engine_off_keeps_old_behaviour(monkeypatch):
    monkeypatch.setattr(main, "TOKENS_VERIFY_URL", "")
    assert call("ft_abc").status_code == 401


class _Key:
    key = "k"


class _Jwks:
    def get_signing_key_from_jwt(self, t):
        return _Key()


def _jwt_ok(monkeypatch):
    monkeypatch.setattr(main, "get_jwks_client", lambda: _Jwks())
    monkeypatch.setattr(main.jwt, "decode", lambda *a, **k: {"client_id": "dagu-cc", "sub": "d", "exp": 2**31, "scp": [main.REQUIRED_SCOPE]})


def test_authelia_jwt_revoked_in_engine_is_rejected_after_window(eng, monkeypatch):
    e, now = eng
    _jwt_ok(monkeypatch)
    e.active.add("a.b.c")
    assert call("a.b.c").status_code == 200
    e.active.clear()                        # owner revokes the adopted JWT
    now[0] += main.TOKENS_CACHE_TTL + 1
    assert call("a.b.c").status_code == 401


def test_authelia_jwt_survives_engine_outage(eng, monkeypatch):
    e, now = eng
    _jwt_ok(monkeypatch)
    e.down = True
    assert call("a.b.c").status_code == 200  # signature alone, as before the engine existed


def test_dead_engine_is_not_redialled_for_a_few_seconds(eng):
    e, now = eng
    main._engine_down_until[0] = 0.0
    e.down = True
    assert call("ft_abc").status_code == 503
    n = e.calls
    assert call("ft_other").status_code == 503
    assert e.calls == n                      # breaker open: no new dial
    now[0] += main.TOKENS_BREAKER_S + 1
    e.down = False
    e.active.add("ft_other")
    assert call("ft_other").status_code == 200
