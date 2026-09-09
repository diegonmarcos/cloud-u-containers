#!/usr/bin/env python3
"""
Contract test for the ANONYMOUS ON-MESH READ PATH that phone clients poll.

Run:  python3 test_read_path.py        (must be on the WireGuard mesh)

Unlike test_notify_broker.py / test_notify_digest.py, which are pure and do no
I/O, this one talks to the live server on purpose: what it pins is not a
function's behaviour but the SERVER'S ANSWER, and that is exactly the thing a
config edit elsewhere can silently take away.

## Why this exists
Every ntfy channel card in the Cloud SuperApp read "unavailable HTTP 401" for
as long as its poll went to the PUBLIC hostname. Two facts, both server-side,
both invisible from the app's source, decided that:

  1. rss.diegonmarcos.com is wg_only AND gated. The mesh only gets a client to
     Caddy; Caddy then demands one of three credentials (JWT bearer, tk_ token,
     Authelia cookie -- see infra-sec_caddy/src/caddyfile.nix::mkNtfyBlock).
     Reachability is not authorization, and 401 was the gate working.
  2. The ntfy container itself grants what a read needs without any credential
     (auth-default-access: read-write, templates/server.yml.tpl), so the origin
     on the mesh is an AUTHORIZED path, not a bypass of the gate. The same
     judgement is already written down for the /feed* routes as
     feed_auth: "none".

If someone flips auth-default-access to deny-all, adds a topic ACL, moves the
port, or puts the gate in front of the origin too, the app goes back to a wall
of grey "unavailable" cards and nothing on the server side fails first. This
test fails first.

It also pins the `since` UNIT. ntfy accepts s/m/h, a Unix timestamp, a message
id or `all` -- `d` is none of them and answers HTTP 400 code 40008. Two client
call sites shipped `since=7d` / `since=30d` and got that 400 the moment the 401
in front of it was fixed, so the unit is part of the contract, not a detail.

No credential is sent by construction: urllib adds no Authorization header.
That matters -- curl in this fleet may inject one, and a probe that seems to
succeed anonymously can be silently authenticated.
"""
import json
import sys
import urllib.error
import urllib.request

# The origin the app's NtfyCatalog.readBaseUrl() falls back to, and the topic
# every fleet device is told to look at when it is stranded.
ORIGIN = "http://10.0.0.6:8090"
TOPIC = "fleet_advisory"
TIMEOUT = 10

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}  {detail}")


def get(url):
    """(status, content_type, body) for an anonymous GET. HTTPError is an
    answer, not a crash -- a 401/403 is precisely what this test looks for."""
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read().decode("utf-8", "replace")


def test_anonymous_read_is_authorized():
    print("anonymous read on the mesh origin:")
    status, ctype, body = get(f"{ORIGIN}/{TOPIC}/json?poll=1&since=168h")
    check("answers 200 with no credential", status == 200, f"got {status}")
    check("answers ndjson, not an HTML login page", "json" in ctype.lower(), f"got '{ctype}'")
    # A poll of a topic nobody published to is legitimately empty, so an empty
    # body is not a failure -- but every line present must be a real envelope.
    lines = [ln for ln in body.splitlines() if ln.strip()]
    parsed = [json.loads(ln) for ln in lines] if status == 200 else []
    check("every line parses as an ntfy envelope for this topic",
          all(m.get("topic") == TOPIC for m in parsed),
          f"{len(parsed)} lines, topics={ {m.get('topic') for m in parsed} }")


def test_since_unit_is_hours_not_days():
    print("since parameter unit:")
    status, _, body = get(f"{ORIGIN}/{TOPIC}/json?poll=1&since=168h")
    check("hours accepted", status == 200, f"got {status}")
    status, _, body = get(f"{ORIGIN}/{TOPIC}/json?poll=1&since=7d")
    # Pinned as a REJECTION: if a future ntfy starts accepting `d` this test
    # goes red and someone re-reads the client comments rather than finding out
    # from a user that the cards went grey again.
    check("days still rejected -- clients must send hours", status == 400, f"got {status}")
    check("rejection is ntfy's own 40008, not an edge error",
          '"code":40008' in body.replace(" ", ""), body[:120])


def test_public_edge_still_demands_a_credential():
    print("public edge gate (must NOT have been opened):")
    try:
        status, _, _ = get("https://rss.diegonmarcos.com/{}/json?poll=1&since=168h".format(TOPIC))
    except Exception as e:  # DNS/TLS failure off-mesh is not what we assert here
        print(f"  skip public-edge probe ({type(e).__name__}) -- run from the mesh")
        return
    # 401 (no Accept: text/html) and 302 (browser-shaped) are the same verdict:
    # refused for lack of a credential. Either is the gate doing its job.
    check("anonymous request is refused, not served",
          status in (401, 302, 403), f"got {status} -- the gate may have been opened")


if __name__ == "__main__":
    test_anonymous_read_is_authorized()
    test_since_unit_is_hours_not_days()
    test_public_edge_still_demands_a_credential()
    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)
