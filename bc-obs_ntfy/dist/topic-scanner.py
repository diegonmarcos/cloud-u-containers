"""ntfy topic scanner — serves ALL configured channels (not just ones with messages)."""

import json
import sqlite3
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

DB_PATH = "/var/cache/ntfy/cache.db"
PORT = 8091
REFRESH_INTERVAL = 30  # seconds

# ALL configured channels (always shown, even if no messages yet)
# Format: category_name-of-channel
CONFIGURED_TOPICS = [
    # VCS — version control events (from GitHub Atom feed)
    "vcs_commits",              # Push/commit events
    "vcs_pull-requests",        # PR open/close/merge events
    "vcs_issues-releases",      # Issues, releases, tags, forks
    # CI/CD — build & deploy pipeline
    "cicd_deploy-digest",       # Container restarts & deploy activity
    # Infrastructure — system & network health
    "infra_mesh-health",        # WireGuard mesh connectivity checks
    "infra_endpoints",          # HTTP service endpoint monitoring
    "infra_dns",                # DNS resolution checks
    "infra_resources",          # VM disk/memory/CPU usage
    "infra_containers",         # Docker container health
    # Operations — scheduled tasks & data
    "ops_summary",              # Daily/weekly ops reports
    "ops_backups",              # Backup freshness status
    "ops_cron",                 # Systemd timer/cron failures
    # Security — threats, auth, certs
    "security_audit",           # Auth log analysis & brute-force detection
    "security_tls",             # TLS certificate expiry warnings
    "security_connections",     # All SSH/sudo/connection events across VMs
    "security_yara",            # YARA malware scanner alerts & status
]

# Shared state
_lock = threading.Lock()
_topics = []
_updated = ""


def scan_topics():
    """Return ALL configured topics + any discovered in cache.db."""
    all_topics = set(CONFIGURED_TOPICS)

    # Also add any topics found in cache.db (user-created channels)
    try:
        conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        cur = conn.cursor()
        cur.execute("SELECT DISTINCT topic FROM messages ORDER BY topic")
        db_topics = [row[0] for row in cur.fetchall()]
        conn.close()
        all_topics.update(db_topics)
    except Exception as e:
        print(f"[scanner] warning: could not read cache.db: {e}", flush=True)

    return sorted(list(all_topics))


def refresh_loop():
    """Background thread that refreshes the topic list every REFRESH_INTERVAL seconds."""
    global _topics, _updated
    while True:
        result = scan_topics()
        if result is not None:
            with _lock:
                _topics = result
                _updated = datetime.now(timezone.utc).isoformat()
            print(f"[scanner] refreshed: {len(_topics)} topics", flush=True)
        time.sleep(REFRESH_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path == "":
            with _lock:
                body = json.dumps({"topics": _topics, "updated": _updated})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body.encode())
        elif self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        # Suppress per-request logs
        pass


if __name__ == "__main__":
    # Initial scan before starting server
    result = scan_topics()
    if result is not None:
        _topics = result
        _updated = datetime.now(timezone.utc).isoformat()
        print(f"[scanner] initial scan: {len(_topics)} topics", flush=True)
    else:
        print("[scanner] initial scan failed, will retry in background", flush=True)

    t = threading.Thread(target=refresh_loop, daemon=True)
    t.start()

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[scanner] listening on :{PORT}", flush=True)
    server.serve_forever()
