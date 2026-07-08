#!/usr/bin/env python3
"""
Table-driven tests for the PURE notify-broker decision function.

No framework, no network, no clock, no disk. Every case feeds a synthetic event
+ the real emitted policy (build-notify.json) + a controlled `now_ts` into
decide(), and asserts the resulting (actions, new_state).

Run:  python3 test_notify_broker.py
Exit: 0 = all pass, 1 = failure.

Covers: severity mapping, category resolution (explicit / unit glob / default),
routing (ntfy/matrix/email per severity), dedup, flap, escalation warn→crit→page,
ack reset, and recovery pairing.
"""
import json
import sys
import importlib.util
from pathlib import Path

# The broker file is hyphenated (notify-broker.py) — load it by path.
_spec = importlib.util.spec_from_file_location(
    "notify_broker", str(Path(__file__).with_name("notify-broker.py")))
nb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nb)


# ── load real policy (symlink → 2_configs/dist/build-notify.json) ──────────
def _load_policy():
    for cand in ("./build-notify.json", "../build-notify.json"):
        p = Path(cand)
        if p.exists():
            return json.loads(p.read_text())
    # minimal inline fallback so the test is runnable standalone
    return {
        "severity_map": {"default": "info", "by_class": {
            "load_shed": "crit", "psi_high": "warn", "deploy_failed": "page",
            "recovered": "info"}},
        "category_by_unit": {"load-shedder": "resources", "caddy": "endpoints", "wg-quick*": "mesh"},
        "routing": {"rules": [
            {"match": "category:resources", "channels": {
                "info": [{"kind": "ntfy", "topic": "health_resources"}],
                "warn": [{"kind": "ntfy", "topic": "health_resources"}],
                "crit": [{"kind": "ntfy", "topic": "health_resources"}, {"kind": "matrix"}],
                "page": [{"kind": "ntfy", "topic": "health_resources"}, {"kind": "matrix"}, {"kind": "email"}]}},
            {"match": "category:mesh", "channels": {
                "page": [{"kind": "ntfy", "topic": "health_mesh"}, {"kind": "matrix"}, {"kind": "email"}]}},
            {"match": "default", "channels": {
                "info": [{"kind": "ntfy", "topic": "health_resources"}],
                "crit": [{"kind": "ntfy", "topic": "health_resources"}, {"kind": "matrix"}]}}]},
        "dedup": {"window_secs": 300, "by_key": {}},
        "flap": {"enabled": True, "transitions": 4, "window_secs": 900, "mute_after_flap_secs": 1800},
        "escalation": {"enabled": True, "warn_to_crit_secs": 900, "crit_to_page_secs": 1800},
        "recovery": {"enabled": True, "notice_severity": "info"},
    }


POLICY = _load_policy()

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


def kinds(actions):
    return [a["kind"] for a in actions]


def notes(actions):
    return [a["note"] for a in actions]


# ═══════════════════════════════════════════════════════════════════════════
# 1. severity + category resolution
# ═══════════════════════════════════════════════════════════════════════════
def test_severity_and_category():
    print("severity_and_category:")
    ev = {"class": "load_shed", "key": "k1", "unit": "load-shedder", "title": "t"}
    assert nb.resolve_severity(ev, POLICY) == "crit"
    assert nb.resolve_category(ev, POLICY) == "resources"
    check("class load_shed -> crit/resources", True)

    # explicit severity wins over class
    ev2 = {"class": "psi_high", "severity": "page", "key": "k", "title": "t"}
    check("explicit severity wins", nb.resolve_severity(ev2, POLICY) == "page")

    # unit glob resolution
    ev3 = {"class": "x", "unit": "wg-quick-wg0", "key": "k", "title": "t"}
    check("unit glob wg-quick* -> mesh", nb.resolve_category(ev3, POLICY) == "mesh")

    # unknown -> default category + default severity
    ev4 = {"class": "totally_unknown", "key": "k", "title": "t"}
    check("unknown class -> default severity", nb.resolve_severity(ev4, POLICY) == "info")
    check("no category -> default", nb.resolve_category(ev4, POLICY) == "default")


# ═══════════════════════════════════════════════════════════════════════════
# 2. routing — crit gets ntfy+matrix, page gets ntfy+matrix+email
# ═══════════════════════════════════════════════════════════════════════════
def test_routing():
    print("routing:")
    ev = {"class": "load_shed", "key": "r1", "category": "resources", "title": "shed", "body": "b"}
    actions, _ = nb.decide(ev, POLICY, {}, now_ts=1000)
    check("crit -> ntfy+matrix", kinds(actions) == ["ntfy", "matrix"], kinds(actions))

    ev2 = {"class": "deploy_failed", "key": "r2", "category": "resources", "title": "p", "body": "b"}
    actions2, _ = nb.decide(ev2, POLICY, {}, now_ts=1000)
    check("page -> ntfy+matrix+email", kinds(actions2) == ["ntfy", "matrix", "email"], kinds(actions2))
    check("page ntfy topic = health_resources",
          actions2[0]["topic"] == "health_resources", actions2[0].get("topic"))


