#!/usr/bin/env python3
"""
RSS Profile Gateway — serves ntfy topic groups as Atom feeds + discovery JSON.

Endpoints (all under /feed/ prefix — routed here by Caddy from rss.diegonmarcos.com):
  GET /feed/profiles.json           → discovery: all profiles + channels (schema v1)
  GET /feed/<profile_id>.atom       → Atom feed for a profile (aggregated topics)
  GET /feed/c/<channel_name>.atom   → Atom feed for a single topic/channel
  GET /feed/health                  → 200 OK, for healthchecks

Auth: Caddy's 3-tier ntfy auth already validated the request before it reaches us.
Internal ntfy poll is on the Docker network (no auth needed, ntfy auth-default-access=read-write).

Config: /etc/ntfy/profiles-config.json (baked from build.json by the Nix flake).
"""

import sys; sys.stdout.reconfigure(line_buffering=True)

import json
import time
import urllib.request
import urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from datetime import datetime, timezone
from xml.sax.saxutils import escape

PROFILES_CONFIG = "/etc/ntfy/profiles-config.json"
NTFY_INTERNAL   = "http://ntfy:8090"
POLL_SINCE      = "168h"          # 7 days of history in each Atom feed
PORT            = 8091
ATOM_NS         = "http://www.w3.org/2005/Atom"


def load_config():
    return json.loads(Path(PROFILES_CONFIG).read_text())


def ntfy_poll(topics: list[str]) -> list[dict]:
    """Poll ntfy's JSON endpoint for one or more topics (internal, no auth)."""
    if not topics:
        return []
    topic_str = ",".join(topics)
    url = f"{NTFY_INTERNAL}/{topic_str}/json?poll=1&since={POLL_SINCE}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "rss-gateway/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            lines = resp.read().decode().strip().split("\n")
        msgs = []
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                m = json.loads(line)
                if m.get("event") == "message":
                    msgs.append(m)
            except Exception:
                pass
        # Newest first
        msgs.sort(key=lambda m: m.get("time", 0), reverse=True)
        return msgs
    except Exception as e:
        print(f"ntfy poll error ({topic_str}): {e}")
        return []


def iso8601(ts: int) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atom_feed(title: str, feed_id: str, base_url: str, messages: list[dict]) -> str:
    """Render an Atom 1.0 feed from ntfy message objects."""
    updated = iso8601(messages[0]["time"]) if messages else iso8601(int(time.time()))

    entries = []
    for m in messages:
        msg_id   = escape(m.get("id", ""))
        topic    = escape(m.get("topic", ""))
        msg_time = iso8601(m.get("time", 0))
        subject  = escape(m.get("title") or topic or "Notification")
        body     = escape(m.get("message", ""))
        click    = escape(m.get("click", ""))
        tags     = ", ".join(m.get("tags", []))

        content_parts = [body]
        if tags:
            content_parts.append(f"Tags: {escape(tags)}")
        if click:
            content_parts.append(f"Link: {escape(click)}")
        content = " | ".join(p for p in content_parts if p)

        entry_link = click if click else f"{base_url}/c/{topic}.atom"

        entries.append(f"""  <entry>
    <id>urn:ntfy:{escape(msg_id)}</id>
    <title>{subject}</title>
    <updated>{msg_time}</updated>
    <author><name>{topic}</name></author>
    <category term="{topic}"/>
    <content type="text">{content}</content>
    <link href="{escape(entry_link)}"/>
  </entry>""")

    entries_xml = "\n".join(entries)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="{ATOM_NS}">
  <title>{escape(title)}</title>
  <id>urn:ntfy-profile:{escape(feed_id)}</id>
  <updated>{updated}</updated>
  <link href="{escape(base_url)}/{escape(feed_id)}.atom" rel="self"/>
{entries_xml}
</feed>
"""


class Handler(BaseHTTPRequestHandler):
    log_message = lambda self, fmt, *args: print(fmt % args)

    def do_GET(self):
        path = self.path.split("?")[0]  # strip query params

        try:
            cfg = load_config()
        except Exception as e:
            self.send_error(503, f"Config unavailable: {e}")
            return

        base_url = cfg.get("base", "https://rss.diegonmarcos.com/feed")

        # ── /feed/health ────────────────────────────────────────────────────────
        if path in ("/feed/health", "/feed/health/"):
            self._json({"status": "ok"})
            return

        # ── /feed/profiles.json ─────────────────────────────────────────────────
        if path in ("/feed/profiles.json", "/feed/profiles.json/"):
            self._json(cfg)
            return

        # ── /feed/<profile_id>.atom ─────────────────────────────────────────────
        if path.startswith("/feed/") and path.endswith(".atom") and "/c/" not in path:
            profile_id = path[len("/feed/"):-len(".atom")]
            profile = next((p for p in cfg.get("profiles", []) if p["id"] == profile_id), None)
            if not profile:
                self.send_error(404, f"Unknown profile: {profile_id}")
                return
            topics = [ch["name"] for ch in profile.get("channels", [])]
            msgs   = ntfy_poll(topics)
            body   = atom_feed(profile["title"], profile_id, base_url, msgs).encode()
            self._atom(body)
            return

        # ── /feed/c/<channel_name>.atom ─────────────────────────────────────────
        if path.startswith("/feed/c/") and path.endswith(".atom"):
            channel = path[len("/feed/c/"):-len(".atom")]
            all_channels = {ch["name"] for ch in cfg.get("channels", [])}
            if channel not in all_channels:
                self.send_error(404, f"Unknown channel: {channel}")
                return
            msgs = ntfy_poll([channel])
            body = atom_feed(channel, channel, base_url, msgs).encode()
            self._atom(body)
            return

        self.send_error(404, "Not found")

    def _json(self, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _atom(self, body: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "application/atom+xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    print(f"RSS gateway listening on :{PORT}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
