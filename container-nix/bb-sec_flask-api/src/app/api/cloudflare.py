"""Cloudflare DNS, cache, firewall & analytics management."""
import os
import requests
from flask import Blueprint, jsonify, request

cloudflare_bp = Blueprint('cloudflare', __name__)

CF_API_BASE = 'https://api.cloudflare.com/client/v4'


def _cf_headers():
    token = os.environ.get('CF_API_TOKEN', '')
    return {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}


def _zone_id():
    return os.environ.get('CF_ZONE_ID', '')


def _check_config():
    if not os.environ.get('CF_API_TOKEN') or not os.environ.get('CF_ZONE_ID'):
        return jsonify(error='Cloudflare not configured'), 503
    return None


def _zone_url(path=''):
    return f'{CF_API_BASE}/zones/{_zone_id()}{path}'


# ── DNS ──────────────────────────────────────────────────────────────────

@cloudflare_bp.route('/dns', methods=['GET'])
def list_dns():
    """List all DNS records.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: DNS record list}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    resp = requests.get(_zone_url('/dns_records?per_page=100'), headers=_cf_headers(), timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    records = [
        {
            'id': r['id'],
            'type': r['type'],
            'name': r['name'],
            'content': r['content'],
            'proxied': r.get('proxied', False),
            'ttl': r.get('ttl', 1),
        }
        for r in data.get('result', [])
    ]
    return jsonify(status='ok', records=records, count=len(records))


@cloudflare_bp.route('/dns', methods=['POST'])
def create_dns():
    """Create a DNS record.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: DNS record created}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    body = request.get_json(force=True)
    payload = {
        'type': body.get('type', 'A'),
        'name': body.get('name', ''),
        'content': body.get('content', ''),
        'proxied': body.get('proxied', False),
        'ttl': body.get('ttl', 1),
    }
    resp = requests.post(_zone_url('/dns_records'), headers=_cf_headers(), json=payload, timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    r = data['result']
    record = {'id': r['id'], 'type': r['type'], 'name': r['name'],
              'content': r['content'], 'proxied': r.get('proxied', False), 'ttl': r.get('ttl', 1)}
    return jsonify(status='ok', record=record)


@cloudflare_bp.route('/dns/<record_id>', methods=['PUT'])
def update_dns(record_id):
    """Update a DNS record.
    ---
    tags: [Cloudflare]
    parameters:
      - {name: record_id, in: path, type: string, required: true}
    responses:
      200: {description: DNS record updated}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    body = request.get_json(force=True)
    payload = {
        'type': body.get('type', 'A'),
        'name': body.get('name', ''),
        'content': body.get('content', ''),
        'proxied': body.get('proxied', False),
        'ttl': body.get('ttl', 1),
    }
    resp = requests.patch(
        _zone_url(f'/dns_records/{record_id}'), headers=_cf_headers(), json=payload, timeout=15
    )
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    r = data['result']
    record = {'id': r['id'], 'type': r['type'], 'name': r['name'],
              'content': r['content'], 'proxied': r.get('proxied', False), 'ttl': r.get('ttl', 1)}
    return jsonify(status='ok', record=record)


@cloudflare_bp.route('/dns/<record_id>', methods=['DELETE'])
def delete_dns(record_id):
    """Delete a DNS record.
    ---
    tags: [Cloudflare]
    parameters:
      - {name: record_id, in: path, type: string, required: true}
    responses:
      200: {description: DNS record deleted}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    resp = requests.delete(
        _zone_url(f'/dns_records/{record_id}'), headers=_cf_headers(), timeout=15
    )
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    return jsonify(status='ok', deleted=record_id)


# ── Cache ────────────────────────────────────────────────────────────────

@cloudflare_bp.route('/cache/purge', methods=['POST'])
def purge_cache():
    """Purge Cloudflare cache.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: Cache purged}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    body = request.get_json(force=True)
    if body.get('purge_everything'):
        payload = {'purge_everything': True}
    else:
        payload = {'files': body.get('files', [])}
    resp = requests.post(_zone_url('/purge_cache'), headers=_cf_headers(), json=payload, timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    return jsonify(status='ok', message='Cache purged')


# ── Zone ─────────────────────────────────────────────────────────────────

@cloudflare_bp.route('/zone', methods=['GET'])
def zone_info():
    """Get zone details.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: Zone details}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    resp = requests.get(_zone_url(''), headers=_cf_headers(), timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    return jsonify(status='ok', zone=data['result'])


# ── Firewall ─────────────────────────────────────────────────────────────

@cloudflare_bp.route('/firewall', methods=['GET'])
def list_firewall():
    """List firewall rules.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: Firewall rules}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    resp = requests.get(_zone_url('/firewall/rules'), headers=_cf_headers(), timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    rules = [
        {
            'id': r.get('id'),
            'expression': r.get('filter', {}).get('expression', ''),
            'action': r.get('action', ''),
            'description': r.get('description'),
        }
        for r in data.get('result', [])
    ]
    return jsonify(status='ok', rules=rules)


@cloudflare_bp.route('/firewall', methods=['POST'])
def create_firewall():
    """Create a firewall rule.
    ---
    tags: [Cloudflare]
    responses:
      200: {description: Firewall rule created}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    body = request.get_json(force=True)
    payload = [{
        'filter': {'expression': body.get('expression', '')},
        'action': body.get('action', ''),
        'description': body.get('description', ''),
    }]
    resp = requests.post(_zone_url('/firewall/rules'), headers=_cf_headers(), json=payload, timeout=15)
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    return jsonify(status='ok', result=data['result'])


# ── Analytics ────────────────────────────────────────────────────────────

@cloudflare_bp.route('/analytics', methods=['GET'])
def analytics():
    """Get zone analytics (last 24h).
    ---
    tags: [Cloudflare]
    responses:
      200: {description: Zone analytics}
      503: {description: Cloudflare not configured}
    """
    err = _check_config()
    if err:
        return err
    resp = requests.get(
        _zone_url('/analytics/dashboard?since=-1440&until=0'), headers=_cf_headers(), timeout=15
    )
    data = resp.json()
    if not data.get('success'):
        return jsonify(error=str(data.get('errors'))), 502
    return jsonify(status='ok', analytics=data['result'])
