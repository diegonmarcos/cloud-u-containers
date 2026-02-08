"""
C3 API Routes - Serves Cloud Control Center data from 4.jsons/
Data source: /home/diego/Documents/Git/back-System/cloud/a_solutions/c3/in-house/4.jsons/
"""
import json
from pathlib import Path
from flask import Blueprint, jsonify

c3_bp = Blueprint('c3', __name__)

# Path to C3 JSON output (symlinked or mounted)
C3_DATA_DIR = Path("/app/c3-data")

# Fallback for local development
if not C3_DATA_DIR.exists():
    C3_DATA_DIR = Path(__file__).parent.parent.parent.parent / "c3" / "in-house" / "4.jsons"


def load_c3_json(filename: str) -> dict:
    """Load C3 JSON file."""
    filepath = C3_DATA_DIR / filename
    if filepath.exists():
        return json.loads(filepath.read_text())
    return {"error": f"File not found: {filename}", "path": str(filepath)}


# =============================================================================
# Dashboard (Combined)
# =============================================================================

@c3_bp.route('/dashboard', methods=['GET'])
def get_dashboard():
    """Get combined dashboard data with all alerts."""
    return jsonify(load_c3_json("dashboard.json"))


@c3_bp.route('/alerts', methods=['GET'])
def get_alerts():
    """Get all alerts from all categories."""
    dashboard = load_c3_json("dashboard.json")
    return jsonify({
        "alerts": dashboard.get("alerts", []),
        "status": dashboard.get("status", {})
    })


# =============================================================================
# Security
# =============================================================================

@c3_bp.route('/security', methods=['GET'])
def get_security():
    """Get full security data."""
    return jsonify(load_c3_json("security.json"))


@c3_bp.route('/security/summary', methods=['GET'])
def get_security_summary():
    """Get security summary only."""
    data = load_c3_json("security.json")
    return jsonify({
        "date": data.get("date"),
        "summary": data.get("summary", {}),
        "alerts": data.get("alerts", [])
    })


@c3_bp.route('/security/vms/<vm_name>', methods=['GET'])
def get_security_vm(vm_name: str):
    """Get security data for specific VM."""
    data = load_c3_json("security.json")
    vm_data = data.get("vms", {}).get(vm_name)
    if vm_data:
        return jsonify({"vm": vm_name, **vm_data})
    return jsonify({"error": f"VM not found: {vm_name}"}), 404


@c3_bp.route('/security/failed-ssh', methods=['GET'])
def get_failed_ssh():
    """Get failed SSH attempts across all VMs."""
    data = load_c3_json("security.json")
    all_failed = []
    for vm_name, vm_data in data.get("vms", {}).items():
        for entry in vm_data.get("failed_ssh", []):
            all_failed.append({"vm": vm_name, **entry})
    all_failed.sort(key=lambda x: x.get("count", 0), reverse=True)
    return jsonify({
        "total": data.get("summary", {}).get("total_failed_ssh", 0),
        "by_ip": all_failed[:50]
    })


# =============================================================================
# Performance
# =============================================================================

@c3_bp.route('/performance', methods=['GET'])
def get_performance():
    """Get full performance data."""
    return jsonify(load_c3_json("performance.json"))


@c3_bp.route('/performance/summary', methods=['GET'])
def get_performance_summary():
    """Get performance summary only."""
    data = load_c3_json("performance.json")
    return jsonify({
        "date": data.get("date"),
        "summary": data.get("summary", {}),
        "alerts": data.get("alerts", [])
    })


@c3_bp.route('/performance/vms/<vm_name>', methods=['GET'])
def get_performance_vm(vm_name: str):
    """Get performance data for specific VM."""
    data = load_c3_json("performance.json")
    vm_data = data.get("vms", {}).get(vm_name)
    if vm_data:
        return jsonify({"vm": vm_name, **vm_data})
    return jsonify({"error": f"VM not found: {vm_name}"}), 404


@c3_bp.route('/performance/docker', methods=['GET'])
def get_docker_stats():
    """Get Docker stats across all VMs."""
    data = load_c3_json("performance.json")
    all_containers = []
    for vm_name, vm_data in data.get("vms", {}).items():
        for container in vm_data.get("docker", []):
            all_containers.append({"vm": vm_name, **container})
    return jsonify({"containers": all_containers})


# =============================================================================
# Docker (dedicated)
# =============================================================================

@c3_bp.route('/docker', methods=['GET'])
def get_docker():
    """Get full docker data."""
    return jsonify(load_c3_json("docker.json"))


@c3_bp.route('/docker/vms/<vm_name>', methods=['GET'])
def get_docker_vm(vm_name: str):
    """Get docker data for specific VM."""
    data = load_c3_json("docker.json")
    vm_data = data.get("vms", {}).get(vm_name)
    if vm_data:
        return jsonify({"vm": vm_name, **vm_data})
    return jsonify({"error": f"VM not found: {vm_name}"}), 404


