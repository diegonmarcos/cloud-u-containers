#!/usr/bin/env python3
"""
Table-driven tests for the PURE digest summarize() function. No I/O.
Run:  python3 test_notify_digest.py
"""
import sys
import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "notify_digest", str(Path(__file__).with_name("notify-digest.py")))
nd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(nd)

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


def test_all_green():
    print("all_green:")
    recs = [{"ts": 100, "service": "maddy", "state": "green"},
            {"ts": 100, "service": "caddy", "state": "green"}]
    d = nd.summarize(recs, now_ts=1000)
    check("overall GREEN", d["stats"]["overall"] == "GREEN", d["stats"]["overall"])
    check("2 green", d["stats"]["green_count"] == 2)
    check("no incidents", d["stats"]["incidents"] == 0)
    check("title tagged GREEN", d["title"].startswith("[GREEN]"), d["title"])


def test_incident_and_down():
    print("incident_and_down:")
    # maddy goes green -> red -> green -> red across the window (2 incidents)
    recs = [
        {"ts": 10, "service": "maddy", "state": "green"},
        {"ts": 20, "service": "maddy", "state": "red", "detail": "OOM"},
        {"ts": 30, "service": "maddy", "state": "green"},
        {"ts": 40, "service": "maddy", "state": "red", "detail": "swap thrash"},
        {"ts": 50, "service": "caddy", "state": "yellow"},
    ]
    d = nd.summarize(recs, now_ts=1000)
    check("overall RED (maddy last=red)", d["stats"]["overall"] == "RED", d["stats"]["overall"])
    check("2 incidents (green->red twice)", d["stats"]["incidents"] == 2, d["stats"]["incidents"])
    check("maddy in reds_now", "maddy" in d["stats"]["reds_now"], d["stats"]["reds_now"])
    check("caddy degraded", "caddy" in d["stats"]["yellows_now"], d["stats"]["yellows_now"])
    check("incident detail in body", "swap thrash" in d["body"], d["body"])


def test_degraded_only():
    print("degraded_only:")
    recs = [{"ts": 10, "service": "photoprism", "state": "stale"},
            {"ts": 10, "service": "gitea", "state": "green"}]
    d = nd.summarize(recs, now_ts=1000)
    check("overall YELLOW", d["stats"]["overall"] == "YELLOW", d["stats"]["overall"])
    check("photoprism degraded", "photoprism" in d["stats"]["yellows_now"])


def test_weekly_window_label():
    print("weekly_window_label:")
    d = nd.summarize([{"ts": 1, "service": "x", "state": "green"}], now_ts=1000, weekly=True)
    check("weekly window", d["stats"]["window"] == "week")
    check("title says Week", "Week digest" in d["title"], d["title"])


def test_empty_history():
    print("empty_history:")
    d = nd.summarize([], now_ts=1000)
    check("empty -> GREEN", d["stats"]["overall"] == "GREEN")
    check("empty -> 0 incidents", d["stats"]["incidents"] == 0)


def main():
    for fn in (test_all_green, test_incident_and_down, test_degraded_only,
               test_weekly_window_label, test_empty_history):
        fn()
    print(f"\n{PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