# ═══════════════════════════════════════════════════════════════════════════
# 3. dedup — identical (key,severity) within window suppressed
# ═══════════════════════════════════════════════════════════════════════════
def test_dedup():
    print("dedup:")
    ev = {"class": "load_shed", "key": "d1", "category": "resources", "title": "t", "body": "b"}
    a1, s1 = nb.decide(ev, POLICY, {}, now_ts=1000)
    check("first fires", len(a1) > 0)
    a2, s2 = nb.decide(ev, POLICY, s1, now_ts=1100)  # +100s < 300 window
    check("repeat within window suppressed", len(a2) == 0, kinds(a2))
    check("suppressed_count incremented",
          s2["keys"]["d1"].get("suppressed_count", 0) == 1)
    a3, s3 = nb.decide(ev, POLICY, s2, now_ts=1500)  # +500s > 300 window
    check("fires again after window", len(a3) > 0, kinds(a3))


# ═══════════════════════════════════════════════════════════════════════════
# 4. escalation — warn unacked ages to crit, then page
# ═══════════════════════════════════════════════════════════════════════════
def test_escalation():
    print("escalation:")
    ev = {"class": "psi_high", "key": "e1", "category": "resources", "title": "t", "body": "b"}
    a1, s1 = nb.decide(ev, POLICY, {}, now_ts=0)
    check("initial warn", a1 and a1[0]["severity"] == "warn", a1)

    # +901s (past warn_to_crit 900) — must escalate to crit.
    # Use a fresh severity higher than dedup so it emits; escalation raises severity.
    a2, s2 = nb.decide(ev, POLICY, s1, now_ts=901)
    check("warn -> crit at 900s", a2 and a2[0]["severity"] == "crit", [x["severity"] for x in a2])
    check("crit routes matrix too", "matrix" in kinds(a2), kinds(a2))

    # +1801s (past crit_to_page 1800 from first_alert) — escalate to page.
    a3, s3 = nb.decide(ev, POLICY, s2, now_ts=1801)
    check("crit -> page at 1800s", a3 and a3[0]["severity"] == "page", [x["severity"] for x in a3])
    check("page routes email", "email" in kinds(a3), kinds(a3))


# ═══════════════════════════════════════════════════════════════════════════
# 5. ack — resets escalation, no new notification
# ═══════════════════════════════════════════════════════════════════════════
def test_ack():
    print("ack:")
    ev = {"class": "psi_high", "key": "a1", "category": "resources", "title": "t", "body": "b"}
    _, s1 = nb.decide(ev, POLICY, {}, now_ts=0)
    ack_ev = {"key": "a1", "ack": True}
    a2, s2 = nb.decide(ack_ev, POLICY, s1, now_ts=10)
    check("ack emits nothing", len(a2) == 0)
    check("ack sets acked", s2["keys"]["a1"].get("acked") is True)
    # after ack, aged event does NOT escalate (acked short-circuits escalation)
    a3, s3 = nb.decide(ev, POLICY, s2, now_ts=2000)
    sev = a3[0]["severity"] if a3 else None
    check("acked does not escalate to page", sev != "page", sev)


# ═══════════════════════════════════════════════════════════════════════════
# 6. recovery — paired resolved notice, then key cleared
# ═══════════════════════════════════════════════════════════════════════════
def test_recovery():
    print("recovery:")
    ev = {"class": "load_shed", "key": "rec1", "category": "resources", "title": "shed", "body": "b"}
    _, s1 = nb.decide(ev, POLICY, {}, now_ts=1000)
    rec = {"key": "rec1", "category": "resources", "recovered": True, "title": "shed", "body": "clear"}
    a2, s2 = nb.decide(rec, POLICY, s1, now_ts=1100)
    check("recovery emits resolved notice", any(n == "recovery" for n in notes(a2)), notes(a2))
    check("resolved title prefixed", a2 and a2[0]["title"].startswith("[RESOLVED]"), a2)
    check("active_severity cleared", s2["keys"]["rec1"].get("active_severity") is None)

    # recovery for a non-alerting key = no notice
    a3, s3 = nb.decide(rec, POLICY, {"keys": {}}, now_ts=1200)
    check("recovery on unknown key silent", len(a3) == 0, kinds(a3))


# ═══════════════════════════════════════════════════════════════════════════
# 7. flap — N transitions within window emit single flapping notice + mute
# ═══════════════════════════════════════════════════════════════════════════
def test_flap():
    print("flap:")
    key = "f1"
    cat = "resources"
    state = {}
    t = 0
    # Alternate alert/recovery quickly to rack up transitions.
    # transitions=4 in policy → 4th transition triggers flapping.
    saw_flap = False
    for i in range(8):
        if i % 2 == 0:
            ev = {"class": "load_shed", "key": key, "category": cat, "title": "t", "body": "b"}
        else:
            ev = {"key": key, "category": cat, "recovered": True, "title": "t", "body": "b"}
        t += 30  # 30s apart, well inside 900s window
        actions, state = nb.decide(ev, POLICY, state, now_ts=t)
        if any(n == "flap" for n in notes(actions)):
            saw_flap = True
    check("flapping notice emitted", saw_flap)
    # after flap, muted_until set in the future
    muted = state["keys"][key].get("flap_muted_until", 0)
    check("flap mute window set", muted > t, muted)


def main():
    for fn in (test_severity_and_category, test_routing, test_dedup,
               test_escalation, test_ack, test_recovery, test_flap):
        fn()
    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