# =============================================================================
# Web/HTTP
# =============================================================================

@c3_bp.route('/web', methods=['GET'])
def get_web():
    """Get full web/HTTP data."""
    return jsonify(load_c3_json("web.json"))


@c3_bp.route('/web/summary', methods=['GET'])
def get_web_summary():
    """Get web summary only."""
    data = load_c3_json("web.json")
    return jsonify({
        "date": data.get("date"),
        "summary": data.get("summary", {}),
        "alerts": data.get("alerts", [])
    })


@c3_bp.route('/web/threats', methods=['GET'])
def get_web_threats():
    """Get web security threats (suspicious requests, scanners)."""
    data = load_c3_json("web.json")
    threats = {
        "suspicious_requests": [],
        "scanner_activity": [],
        "top_error_ips": []
    }
    for vm_name, vm_data in data.get("vms", {}).items():
        for req in vm_data.get("suspicious_requests", [])[:10]:
            threats["suspicious_requests"].append({"vm": vm_name, "request": req})
        for scanner in vm_data.get("scanner_agents", []):
            threats["scanner_activity"].append({"vm": vm_name, **scanner})
        for ip in vm_data.get("top_error_ips", [])[:5]:
            threats["top_error_ips"].append({"vm": vm_name, **ip})
    return jsonify(threats)


@c3_bp.route('/web/top-ips', methods=['GET'])
def get_top_ips():
    """Get top requesting IPs."""
    data = load_c3_json("web.json")
    all_ips = []
    for vm_name, vm_data in data.get("vms", {}).items():
        for ip in vm_data.get("top_ips", []):
            all_ips.append({"vm": vm_name, **ip})
    all_ips.sort(key=lambda x: x.get("count", 0), reverse=True)
    return jsonify({"top_ips": all_ips[:30]})


# =============================================================================
# Availability
# =============================================================================

@c3_bp.route('/availability', methods=['GET'])
def get_availability():
    """Get full availability data."""
    return jsonify(load_c3_json("availability.json"))


@c3_bp.route('/availability/status', methods=['GET'])
def get_availability_status():
    """Get current availability status."""
    data = load_c3_json("availability.json")
    return jsonify({
        "date": data.get("date"),
        "current_status": data.get("current_status", {}),
        "summary": data.get("summary", {}),
        "alerts": data.get("alerts", [])
    })


@c3_bp.route('/availability/endpoints', methods=['GET'])
def get_endpoints_status():
    """Get endpoint status."""
    data = load_c3_json("availability.json")
    return jsonify({
        "endpoints": data.get("current_status", {}).get("endpoints", []),
        "up": data.get("summary", {}).get("endpoints_up", 0),
        "down": data.get("summary", {}).get("endpoints_down", 0)
    })


@c3_bp.route('/availability/ssl', methods=['GET'])
def get_ssl_status():
    """Get SSL certificate status."""
    data = load_c3_json("availability.json")
    return jsonify({
        "certificates": data.get("current_status", {}).get("ssl", []),
        "ok": data.get("summary", {}).get("ssl_ok", 0),
        "warning": data.get("summary", {}).get("ssl_warning", 0),
        "critical": data.get("summary", {}).get("ssl_critical", 0)
    })


@c3_bp.route('/availability/vms', methods=['GET'])
def get_vms_connectivity():
    """Get VM connectivity status."""
    data = load_c3_json("availability.json")
    return jsonify({
        "vms": data.get("current_status", {}).get("vms", []),
        "reachable": data.get("summary", {}).get("vms_reachable", 0),
        "unreachable": data.get("summary", {}).get("vms_unreachable", 0)
    })


# =============================================================================
# Costs
# =============================================================================

@c3_bp.route('/costs', methods=['GET'])
def get_costs():
    """Get full costs data."""
    return jsonify(load_c3_json("costs.json"))


@c3_bp.route('/costs/infra', methods=['GET'])
def get_costs_infra():
    """Get infrastructure costs."""
    data = load_c3_json("costs.json")
    return jsonify({
        "gcp": data.get("gcp", {}),
        "oci": data.get("oci", {}),
        "resources": data.get("resources", {}),
        "summary": data.get("summary", {})
    })


@c3_bp.route('/costs/ai', methods=['GET'])
def get_costs_ai():
    """Get AI/Claude costs."""
    data = load_c3_json("costs.json")
    return jsonify({
        "claude": data.get("claude", {}),
        "summary": {
            "estimated_cost": data.get("claude", {}).get("usage", {}).get("estimated_cost_usd", 0)
        }
    })


# =============================================================================
# Architecture
# =============================================================================

@c3_bp.route('/architecture', methods=['GET'])
def get_architecture():
    """Get full architecture data."""
    return jsonify(load_c3_json("architecture.json"))
