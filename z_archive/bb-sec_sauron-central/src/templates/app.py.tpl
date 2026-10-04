#!/usr/bin/env python3
"""Simple SIEM API for querying alerts."""

import os
import sqlite3
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from datetime import datetime, timedelta

DB_PATH = os.environ.get("DB_PATH", "/var/log/siem/alerts.db")


def get_db():
    """Get database connection."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    """Initialize database schema if needed."""
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT,
            vm TEXT,
            severity TEXT,
            rule TEXT,
            file TEXT,
            raw TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_ts ON alerts(ts)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_vm ON alerts(vm)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_severity ON alerts(severity)")
    conn.commit()
    conn.close()


class APIHandler(BaseHTTPRequestHandler):
    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/api/health":
            self._send_json({"status": "ok"})

        elif path == "/api/alerts":
            self._get_alerts(params)

        elif path == "/api/stats":
            self._get_stats(params)

        elif path == "/api/vms":
            self._get_vms()

        else:
            self._send_json({"error": "Not found"}, 404)

    def _get_alerts(self, params):
        """Get alerts with optional filters."""
        conn = get_db()

        query = "SELECT * FROM alerts WHERE 1=1"
        args = []

        if "vm" in params:
            query += " AND vm = ?"
            args.append(params["vm"][0])

        if "severity" in params:
            query += " AND severity = ?"
            args.append(params["severity"][0])

        if "since" in params:
            query += " AND ts >= ?"
            args.append(params["since"][0])

        query += " ORDER BY ts DESC LIMIT ?"
        args.append(int(params.get("limit", [100])[0]))

        rows = conn.execute(query, args).fetchall()
        conn.close()

        alerts = [dict(row) for row in rows]
        self._send_json({"alerts": alerts, "count": len(alerts)})

    def _get_stats(self, params):
        """Get alert statistics."""
        conn = get_db()

        # Get counts by severity
        severity_counts = conn.execute("""
            SELECT severity, COUNT(*) as count
            FROM alerts
            GROUP BY severity
        """).fetchall()

        # Get counts by VM
        vm_counts = conn.execute("""
            SELECT vm, COUNT(*) as count
            FROM alerts
            GROUP BY vm
        """).fetchall()

        # Get last 24h count
        yesterday = (datetime.now() - timedelta(days=1)).isoformat()
        recent_count = conn.execute(
            "SELECT COUNT(*) FROM alerts WHERE ts >= ?",
            [yesterday]
        ).fetchone()[0]

        conn.close()

        self._send_json({
            "by_severity": {row[0]: row[1] for row in severity_counts},
            "by_vm": {row[0]: row[1] for row in vm_counts},
            "last_24h": recent_count
        })

    def _get_vms(self):
        """Get list of VMs with alert counts."""
        conn = get_db()
        rows = conn.execute("""
            SELECT vm, COUNT(*) as count, MAX(ts) as last_alert
            FROM alerts
            GROUP BY vm
        """).fetchall()
        conn.close()

        vms = [{"vm": row[0], "count": row[1], "last_alert": row[2]} for row in rows]
        self._send_json({"vms": vms})

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass


def main():
    init_db()
    port = int(os.environ.get("PORT", 8080))
    server = HTTPServer(("0.0.0.0", port), APIHandler)
    print(f"SIEM API running on port {port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
