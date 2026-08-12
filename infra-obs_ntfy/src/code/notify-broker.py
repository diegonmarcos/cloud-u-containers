#!/usr/bin/env python3
import sys; sys.stdout.reconfigure(line_buffering=True)
"""
Enterprise notification broker for the ntfy taxonomy.

All producers (load-shedder, journal-ntfy, health-agent, reports) POST *events*
here instead of publishing raw to the health_resources firehose. The broker
applies a data-driven policy (build-notify.json, emitted by 9_others) to decide:
severity, dedup/rate-limit, flap detection, escalation, recovery pairing, and
multi-channel routing (ntfy topic / matrix room / email).

DESIGN — the routing/dedup/flap/escalation/recovery logic is a PURE FUNCTION:

    decide(event, policy, state, now_ts) -> (actions, new_state)

`decide` does NO I/O — no network, no clock, no disk. That makes it fully
table-testable (see test_notify_broker.py). The impure shell around it
(load_state / save_state / dispatch actions over the network / the HTTP server)
is kept thin and lives below the DECIDE line.

Event contract (what producers emit — see MIGRATION-notify-broker.md):
    {
      "source":   "load-shedder",          # producer id (free text)
      "class":    "load_shed",             # event class → severity_map.by_class
      "severity": "crit",                  # OPTIONAL explicit override; wins over class
      "key":      "oci-mail:load_shed",    # dedup / recovery / escalation identity
      "category": "resources",             # OPTIONAL; else resolved from unit or default
      "unit":     "load-shedder",          # OPTIONAL; category_by_unit fallback
      "title":    "Load shed on oci-mail",
      "body":     "PSI mem avg10=72 ...",
      "host":     "oci-mail",
      "service":  "maddy",
      "ack":      false,                   # true = ack this key (reset escalation)
      "recovered": false                   # true = condition cleared (recovery notice)
    }

Config SoT: ./build-notify.json (symlink → 1_cloud-configs/dist/build-notify.json).
"""
import json
import time
import fnmatch
import urllib.request
import urllib.parse
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer

POLICY_PATH = "/app/build-notify.json"
DEFAULT_STATE_PATH = "/var/cache/ntfy/notify-state.json"

SEVERITY_ORDER = ["info", "warn", "crit", "page"]


# ═══════════════════════════════════════════════════════════════════════════
# DECIDE — pure function. No I/O. Fully unit-testable.
# ═══════════════════════════════════════════════════════════════════════════

def _severity_rank(sev):
    try:
        return SEVERITY_ORDER.index(sev)
    except ValueError:
        return 0


def resolve_category(event, policy):
    """category from event.category, else unit glob, else 'default'."""
    if event.get("category"):
        return event["category"]
    unit = event.get("unit")
    if unit:
        table = policy.get("category_by_unit", {})
        # Longest literal (non-glob) prefix wins; then glob patterns.
        literal = {k: v for k, v in table.items() if "*" not in k and not k.startswith("_")}
        if unit in literal:
            return literal[unit]
        best = None
        for pat, cat in table.items():
            if pat.startswith("_"):
                continue
            if "*" in pat and fnmatch.fnmatch(unit, pat):
                # Prefer the most specific (longest) matching glob.
                if best is None or len(pat) > len(best[0]):
                    best = (pat, cat)
        if best:
            return best[1]
    return "default"


def resolve_severity(event, policy):
    """Explicit event.severity wins; else map event.class via severity_map."""
    sev = event.get("severity")
    if sev in SEVERITY_ORDER:
        return sev
    smap = policy.get("severity_map", {})
    by_class = smap.get("by_class", {})
    cls = event.get("class")
    if cls and cls in by_class:
        return by_class[cls]
    return smap.get("default", "info")


