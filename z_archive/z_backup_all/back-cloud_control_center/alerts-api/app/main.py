"""
Alerts API - Central Alert & Log Audit Center
Receives alerts from collectors, stores in SQLite, forwards to ntfy
"""
from flask import Flask, request, jsonify
from flask_cors import CORS
from datetime import datetime, timedelta
import sqlite3
import os
import requests
import json

app = Flask(__name__)
CORS(app)

# Configuration
DB_PATH = os.environ.get('DB_PATH', '/data/alerts.db')
NTFY_URL = os.environ.get('NTFY_URL', 'https://rss.diegonmarcos.com')

# Priority mapping
PRIORITY_MAP = {
    'critical': 5,
    'high': 4,
    'default': 3,
    'low': 2,
    'min': 1
}

def get_db():
    """Get database connection"""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    """Initialize database tables"""
    conn = get_db()
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS alerts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
            vm TEXT NOT NULL,
            service TEXT NOT NULL,
            topic TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT,
            priority TEXT DEFAULT 'default',
            tags TEXT,
            log_path TEXT,
            log_cmd TEXT,
            acknowledged INTEGER DEFAULT 0,
            ntfy_id TEXT
        );

        CREATE TABLE IF NOT EXISTS services (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            vm TEXT NOT NULL,
            status TEXT DEFAULT 'unknown',
            last_seen DATETIME,
            last_alert DATETIME
        );

        CREATE TABLE IF NOT EXISTS vms (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE NOT NULL,
            ip TEXT,
            status TEXT DEFAULT 'unknown',
            last_seen DATETIME
        );

        CREATE INDEX IF NOT EXISTS idx_alerts_timestamp ON alerts(timestamp);
        CREATE INDEX IF NOT EXISTS idx_alerts_service ON alerts(service);
        CREATE INDEX IF NOT EXISTS idx_alerts_vm ON alerts(vm);
    ''')
    conn.commit()
    conn.close()

def send_to_ntfy(topic, title, message, priority='default', tags=''):
    """Forward alert to ntfy"""
    try:
        headers = {
            'Title': title,
            'Priority': str(PRIORITY_MAP.get(priority, 3)),
            'Tags': tags
        }
        resp = requests.post(
            f"{NTFY_URL}/{topic}",
            data=message,
            headers=headers,
            timeout=5
        )
        if resp.ok:
            data = resp.json()
            return data.get('id')
    except Exception as e:
        app.logger.error(f"ntfy error: {e}")
    return None

# ============ API ENDPOINTS ============

@app.route('/api/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'ok', 'timestamp': datetime.utcnow().isoformat()})

@app.route('/api/alerts', methods=['POST'])
def create_alert():
    """
    Receive alert from collector

    Body:
    {
        "vm": "oci-flex",
        "service": "ssh",
        "topic": "auth",
        "title": "SSH: 3 failed logins",
        "message": "Failed login attempts from 192.168.1.1",
        "priority": "high",
        "tags": "warning,lock",
        "log_path": "/var/log/auth.log",
        "log_cmd": "journalctl -u sshd --since '5 min ago'"
    }
    """
    data = request.get_json()

    if not data:
        return jsonify({'error': 'No data provided'}), 400

    required = ['vm', 'service', 'topic', 'title']
    for field in required:
        if field not in data:
            return jsonify({'error': f'Missing field: {field}'}), 400

    # Store in database
    conn = get_db()
    cursor = conn.cursor()

    cursor.execute('''
        INSERT INTO alerts (vm, service, topic, title, message, priority, tags, log_path, log_cmd)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''', (
        data['vm'],
        data['service'],
        data['topic'],
        data['title'],
        data.get('message', ''),
        data.get('priority', 'default'),
        data.get('tags', ''),
        data.get('log_path', ''),
        data.get('log_cmd', '')
    ))

    alert_id = cursor.lastrowid

    # Update service last_alert
    cursor.execute('''
        INSERT INTO services (name, vm, status, last_alert, last_seen)
        VALUES (?, ?, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        ON CONFLICT(name) DO UPDATE SET
            last_alert = CURRENT_TIMESTAMP,
            last_seen = CURRENT_TIMESTAMP,
            status = 'active'
    ''', (data['service'], data['vm']))

    # Update VM last_seen
    cursor.execute('''
        INSERT INTO vms (name, status, last_seen)
        VALUES (?, 'online', CURRENT_TIMESTAMP)
        ON CONFLICT(name) DO UPDATE SET
            last_seen = CURRENT_TIMESTAMP,
            status = 'online'
    ''', (data['vm'],))

    conn.commit()

    # Forward to ntfy
    ntfy_id = send_to_ntfy(
        data['topic'],
        data['title'],
        data.get('message', ''),
        data.get('priority', 'default'),
        data.get('tags', '')
    )

    if ntfy_id:
        cursor.execute('UPDATE alerts SET ntfy_id = ? WHERE id = ?', (ntfy_id, alert_id))
        conn.commit()

    conn.close()

    return jsonify({
        'id': alert_id,
        'ntfy_id': ntfy_id,
        'status': 'created'
    }), 201

@app.route('/api/alerts', methods=['GET'])
def get_alerts():
    """
    Get alerts with optional filters

    Query params:
    - since: ISO timestamp or relative (1h, 24h, 7d)
    - vm: filter by VM
    - service: filter by service
    - topic: filter by topic
    - priority: filter by priority
    - limit: max results (default 100)
    - offset: pagination offset
    """
    since = request.args.get('since', '24h')
    vm = request.args.get('vm')
    service = request.args.get('service')
    topic = request.args.get('topic')
    priority = request.args.get('priority')
    limit = int(request.args.get('limit', 100))
    offset = int(request.args.get('offset', 0))

    # Parse since parameter
    if since.endswith('h'):
        hours = int(since[:-1])
        since_time = datetime.utcnow() - timedelta(hours=hours)
    elif since.endswith('d'):
        days = int(since[:-1])
        since_time = datetime.utcnow() - timedelta(days=days)
    else:
        try:
            since_time = datetime.fromisoformat(since)
        except:
            since_time = datetime.utcnow() - timedelta(hours=24)

    # Build query
    query = 'SELECT * FROM alerts WHERE timestamp > ?'
    params = [since_time.isoformat()]

    if vm:
        query += ' AND vm = ?'
        params.append(vm)
    if service:
        query += ' AND service = ?'
        params.append(service)
    if topic:
        query += ' AND topic = ?'
        params.append(topic)
    if priority:
        query += ' AND priority = ?'
        params.append(priority)

    query += ' ORDER BY timestamp DESC LIMIT ? OFFSET ?'
    params.extend([limit, offset])

    conn = get_db()
    cursor = conn.cursor()
    cursor.execute(query, params)

    alerts = [dict(row) for row in cursor.fetchall()]

    # Get total count
    count_query = 'SELECT COUNT(*) FROM alerts WHERE timestamp > ?'
    cursor.execute(count_query, [since_time.isoformat()])
    total = cursor.fetchone()[0]

    conn.close()

    return jsonify({
        'alerts': alerts,
        'total': total,
        'limit': limit,
        'offset': offset
    })

@app.route('/api/alerts/<int:alert_id>/ack', methods=['POST'])
def acknowledge_alert(alert_id):
    """Acknowledge an alert"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('UPDATE alerts SET acknowledged = 1 WHERE id = ?', (alert_id,))
    conn.commit()
    conn.close()
    return jsonify({'status': 'acknowledged'})

@app.route('/api/stats', methods=['GET'])
def get_stats():
    """Get alert statistics"""
    since = request.args.get('since', '24h')

    if since.endswith('h'):
        hours = int(since[:-1])
        since_time = datetime.utcnow() - timedelta(hours=hours)
    elif since.endswith('d'):
        days = int(since[:-1])
        since_time = datetime.utcnow() - timedelta(days=days)
    else:
        since_time = datetime.utcnow() - timedelta(hours=24)

    conn = get_db()
    cursor = conn.cursor()

    # Count by priority
    cursor.execute('''
        SELECT priority, COUNT(*) as count
        FROM alerts
        WHERE timestamp > ?
        GROUP BY priority
    ''', [since_time.isoformat()])
    by_priority = {row['priority']: row['count'] for row in cursor.fetchall()}

    # Count by service
    cursor.execute('''
        SELECT service, COUNT(*) as count
        FROM alerts
        WHERE timestamp > ?
        GROUP BY service
    ''', [since_time.isoformat()])
    by_service = {row['service']: row['count'] for row in cursor.fetchall()}

    # Count by VM
    cursor.execute('''
        SELECT vm, COUNT(*) as count
        FROM alerts
        WHERE timestamp > ?
        GROUP BY vm
    ''', [since_time.isoformat()])
    by_vm = {row['vm']: row['count'] for row in cursor.fetchall()}

    # Total count
    cursor.execute('SELECT COUNT(*) FROM alerts WHERE timestamp > ?', [since_time.isoformat()])
    total = cursor.fetchone()[0]

    conn.close()

    return jsonify({
        'total': total,
        'by_priority': by_priority,
        'by_service': by_service,
        'by_vm': by_vm,
        'since': since_time.isoformat()
    })

@app.route('/api/services', methods=['GET'])
def get_services():
    """Get all services with status"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT * FROM services ORDER BY name')
    services = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return jsonify({'services': services})

@app.route('/api/vms', methods=['GET'])
def get_vms():
    """Get all VMs with status"""
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('SELECT * FROM vms ORDER BY name')
    vms = [dict(row) for row in cursor.fetchall()]
    conn.close()
    return jsonify({'vms': vms})

@app.route('/api/services/<name>/heartbeat', methods=['POST'])
def service_heartbeat(name):
    """Update service heartbeat"""
    data = request.get_json() or {}
    vm = data.get('vm', 'unknown')
    status = data.get('status', 'active')

    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('''
        INSERT INTO services (name, vm, status, last_seen)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(name) DO UPDATE SET
            last_seen = CURRENT_TIMESTAMP,
            status = ?
    ''', (name, vm, status, status))
    conn.commit()
    conn.close()

    return jsonify({'status': 'ok'})

@app.route('/api/vms/<name>/heartbeat', methods=['POST'])
def vm_heartbeat(name):
    """Update VM heartbeat"""
    data = request.get_json() or {}
    ip = data.get('ip', '')
    status = data.get('status', 'online')

    conn = get_db()
    cursor = conn.cursor()
    cursor.execute('''
        INSERT INTO vms (name, ip, status, last_seen)
        VALUES (?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(name) DO UPDATE SET
            last_seen = CURRENT_TIMESTAMP,
            status = ?,
            ip = COALESCE(?, ip)
    ''', (name, ip, status, status, ip))
    conn.commit()
    conn.close()

    return jsonify({'status': 'ok'})

# Initialize database on startup
with app.app_context():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    init_db()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
