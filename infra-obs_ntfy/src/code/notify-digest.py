#!/usr/bin/env python3
import sys; sys.stdout.reconfigure(line_buffering=True)
"""
Notification digest generator (§4C).

Daily 08:00 (+ weekly rollup on the configured weekday) summary posted to the
ops_reports topic + email. Reads the tiered-reports history JSONL (written by the
Phase-1 reports engine) — NOT the live infra — so it never probes anything; it
just aggregates what already happened.

Pure aggregation core:  summarize(records, now_ts, weekly) -> {title, body, stats}
is I/O-free and table-testable. The impure shell reads the JSONL, calls the
broker's dispatch() (so routing/secrets stay in ONE place), and exits.

Invoked by a Dagu DAG / systemd timer at 08:00 (cadence + topic are data in
build-notify.json#digest). Run manually:  python3 notify-digest.py [--weekly]

History JSONL line shape (contract with the reports engine):
    {"ts": 1720000000, "service": "maddy", "state": "green|yellow|red|unknown|stale",
     "tier": "t1", "detail": "..."}
"""
import json
import time
import importlib.util
from pathlib import Path
from datetime import datetime, timezone


POLICY_PATH = "/app/build-notify.json"


# ── pure aggregation ───────────────────────────────────────────────────────
def read_history(path, since_ts):
    """Read JSONL, keep records with ts >= since_ts. Tolerates bad lines."""
    recs = []
    p = Path(path)
    if not p.exists():
        return recs
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
            if r.get("ts", 0) >= since_ts:
                recs.append(r)
        except Exception:
            continue
    return recs


def summarize(records, now_ts, weekly=False):
    """
    Aggregate history records into a digest. Pure — no I/O.
    Returns {title, body, stats}.
    """
    window = "week" if weekly else "day"
    by_service = {}
    state_counts = {"green": 0, "yellow": 0, "red": 0, "unknown": 0, "stale": 0}
    incidents = []  # transitions into red

    prev_state = {}
    for r in sorted(records, key=lambda x: x.get("ts", 0)):
        svc = r.get("service", "?")
        st = r.get("state", "unknown")
        state_counts[st] = state_counts.get(st, 0) + 1
        cur = by_service.setdefault(svc, {"last": st, "reds": 0, "worst": st})
        cur["last"] = st
        if st == "red":
            cur["reds"] += 1
            if prev_state.get(svc) != "red":
                incidents.append({"service": svc, "ts": r.get("ts"), "detail": r.get("detail", "")})
        # worst-of tracking
        rank = {"green": 0, "yellow": 1, "unknown": 1, "stale": 2, "red": 3}
        if rank.get(st, 0) > rank.get(cur["worst"], 0):
            cur["worst"] = st
        prev_state[svc] = st

    reds_now = sorted([s for s, v in by_service.items() if v["last"] == "red"])
    yellows_now = sorted([s for s, v in by_service.items() if v["last"] in ("yellow", "stale", "unknown")])
    greens = sorted([s for s, v in by_service.items() if v["last"] == "green"])

    dt = datetime.fromtimestamp(now_ts, tz=timezone.utc).strftime("%Y-%m-%d")
    overall = "RED" if reds_now else ("YELLOW" if yellows_now else "GREEN")
    title = f"[{overall}] {window.capitalize()} digest {dt}"

    lines = [
        f"Overall: {overall}",
        f"Services: {len(greens)} green / {len(yellows_now)} degraded / {len(reds_now)} down",
        f"Incidents ({window}): {len(incidents)}",
    ]
    if reds_now:
        lines.append("DOWN now: " + ", ".join(reds_now))
    if yellows_now:
        lines.append("Degraded: " + ", ".join(yellows_now))
    if incidents:
        lines.append("")
        lines.append("Recent incidents:")
        for inc in incidents[-10:]:
            when = datetime.fromtimestamp(inc.get("ts") or now_ts, tz=timezone.utc).strftime("%m-%d %H:%M")
            lines.append(f"  {when} {inc['service']} {inc.get('detail', '')}".rstrip())

    return {
        "title": title,
        "body": "\n".join(lines),
        "stats": {
            "overall": overall,
            "window": window,
            "state_counts": state_counts,
            "incidents": len(incidents),
            "reds_now": reds_now,
            "yellows_now": yellows_now,
            "green_count": len(greens),
        },
    }


# ── impure shell ───────────────────────────────────────────────────────────
def _load_broker():
    spec = importlib.util.spec_from_file_location(
        "notify_broker", str(Path(__file__).with_name("notify-broker.py")))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    import os
    weekly = "--weekly" in sys.argv
    policy = json.loads(Path(os.environ.get("NOTIFY_POLICY_PATH", POLICY_PATH)).read_text())
    dcfg = policy.get("digest", {})
    if not dcfg.get("enabled", True):
        print("[digest] disabled in policy — nothing to do")
        return

    now_ts = int(time.time())
    span = 7 * 86400 if weekly else 86400
    hist_path = dcfg.get("reports_history_jsonl", "/opt/health/history/reports.jsonl")
    records = read_history(hist_path, now_ts - span)
    digest = summarize(records, now_ts, weekly=weekly)

    topic = dcfg.get("topic", "ops_reports")
    nb = _load_broker()
    actions = [{"kind": "ntfy", "topic": topic, "severity": "info",
                "title": digest["title"], "body": digest["body"], "key": "digest", "note": "digest"}]
    if dcfg.get("email"):
        actions.append({"kind": "email", "severity": "info",
                        "title": digest["title"], "body": digest["body"], "key": "digest", "note": "digest"})
    sent = sum(1 for a in actions if nb.dispatch(a, policy))
    print(f"[digest] {digest['stats']['overall']} — {len(records)} records, {sent}/{len(actions)} channels sent")


if __name__ == "__main__":
    main()
