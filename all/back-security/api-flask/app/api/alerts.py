"""
Alerts API Blueprint
Receives alerts from all VMs and pushes to ntfy
"""
import os
import time
import hashlib
import requests
from datetime import datetime, timedelta
from flask import Blueprint, request, jsonify

alerts_bp = Blueprint('alerts', __name__)

# Configuration
NTFY_URL = os.environ.get('NTFY_URL', 'http://ntfy:80')
NTFY_TOKEN = os.environ.get('NTFY_TOKEN', '')
ALERT_HISTORY_HOURS = 24

# In-memory storage (could be Redis/SQLite for persistence)
alert_history = []
seen_hashes = {}  # For deduplication

# Topic mapping
TOPIC_MAP = {
    'github': 'github',
    'sauron': 'sauron',
    'auth': 'auth',
    'system': 'system',
    'docker': 'system',
    'disk': 'system',
    'ops': 'ops',
    'cron': 'cron',
    'backup': 'backup',
    'security': 'security',
    'deploy': 'deploy',
}

# Priority mapping
PRIORITY_MAP = {
    'emergency': 'urgent',
    'alert': 'urgent',
    'critical': 'high',
    'error': 'high',
    'warning': 'default',
    'notice': 'low',
    'info': 'low',
    'debug': 'min',
}


def get_alert_hash(alert):
    """Generate hash for deduplication"""
    key = f"{alert.get('vm', '')}-{alert.get('category', '')}-{alert.get('message', '')[:100]}"
    return hashlib.md5(key.encode()).hexdigest()[:16]


def is_duplicate(alert_hash, window_seconds=300):
    """Check if alert was seen recently"""
    now = time.time()
    if alert_hash in seen_hashes:
        if now - seen_hashes[alert_hash] < window_seconds:
            return True
    seen_hashes[alert_hash] = now
    # Cleanup old hashes
    cutoff = now - 3600
    for h in list(seen_hashes.keys()):
        if seen_hashes[h] < cutoff:
            del seen_hashes[h]
    return False


def push_to_ntfy(topic, title, message, priority='default', tags=None, click=None):
    """Push notification to ntfy"""
    headers = {
        'Title': title[:250],
        'Priority': priority,
    }
    if NTFY_TOKEN:
        headers['Authorization'] = f'Bearer {NTFY_TOKEN}'
    if tags:
        headers['Tags'] = ','.join(tags)
    if click:
        headers['Click'] = click

    try:
        resp = requests.post(
            f'{NTFY_URL}/{topic}',
            data=message.encode('utf-8'),
            headers=headers,
            timeout=10
        )
        return resp.status_code == 200
    except Exception as e:
        print(f'ntfy error: {e}')
        return False


def cleanup_history():
    """Remove old alerts from history"""
    global alert_history
    cutoff = datetime.utcnow() - timedelta(hours=ALERT_HISTORY_HOURS)
    alert_history = [a for a in alert_history if _get_timestamp(a) > cutoff]


def _get_timestamp(alert):
    """Safely get timestamp as datetime object"""
    ts = alert.get('timestamp')
    if ts is None:
        return datetime.min
    if isinstance(ts, datetime):
        return ts
    if isinstance(ts, str):
        try:
            return datetime.fromisoformat(ts.replace('Z', '+00:00'))
        except (ValueError, AttributeError):
            return datetime.min
    return datetime.min


@alerts_bp.route('/ingest', methods=['POST'])
def ingest_alert():
    """
    Receive alert from VM collector

    Expected JSON:
    {
        "vm": "oci-micro-1",
        "category": "auth|sauron|system|github",
        "severity": "emergency|alert|critical|error|warning|notice|info",
        "title": "Short title",
        "message": "Full message",
        "source": "journald|sauron|github",
        "metadata": {}
    }
    """
    data = request.get_json()
    if not data:
        return jsonify({'error': 'No JSON data'}), 400

    required = ['vm', 'category', 'title', 'message']
    for field in required:
        if field not in data:
            return jsonify({'error': f'Missing field: {field}'}), 400

    # Generate hash for deduplication
    alert_hash = get_alert_hash(data)
    if is_duplicate(alert_hash):
        return jsonify({'status': 'duplicate', 'hash': alert_hash}), 200

    # Map category to ntfy topic
    category = data['category'].lower()
    topic = TOPIC_MAP.get(category, 'system')

    # Map severity to ntfy priority
    severity = data.get('severity', 'warning').lower()
    priority = PRIORITY_MAP.get(severity, 'default')

    # Build notification
    vm = data['vm']
    title = f"{data['title']} [{vm}]"
    message = data['message']

    # Tags based on category
    tags = [category, vm.replace('-', '')]
    if severity in ['emergency', 'alert', 'critical']:
        tags.append('warning')
    if category == 'auth':
        tags.append('lock')
    elif category == 'sauron':
        tags.append('eyes')
    elif category == 'github':
        tags.append('octocat')
    elif category == 'system':
        tags.append('computer')

    # Push to ntfy
    success = push_to_ntfy(
        topic=topic,
        title=title,
        message=message,
        priority=priority,
        tags=tags,
        click=data.get('metadata', {}).get('url')
    )

    # Store in history with ISO timestamp string for consistency
    alert_record = {
        'hash': alert_hash,
        'timestamp': datetime.utcnow().isoformat(),
        'vm': vm,
        'category': category,
        'severity': severity,
        'title': data['title'],
        'message': message[:500],
        'source': data.get('source', 'api'),
        'pushed': success,
    }
    alert_history.append(alert_record)
    cleanup_history()

    return jsonify({
        'status': 'ok' if success else 'failed',
        'hash': alert_hash,
        'topic': topic,
        'priority': priority,
    }), 200 if success else 500