def route_channels(category, severity, policy):
    """Pick the channel list for (category, severity). service rule > category > default."""
    rules = policy.get("routing", {}).get("rules", [])
    # match precedence: service:<svc> handled by caller injecting category already;
    # here we match category:<cat> then default.
    want = f"category:{category}"
    chosen = None
    for r in rules:
        if r.get("match") == want:
            chosen = r
            break
    if chosen is None:
        for r in rules:
            if r.get("match") == "default":
                chosen = r
                break
    if chosen is None:
        return []
    return chosen.get("channels", {}).get(severity, [])


def _flap_step(key_state, alerting, now_ts, flap_cfg):
    """Track transitions; return (is_flapping, muted, new_key_state)."""
    if not flap_cfg.get("enabled", False):
        return False, False, key_state
    window = flap_cfg.get("window_secs", 900)
    limit = flap_cfg.get("transitions", 4)
    mute_for = flap_cfg.get("mute_after_flap_secs", 1800)

    ks = dict(key_state)
    muted_until = ks.get("flap_muted_until", 0)
    if now_ts < muted_until:
        return False, True, ks  # inside mute window — suppress

    prev = ks.get("alerting")
    trans = ks.get("transitions", [])
    if prev is not None and prev != alerting:
        trans = [t for t in trans if now_ts - t < window]
        trans.append(now_ts)
    ks["transitions"] = trans

    is_flapping = len(trans) >= limit
    if is_flapping:
        ks["flap_muted_until"] = now_ts + mute_for
        ks["transitions"] = []
    return is_flapping, False, ks


def decide(event, policy, state, now_ts):
    """
    Pure routing/dedup/flap/escalation/recovery decision.

    Returns (actions, new_state):
      actions: list of {kind, topic?, severity, title, body, key, note}
      new_state: updated state dict (persist verbatim)

    Never performs I/O. `now_ts` is injected epoch seconds.
    """
    new_state = json.loads(json.dumps(state)) if state else {}
    keys = new_state.setdefault("keys", {})

    key = event.get("key") or f"{event.get('source', '?')}:{event.get('class', '?')}"
    ks = keys.setdefault(key, {})

    category = resolve_category(event, policy)
    severity = resolve_severity(event, policy)
    recovered = bool(event.get("recovered")) or event.get("class") in ("recovered",) \
        or (isinstance(event.get("class"), str) and event["class"].endswith("_ok"))
    ack = bool(event.get("ack"))

    actions = []

    # ── ACK: reset escalation ladder, no notification ──────────────────────
    if ack:
        ks["acked"] = True
        ks["escalation_level"] = None
        return actions, new_state

    # ── RECOVERY: paired resolved notice, then clear key ───────────────────
    rec_cfg = policy.get("recovery", {})
    if recovered:
        # flap accounting: alerting -> not alerting
        flapping, muted, ks = _flap_step(ks, alerting=False, now_ts=now_ts, flap_cfg=policy.get("flap", {}))
        was_alerting = ks.get("active_severity") is not None
        if rec_cfg.get("enabled", True) and was_alerting:
            notice_sev = rec_cfg.get("notice_severity", "info")
            channels = route_channels(category, ks.get("active_severity", severity), policy)
            for ch in channels:
                actions.append({
                    "kind": ch.get("kind"),
                    "topic": ch.get("topic"),
                    "severity": notice_sev,
                    "title": f"[RESOLVED] {event.get('title', key)}",
                    "body": event.get("body", ""),
                    "key": key,
                    "note": "recovery",
                })
        # clear alerting state, keep flap transitions window
        ks["active_severity"] = None
        ks["alerting"] = False
        ks["acked"] = False
        ks["escalation_level"] = None
        ks.pop("first_alert_ts", None)
        ks.pop("last_alert_ts", None)
        keys[key] = ks
        return actions, new_state

    # ── ESCALATION: bump severity if an unacked alert has aged past threshold ─
    esc = policy.get("escalation", {})
    if esc.get("enabled", False) and ks.get("active_severity") and not ks.get("acked"):
        first = ks.get("first_alert_ts", now_ts)
        age = now_ts - first
        eff = severity
        if ks["active_severity"] == "warn" and age >= esc.get("warn_to_crit_secs", 900):
            eff = "crit"
        if (ks["active_severity"] in ("warn", "crit")) and age >= esc.get("crit_to_page_secs", 1800):
            eff = "page"
        # escalation only raises, never lowers
        if _severity_rank(eff) > _severity_rank(severity):
            severity = eff

    # ── FLAP: not alerting -> alerting transition tracking ─────────────────
    flapping, muted, ks = _flap_step(ks, alerting=True, now_ts=now_ts, flap_cfg=policy.get("flap", {}))
    if muted:
        keys[key] = ks
        return actions, new_state  # inside flap mute window
    if flapping:
        channels = route_channels(category, "warn", policy)
        for ch in channels:
            actions.append({
                "kind": ch.get("kind"),
                "topic": ch.get("topic"),
                "severity": "warn",
                "title": f"[FLAPPING] {event.get('title', key)}",
                "body": f"{key} flapped; further transitions muted.",
                "key": key,
                "note": "flap",
            })
        ks["active_severity"] = severity
        ks["alerting"] = True
        ks["first_alert_ts"] = ks.get("first_alert_ts", now_ts)
        ks["last_alert_ts"] = now_ts
        keys[key] = ks
        return actions, new_state

    # ── DEDUP: suppress identical (key, severity) within window ────────────
    dd = policy.get("dedup", {})
    window = dd.get("by_key", {}).get(key, dd.get("window_secs", 300))
    last = ks.get("last_sent", {}).get(severity, 0)
    suppressed = (now_ts - last) < window and ks.get("active_severity") == severity
    if suppressed:
        ks.setdefault("suppressed_count", 0)
        ks["suppressed_count"] += 1
        ks["alerting"] = True
        keys[key] = ks
        return actions, new_state

    # ── EMIT: route to channels for (category, severity) ───────────────────
    channels = route_channels(category, severity, policy)
    for ch in channels:
        actions.append({
            "kind": ch.get("kind"),
            "topic": ch.get("topic"),
            "severity": severity,
            "title": event.get("title", key),
            "body": event.get("body", ""),
            "key": key,
            "note": "alert",
        })

    ks.setdefault("last_sent", {})[severity] = now_ts
    ks["active_severity"] = severity
    ks["alerting"] = True
    ks["acked"] = False
    ks["first_alert_ts"] = ks.get("first_alert_ts", now_ts)
    ks["last_alert_ts"] = now_ts
    ks["suppressed_count"] = 0
    keys[key] = ks
    return actions, new_state


