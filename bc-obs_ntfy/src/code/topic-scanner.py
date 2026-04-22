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
    # universal inbox — all events
    "all",                          # Every message from every channel
    # dev — source code events (git)
    "dev_commits",              # Push/commit events
    "dev_pull-requests",        # PR open/close/merge events
    "dev_releases",             # Issues, releases, tags, forks
    # deploy — build & deployment
    "deploy_ship",              # build.sh ship / GHA deploys
    "deploy_containers",        # Container restarts, image pulls
    # health — runtime monitoring
    "health_mesh",              # WireGuard mesh connectivity
    "health_endpoints",         # HTTP service endpoint checks
    "health_dns",               # DNS resolution checks
    "health_resources",         # VM disk/memory/CPU usage
    "health_containers",        # Docker container health
    # ops — maintenance
    "ops_backups",              # Backup freshness status
    "ops_reports",              # Daily/weekly summaries
    # sec — security
    "sec_audit",                # Auth log analysis & brute-force detection
    "sec_tls",                  # TLS certificate expiry warnings
    "sec_connections",          # SSH/sudo/connection events across VMs
    "sec_yara",                 # YARA malware scanner alerts & status
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
