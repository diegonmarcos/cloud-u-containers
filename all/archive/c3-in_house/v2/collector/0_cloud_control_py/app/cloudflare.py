"""
Cloudflare API client for Cloud Control Center
"""

import subprocess
import json
from typing import Dict, List, Optional

from .config_loader import get_cloudflare_config


def _cf_request(endpoint: str, method: str = "GET", data: dict = None) -> Dict:
    """Make Cloudflare API request."""
    config = get_cloudflare_config()
    zone_id = config.get("zone_id", "")
    email = config.get("email", "")
    api_key = config.get("api_key", "")

    url = f"https://api.cloudflare.com/client/v4/zones/{zone_id}/{endpoint}"

    cmd = f'''curl -s -X {method} "{url}" \
        -H "X-Auth-Email: {email}" \
        -H "X-Auth-Key: {api_key}" \
        -H "Content-Type: application/json"'''

    if data:
        cmd += f" -d '{json.dumps(data)}'"

    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return json.loads(result.stdout) if result.stdout else {}
    except:
        return {"success": False, "errors": ["Request failed"]}


def list_dns_records() -> str:
    """List all DNS records (formatted output)."""
    config = get_cloudflare_config()
    zone_id = config.get("zone_id", "")
    email = config.get("email", "")
    api_key = config.get("api_key", "")

    cmd = f'''curl -s "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records" \
        -H "X-Auth-Email: {email}" \
        -H "X-Auth-Key: {api_key}" | \
        jq -r '.result[] | "\\(.type)\\t\\(.name)\\t\\(.content)"' '''

    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return result.stdout.strip() if result.stdout else result.stderr
    except Exception as e:
        return f"Error: {e}"


def list_dns_records_json() -> List[Dict]:
    """List all DNS records as JSON."""
    response = _cf_request("dns_records")
    return response.get("result", [])


def list_rulesets() -> str:
    """List Cloudflare rulesets (formatted output)."""
    config = get_cloudflare_config()
    zone_id = config.get("zone_id", "")
    email = config.get("email", "")
    api_key = config.get("api_key", "")

    cmd = f'''curl -s "https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets" \
        -H "X-Auth-Email: {email}" \
        -H "X-Auth-Key: {api_key}" | jq'''

    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return result.stdout.strip() if result.stdout else result.stderr
    except Exception as e:
        return f"Error: {e}"


def get_dns_record(record_id: str) -> Optional[Dict]:
    """Get specific DNS record."""
    response = _cf_request(f"dns_records/{record_id}")
    return response.get("result")


def create_dns_record(record_type: str, name: str, content: str, proxied: bool = True, ttl: int = 1) -> Dict:
    """Create DNS record."""
    data = {
        "type": record_type,
        "name": name,
        "content": content,
        "proxied": proxied,
        "ttl": ttl
    }
    return _cf_request("dns_records", method="POST", data=data)


def update_dns_record(record_id: str, record_type: str, name: str, content: str, proxied: bool = True) -> Dict:
    """Update DNS record."""
    data = {
        "type": record_type,
        "name": name,
        "content": content,
        "proxied": proxied
    }
    return _cf_request(f"dns_records/{record_id}", method="PUT", data=data)


def delete_dns_record(record_id: str) -> Dict:
    """Delete DNS record."""
    return _cf_request(f"dns_records/{record_id}", method="DELETE")


def purge_cache() -> Dict:
    """Purge all cache."""
    return _cf_request("purge_cache", method="POST", data={"purge_everything": True})