@alerts_bp.route('/list', methods=['GET'])
def list_alerts():
    """List recent alerts"""
    category = request.args.get('category')
    vm = request.args.get('vm')
    limit = min(int(request.args.get('limit', 50)), 500)

    result = alert_history.copy()

    if category:
        result = [a for a in result if a['category'] == category]
    if vm:
        result = [a for a in result if a['vm'] == vm]

    # Sort by timestamp descending - use helper to ensure consistent comparison
    result.sort(key=lambda x: _get_timestamp(x), reverse=True)

    # Ensure all timestamps are strings for JSON serialization
    for a in result:
        if isinstance(a.get('timestamp'), datetime):
            a['timestamp'] = a['timestamp'].isoformat()

    return jsonify({
        'count': len(result[:limit]),
        'alerts': result[:limit]
    })


@alerts_bp.route('/stats', methods=['GET'])
def alert_stats():
    """Get alert statistics"""
    cleanup_history()

    stats = {
        'total': len(alert_history),
        'by_category': {},
        'by_vm': {},
        'by_severity': {},
    }

    for alert in alert_history:
        cat = alert.get('category', 'unknown')
        vm = alert.get('vm', 'unknown')
        sev = alert.get('severity', 'unknown')

        stats['by_category'][cat] = stats['by_category'].get(cat, 0) + 1
        stats['by_vm'][vm] = stats['by_vm'].get(vm, 0) + 1
        stats['by_severity'][sev] = stats['by_severity'].get(sev, 0) + 1

    return jsonify(stats)


@alerts_bp.route('/channels', methods=['GET'])
def list_channels():
    """List available notification channels/topics"""
    return jsonify({
        'channels': [
            {'id': 'github', 'name': 'GitHub', 'icon': '', 'color': '#238636', 'description': 'Repository activity', 'rss_url': 'https://rss.diegonmarcos.com/github/json?poll=1'},
            {'id': 'sauron', 'name': 'Sauron', 'icon': '', 'color': '#f85149', 'description': 'YARA security scans', 'rss_url': 'https://rss.diegonmarcos.com/sauron/json?poll=1'},
            {'id': 'auth', 'name': 'Auth', 'icon': '', 'color': '#a371f7', 'description': 'SSH, sudo, login events', 'rss_url': 'https://rss.diegonmarcos.com/auth/json?poll=1'},
            {'id': 'system', 'name': 'System', 'icon': '', 'color': '#58a6ff', 'description': 'Service errors & crashes', 'rss_url': 'https://rss.diegonmarcos.com/system/json?poll=1'},
            {'id': 'ops', 'name': 'Operations', 'icon': '', 'color': '#d29922', 'description': 'Deployments & restarts', 'rss_url': 'https://rss.diegonmarcos.com/ops/json?poll=1'},
            {'id': 'docker', 'name': 'Docker', 'icon': '', 'color': '#2496ed', 'description': 'Container events', 'rss_url': 'https://rss.diegonmarcos.com/docker/json?poll=1'},
            {'id': 'cron', 'name': 'Cron', 'icon': '', 'color': '#6e7681', 'description': 'Scheduled job events', 'rss_url': 'https://rss.diegonmarcos.com/cron/json?poll=1'},
            {'id': 'backup', 'name': 'Backup', 'icon': '', 'color': '#3fb950', 'description': 'Backup job status', 'rss_url': 'https://rss.diegonmarcos.com/backup/json?poll=1'},
            {'id': 'security', 'name': 'Security', 'icon': '', 'color': '#da3633', 'description': 'Security alerts', 'rss_url': 'https://rss.diegonmarcos.com/security/json?poll=1'},
            {'id': 'deploy', 'name': 'Deploy', 'icon': '', 'color': '#bf8700', 'description': 'Deployment notifications', 'rss_url': 'https://rss.diegonmarcos.com/deploy/json?poll=1'},
        ]
    })


@alerts_bp.route('/test', methods=['POST'])
def test_alert():
    """Send a test alert"""
    topic = request.args.get('topic', 'system')
    success = push_to_ntfy(
        topic=topic,
        title=f'Test {topic} [test]',
        message=f'Test notification from Cloud API at {datetime.utcnow().isoformat()}',
        priority='low',
        tags=['test', topic, 'white_check_mark']
    )
    return jsonify({'status': 'ok' if success else 'failed', 'topic': topic})