# ═══════════════════════════════════════════════════════════════════════════
# IMPURE SHELL — I/O, network, HTTP server. Not unit-tested (no logic).
# ═══════════════════════════════════════════════════════════════════════════

def load_policy(path=POLICY_PATH):
    return json.loads(Path(path).read_text())


def load_state(path):
    try:
        return json.loads(Path(path).read_text())
    except Exception:
        return {}


def save_state(path, state):
    p = Path(path)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(p)  # atomic


def _priority_for(severity, policy):
    levels = policy.get("severity_levels", {})
    if severity in levels and "priority" in levels[severity]:
        return str(levels[severity]["priority"])
    return {"info": "default", "warn": "high", "crit": "urgent", "page": "urgent"}.get(severity, "default")


def dispatch(action, policy):
    """Send one action over its transport. All secrets read from env at runtime."""
    import os
    kind = action["kind"]
    if kind == "ntfy":
        ntfy = policy.get("ntfy", {})
        base = ntfy.get("wg_base_url", "http://10.0.0.6:8090")
        topic = action.get("topic")
        if not topic:
            print(f"[broker] skip ntfy action without topic: {action['key']}", flush=True)
            return False
        # Validate topic against the live taxonomy the engine emitted.
        valid = policy.get("valid_topics")
        if valid and topic not in valid:
            print(f"[broker] ERROR unknown topic '{topic}' (not in valid_topics) — dropping", flush=True)
            return False
        headers = {
            "Title": action["title"][:250],
            "Priority": _priority_for(action["severity"], policy),
        }
        token_env = policy.get("channels", {}).get("ntfy", {}).get("token_env")
        tok = os.environ.get(token_env) if token_env else None
        if tok:
            headers["Authorization"] = f"Bearer {tok}"
        req = urllib.request.Request(
            f"{base}/{topic}", data=action["body"].encode("utf-8"),
            headers=headers, method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=ntfy.get("timeout_secs", 5)) as r:
                return r.status == 200
        except Exception as e:
            print(f"[broker] ntfy dispatch error: {e}", flush=True)
            return False
    if kind == "matrix":
        # Matrix room post. Requires MATRIX_BROKER_TOKEN in env (secrets.yaml).
        import os as _os
        ch = policy.get("channels", {}).get("matrix", {})
        if not ch.get("enabled"):
            return False
        tok = _os.environ.get(ch.get("token_env", ""))
        if not tok:
            print("[broker] matrix token missing — skipping matrix action", flush=True)
            return False
        hs = ch.get("homeserver", "").rstrip("/")
        room = ch.get("room")
        txn = str(int(time.time() * 1000))
        url = f"{hs}/_matrix/client/v3/rooms/{urllib.parse.quote(room)}/send/m.room.message/{txn}"
        payload = json.dumps({"msgtype": "m.text", "body": f"{action['title']}\n{action['body']}"}).encode()
        req = urllib.request.Request(
            url, data=payload, method="PUT",
            headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                return r.status in (200, 201)
        except Exception as e:
            print(f"[broker] matrix dispatch error: {e}", flush=True)
            return False
    if kind == "email":
        # Email via resend API (secrets.yaml RESEND_API_KEY).
        import os as _os
        ch = policy.get("channels", {}).get("email", {})
        if not ch.get("enabled"):
            return False
        key = _os.environ.get(ch.get("resend_key_env", ""))
        if not key:
            print("[broker] resend key missing — skipping email action", flush=True)
            return False
        payload = json.dumps({
            "from": ch.get("from"),
            "to": [ch.get("to")],
            "subject": f"[{action['severity'].upper()}] {action['title']}",
            "text": action["body"],
        }).encode()
        req = urllib.request.Request(
            "https://api.resend.com/emails", data=payload, method="POST",
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status in (200, 202)
        except Exception as e:
            print(f"[broker] email dispatch error: {e}", flush=True)
            return False
    print(f"[broker] unknown channel kind: {kind}", flush=True)
    return False


class BrokerHandler(BaseHTTPRequestHandler):
    policy = None
    state_path = DEFAULT_STATE_PATH

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/health", "/"):
            self._json(200, {"ok": True})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/event", "/ack"):
            self._json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            event = json.loads(self.rfile.read(length) or b"{}")
        except Exception as e:
            self._json(400, {"error": f"bad json: {e}"})
            return
        if self.path == "/ack":
            event["ack"] = True
        state = load_state(self.state_path)
        actions, new_state = decide(event, self.policy, state, int(time.time()))
        sent = 0
        for a in actions:
            if dispatch(a, self.policy):
                sent += 1
        save_state(self.state_path, new_state)
        self._json(200, {"actions": len(actions), "sent": sent})

    def log_message(self, fmt, *args):
        pass


def main():
    import os
    policy = load_policy(os.environ.get("NOTIFY_POLICY_PATH", POLICY_PATH))
    state_path = policy.get("state", {}).get("path", DEFAULT_STATE_PATH)
    port = int(os.environ.get("BROKER_PORT", "8092"))
    BrokerHandler.policy = policy
    BrokerHandler.state_path = state_path
    print(f"[broker] listening on :{port} — policy topics={len(policy.get('valid_topics', []))}", flush=True)
    HTTPServer(("0.0.0.0", port), BrokerHandler).serve_forever()


if __name__ == "__main__":
    main()
