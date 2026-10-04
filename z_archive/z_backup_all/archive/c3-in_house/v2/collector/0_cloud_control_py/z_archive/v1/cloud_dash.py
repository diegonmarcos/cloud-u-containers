#!/usr/bin/env python3
"""
Cloud Infrastructure Dashboard
A unified Python tool for monitoring and managing cloud VMs and services

Modes:
  - TUI Mode: Interactive terminal dashboard
  - Server Mode: Flask API for web dashboard
  - CLI Mode: Quick status output

Version: 6.0.0
Author: Diego Nepomuceno Marcos
Last Updated: 2025-12-03

Usage:
  python cloud_dash.py          # Interactive TUI
  python cloud_dash.py serve    # Start Flask API server
  python cloud_dash.py status   # Quick CLI status
  python cloud_dash.py help     # Show help

Data Source: cloud_dash.json
"""

import json
import os
import subprocess
import sys
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, Any, List
from functools import lru_cache

# =============================================================================
# CONFIGURATION
# =============================================================================

VERSION = "6.9.0"
SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "cloud_dash.json"
FRONTEND_URL = "https://cloud.diegonmarcos.com/cloud_dash.html"

# Server config
SERVER_HOST = '0.0.0.0'
SERVER_PORT = 5000

# GitHub OAuth config
# Create an OAuth App at: https://github.com/settings/developers
# Set callback URL to: https://cloud.diegonmarcos.com/cloud_dash.html
GITHUB_CLIENT_ID = os.environ.get('GITHUB_CLIENT_ID', 'Ov23liOg9JhezyYUCHmS')
GITHUB_CLIENT_SECRET = os.environ.get('GITHUB_CLIENT_SECRET', '66b4c7574336946f42b1b8645010e467c003ec98')
# Allowed GitHub usernames that can perform admin actions (reboot, etc.)
GITHUB_ALLOWED_USERS = os.environ.get('GITHUB_ALLOWED_USERS', 'diegonmarcos').split(',')

# Timeouts (seconds)
SSH_TIMEOUT = 5
PING_TIMEOUT = 2
CURL_TIMEOUT = 5

# ANSI Colors
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[0;33m'
    BLUE = '\033[0;34m'
    MAGENTA = '\033[0;35m'
    CYAN = '\033[0;36m'
    BOLD = '\033[1m'
    DIM = '\033[2m'
    RESET = '\033[0m'

C = Colors()

# =============================================================================
# CONFIG LOADING
# =============================================================================

_config: Optional[Dict[str, Any]] = None

# View mode: 'vm' (by VM parent) or 'category' (by service type)
_view_mode: str = 'vm'

def load_config(force_reload: bool = False) -> Dict[str, Any]:
    """Load and cache the JSON configuration."""
    global _config
    if _config is None or force_reload:
        if not CONFIG_FILE.exists():
            raise FileNotFoundError(f"Config not found: {CONFIG_FILE}")
        with open(CONFIG_FILE, 'r') as f:
            _config = json.load(f)
    return _config

def save_config() -> None:
    """Save the current config back to JSON file."""
    global _config
    if _config is not None:
        with open(CONFIG_FILE, 'w') as f:
            json.dump(_config, f, indent=2)

def update_vm_runtime_status(vm_id: str, online: bool, ping: bool, ssh: bool, ram_percent: Optional[int] = None) -> None:
    """Update VM runtime status in config and save to JSON."""
    config = load_config()
    vm = config.get('virtualMachines', {}).get(vm_id)
    if vm:
        if 'runtimeStatus' not in vm:
            vm['runtimeStatus'] = {}
        vm['runtimeStatus']['online'] = online
        vm['runtimeStatus']['ping'] = ping
        vm['runtimeStatus']['ssh'] = ssh
        vm['runtimeStatus']['ramPercent'] = ram_percent
        vm['runtimeStatus']['lastCheck'] = datetime.now().isoformat()
        save_config()

def update_all_vm_runtime_status() -> None:
    """Check and update runtime status for all VMs."""
    for vm_id in get_vm_ids():
        ip = get_vm(vm_id, 'network.publicIp')
        if ip == 'pending':
            update_vm_runtime_status(vm_id, online=False, ping=False, ssh=False)
            continue

        user = get_vm(vm_id, 'ssh.user')
        key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

        ssh_ok = check_ssh(ip, user, key_path)
        ping_ok = check_ping(ip) if not ssh_ok else True
        ram_pct = get_vm_ram_percent(vm_id) if ssh_ok else None

        update_vm_runtime_status(
            vm_id,
            online=ssh_ok,
            ping=ping_ok,
            ssh=ssh_ok,
            ram_percent=ram_pct
        )

def get_vm_ids() -> List[str]:
    """Get all VM IDs."""
    return list(load_config().get('virtualMachines', {}).keys())

def get_vm_ids_by_category(category: str) -> List[str]:
    """Get VM IDs filtered by category."""
    vms = load_config().get('virtualMachines', {})
    return [k for k, v in vms.items() if v.get('category') == category]

def get_vm_categories() -> List[str]:
    """Get all VM category IDs."""
    return list(load_config().get('vmCategories', {}).keys())

def get_vm_category_name(category: str) -> str:
    """Get VM category display name."""
    return load_config().get('vmCategories', {}).get(category, {}).get('name', category)

def get_vm(vm_id: str, prop: str = None) -> Any:
    """Get VM data or specific property."""
    vm = load_config().get('virtualMachines', {}).get(vm_id, {})
    if prop is None:
        return vm

    # Navigate nested properties like ".network.publicIp"
    props = prop.strip('.').split('.')
    result = vm
    for p in props:
        if isinstance(result, dict):
            result = result.get(p)
        else:
            return None
    return result

def get_service_ids() -> List[str]:
    """Get all service IDs."""
    return list(load_config().get('services', {}).keys())

def get_service_ids_by_category(category: str) -> List[str]:
    """Get service IDs filtered by category."""
    svcs = load_config().get('services', {})
    return [k for k, v in svcs.items() if v.get('category') == category]


def get_services_hierarchical() -> List[Dict[str, Any]]:
    """Get services in hierarchical order grouped by parent's category.

    Returns list of dicts with:
    - category: category id
    - category_name: display name
    - services: list of (svc_id, is_child) tuples in display order

    Parent services appear first, followed by their children indented.
    Only parent services (no parentService) or standalone services are used
    to determine category grouping.
    """
    svcs = load_config().get('services', {})
    categories = load_config().get('serviceCategories', {})

    # Build parent -> children map
    children_map = {}  # parent_id -> [child_ids]
    for svc_id, svc_data in svcs.items():
        parent = svc_data.get('parentService')
        if parent:
            if parent not in children_map:
                children_map[parent] = []
            children_map[parent].append(svc_id)

    # Get all parent/standalone services (those without parentService)
    parent_services = {svc_id: svc_data for svc_id, svc_data in svcs.items()
                       if not svc_data.get('parentService')}

    # Group by category (using parent's category)
    result = []
    for cat_id in categories.keys():
        cat_name = categories[cat_id].get('name', cat_id)
        services_in_cat = []

        for svc_id, svc_data in parent_services.items():
            if svc_data.get('category') == cat_id:
                # Add parent service
                services_in_cat.append((svc_id, False))
                # Add its children
                for child_id in children_map.get(svc_id, []):
                    services_in_cat.append((child_id, True))

        if services_in_cat:
            result.append({
                'category': cat_id,
                'category_name': cat_name,
                'services': services_in_cat
            })

    return result


def get_services_by_vm() -> List[Dict[str, Any]]:
    """Get services organized by VM (for VM-centric view).

    Returns list of dicts with:
    - vm_id: VM identifier
    - vm_name: VM display name
    - vm_index: numeric index for reference
    - services: list of (svc_id, is_child) tuples in display order

    Services are grouped under their parent VM, with parent services
    appearing first followed by their children indented.
    """
    config = load_config()
    vms = config.get('virtualMachines', {})
    svcs = config.get('services', {})

    # Build parent -> children map for services
    children_map = {}  # parent_id -> [child_ids]
    for svc_id, svc_data in svcs.items():
        parent = svc_data.get('parentService')
        if parent:
            if parent not in children_map:
                children_map[parent] = []
            children_map[parent].append(svc_id)

    result = []
    vm_index = 0

    # Iterate VMs by category to maintain consistent ordering
    for cat in get_vm_categories():
        for vm_id in get_vm_ids_by_category(cat):
            vm_data = vms.get(vm_id, {})
            vm_name = vm_data.get('name', vm_id)

            # Get services assigned to this VM
            vm_services = vm_data.get('services', [])
            services_in_vm = []

            # Find parent services first (those without parentService or whose parent is not in this VM)
            for svc_id in vm_services:
                svc_data = svcs.get(svc_id, {})
                parent = svc_data.get('parentService')

                # If no parent, or parent is not in this VM's services, it's a top-level service
                if not parent or parent not in vm_services:
                    services_in_vm.append((svc_id, False))
                    # Add its children that are also in this VM
                    for child_id in children_map.get(svc_id, []):
                        if child_id in vm_services:
                            services_in_vm.append((child_id, True))

            if services_in_vm:
                result.append({
                    'vm_id': vm_id,
                    'vm_name': vm_name,
                    'vm_index': vm_index,
                    'services': services_in_vm
                })

            vm_index += 1

    return result


def get_service_categories() -> List[str]:
    """Get all service category IDs."""
    return list(load_config().get('serviceCategories', {}).keys())

def get_service_category_name(category: str) -> str:
    """Get service category display name."""
    return load_config().get('serviceCategories', {}).get(category, {}).get('name', category)

def get_svc(svc_id: str, prop: str = None) -> Any:
    """Get service data or specific property."""
    svc = load_config().get('services', {}).get(svc_id, {})
    if prop is None:
        return svc

    # Navigate nested properties
    props = prop.strip('.').split('.')
    result = svc
    for p in props:
        if isinstance(result, dict):
            result = result.get(p)
        else:
            return None
    return result

def expand_path(path: str) -> str:
    """Expand ~ in paths."""
    if path and path.startswith('~'):
        return os.path.expanduser(path)
    return path or ''

# =============================================================================
# HELPER FUNCTIONS FOR METRICS & COSTS
# =============================================================================

def run_ccusage(args: List[str], timeout: int = 30) -> Dict[str, Any]:
    """Run ccusage CLI and return JSON output."""
    try:
        result = subprocess.run(
            ['ccusage'] + args + ['--json'],
            capture_output=True, text=True, timeout=timeout
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
        return {"error": result.stderr or "Empty response"}
    except subprocess.TimeoutExpired:
        return {"error": f"Timeout after {timeout}s"}
    except FileNotFoundError:
        return {"error": "ccusage not found. Install: npm i -g ccusage"}
    except Exception as e:
        return {"error": str(e)}

def run_ssh_command(vm_id: str, command: str, timeout: int = 10) -> Dict[str, Any]:
    """Run SSH command on VM and return output."""
    vm = get_vm(vm_id)
    if not vm:
        return {"error": f"VM {vm_id} not found"}

    ssh_user = vm.get("ssh", {}).get("user", "ubuntu")
    ssh_host = vm.get("network", {}).get("publicIp")

    if not ssh_host or ssh_host == "pending":
        return {"error": f"VM {vm_id} has no IP"}

    key_path = expand_path(vm.get("ssh", {}).get("keyPath", ""))

    try:
        result = subprocess.run(
            ["ssh", "-i", key_path, "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no",
             f"{ssh_user}@{ssh_host}", command],
            capture_output=True, text=True, timeout=timeout
        )
        return {"output": result.stdout, "error": result.stderr if result.returncode != 0 else None}
    except subprocess.TimeoutExpired:
        return {"error": "SSH timeout"}
    except Exception as e:
        return {"error": str(e)}

def parse_free_output(output: str) -> Optional[Dict[str, Any]]:
    """Parse 'free -m' output to get memory stats."""
    try:
        lines = output.strip().split('\n')
        mem_line = [l for l in lines if l.startswith('Mem:')][0]
        parts = mem_line.split()
        return {
            "total_mb": int(parts[1]),
            "used_mb": int(parts[2]),
            "free_mb": int(parts[3]),
            "available_mb": int(parts[6]) if len(parts) > 6 else int(parts[3]),
            "percent_used": round(int(parts[2]) / int(parts[1]) * 100, 1)
        }
    except:
        return None

def parse_df_output(output: str) -> Optional[Dict[str, Any]]:
    """Parse 'df -h /' output to get disk stats."""
    try:
        lines = output.strip().split('\n')
        data_line = lines[1]
        parts = data_line.split()
        return {
            "total": parts[1],
            "used": parts[2],
            "available": parts[3],
            "percent_used": int(parts[4].replace('%', ''))
        }
    except:
        return None

def parse_uptime_output(output: str) -> Optional[Dict[str, Any]]:
    """Parse 'uptime' output to get load average."""
    try:
        # Format: "16:30:01 up 5 days, 4:23, 1 user, load average: 0.08, 0.03, 0.01"
        load_part = output.split('load average:')[1].strip()
        loads = [float(x.strip().replace(',', '')) for x in load_part.split(',')[:3]]
        return {
            "load_1m": loads[0],
            "load_5m": loads[1],
            "load_15m": loads[2]
        }
    except:
        return None

def parse_docker_stats(output: str) -> List[Dict[str, str]]:
    """Parse docker stats output."""
    if not output:
        return []
    results = []
    for line in output.strip().split('\n'):
        if not line:
            continue
        parts = line.split('\t')
        if len(parts) >= 3:
            results.append({
                "name": parts[0],
                "cpu": parts[1],
                "memory": parts[2]
            })
    return results

# =============================================================================
# HEALTH CHECK FUNCTIONS
# =============================================================================

def check_ping(host: str) -> bool:
    """Check if host responds to ping."""
    try:
        result = subprocess.run(
            ['ping', '-c', '1', '-W', str(PING_TIMEOUT), host],
            capture_output=True,
            timeout=PING_TIMEOUT + 1
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, Exception):
        return False

def check_ssh(host: str, user: str, key_path: str) -> bool:
    """Check if SSH connection is possible."""
    try:
        result = subprocess.run(
            [
                'ssh', '-i', key_path,
                '-o', 'BatchMode=yes',
                '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                '-o', 'StrictHostKeyChecking=no',
                f'{user}@{host}', 'true'
            ],
            capture_output=True,
            timeout=SSH_TIMEOUT + 2
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, Exception):
        return False

def check_http(url: str) -> bool:
    """Check if HTTP endpoint returns success status."""
    if not url or url == 'null':
        return False

    try:
        result = subprocess.run(
            [
                'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                '--connect-timeout', str(CURL_TIMEOUT),
                '--max-time', str(CURL_TIMEOUT + 2),
                url
            ],
            capture_output=True,
            text=True,
            timeout=CURL_TIMEOUT + 5
        )
        code = result.stdout.strip()
        return code.startswith('2') or code.startswith('3')
    except (subprocess.TimeoutExpired, Exception):
        return False

def get_vm_status_dict(vm_id: str) -> Dict:
    """Get VM status as dictionary (for API)."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return {'status': 'pending', 'label': 'PENDING', 'ping': False, 'ssh': False}

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    ssh_ok = check_ssh(ip, user, key_path)
    ping_ok = check_ping(ip) if not ssh_ok else True

    if ssh_ok:
        return {'status': 'online', 'label': 'ONLINE', 'ping': True, 'ssh': True}
    elif ping_ok:
        return {'status': 'no_ssh', 'label': 'NO SSH', 'ping': True, 'ssh': False}
    else:
        return {'status': 'offline', 'label': 'OFFLINE', 'ping': False, 'ssh': False}

def get_vm_status(vm_id: str) -> str:
    """Get formatted VM status string (for TUI)."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return f"{C.YELLOW}◐ PENDING{C.RESET}"

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    if check_ssh(ip, user, key_path):
        return f"{C.GREEN}● ONLINE {C.RESET}"
    elif check_ping(ip):
        return f"{C.YELLOW}◐ NO SSH {C.RESET}"
    else:
        return f"{C.RED}○ OFFLINE{C.RESET}"

def get_vm_ram_percent(vm_id: str) -> Optional[int]:
    """Get RAM usage percentage via SSH."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return None

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    try:
        result = subprocess.run(
            [
                'ssh', '-i', key_path,
                '-o', 'BatchMode=yes',
                '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                '-o', 'StrictHostKeyChecking=no',
                f'{user}@{ip}',
                "free | awk '/^Mem:/{printf \"%.0f\", $3/$2*100}'"
            ],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT + 2
        )
        if result.returncode == 0 and result.stdout.strip():
            return int(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError, Exception):
        pass
    return None

def get_vm_details(vm_id: str) -> Optional[Dict]:
    """Get detailed VM information via SSH."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return None

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    remote_cmd = '''
echo "hostname:$(hostname)"
echo "uptime:$(uptime -p 2>/dev/null || uptime)"
echo "kernel:$(uname -r)"
echo "cpu:$(nproc)"
echo "ram_used:$(free -h | awk '/^Mem:/{print $3}')"
echo "ram_total:$(free -h | awk '/^Mem:/{print $2}')"
echo "ram_percent:$(free | awk '/^Mem:/{printf "%.1f", $3/$2*100}')"
echo "disk_used:$(df -h / | awk 'NR==2{print $3}')"
echo "disk_total:$(df -h / | awk 'NR==2{print $2}')"
echo "containers:$(sudo docker ps -q 2>/dev/null | wc -l)"
'''

    try:
        result = subprocess.run(
            ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
             '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}', remote_cmd],
            capture_output=True, text=True, timeout=SSH_TIMEOUT + 5
        )
        if result.returncode == 0:
            details = {}
            for line in result.stdout.strip().split('\n'):
                if ':' in line:
                    key, value = line.split(':', 1)
                    details[key.strip()] = value.strip()
            return details
    except Exception:
        pass
    return None

def get_svc_status_dict(svc_id: str) -> Dict:
    """Get service status as dictionary (for API)."""
    status = get_svc(svc_id, 'status')

    # Status: on, dev, hold, tbd
    if status in ('dev', 'development', 'planned'):
        return {'status': 'development', 'label': 'DEV', 'healthy': None}
    if status == 'hold':
        return {'status': 'hold', 'label': 'HOLD', 'healthy': None}
    if status == 'tbd':
        return {'status': 'tbd', 'label': 'TBD', 'healthy': None}

    url = get_svc(svc_id, 'urls.health') or get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')

    if not url or url == 'null':
        return {'status': 'no_url', 'label': 'N/A', 'healthy': None}

    healthy = check_http(url)
    return {
        'status': 'healthy' if healthy else 'error',
        'label': 'HEALTHY' if healthy else 'ERROR',
        'healthy': healthy
    }

def get_svc_status(svc_id: str) -> str:
    """Get formatted service status string (for TUI)."""
    status = get_svc(svc_id, 'status')

    # Status: on, dev, hold, tbd
    if status in ('dev', 'development', 'planned'):
        return f"{C.BLUE}◑ DEV    {C.RESET}"
    if status in ('hold',):
        return f"{C.YELLOW}◐ HOLD   {C.RESET}"
    if status in ('tbd',):
        return f"{C.DIM}○ TBD    {C.RESET}"

    url = get_svc(svc_id, 'urls.health') or get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')

    if not url or url == 'null':
        return f"{C.DIM}- N/A    {C.RESET}"

    if check_http(url):
        return f"{C.GREEN}● HEALTHY{C.RESET}"
    else:
        return f"{C.RED}✖ ERROR  {C.RESET}"

def get_container_status(vm_id: str) -> Optional[list]:
    """Get Docker container status on a VM."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return None

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    try:
        result = subprocess.run(
            ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
             '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}',
             'sudo docker ps -a --format "{{.Names}}|{{.Status}}|{{.Ports}}"'],
            capture_output=True, text=True, timeout=SSH_TIMEOUT + 5
        )
        if result.returncode == 0:
            containers = []
            for line in result.stdout.strip().split('\n'):
                if '|' in line:
                    parts = line.split('|')
                    containers.append({
                        'name': parts[0] if len(parts) > 0 else '',
                        'status': parts[1] if len(parts) > 1 else '',
                        'ports': parts[2] if len(parts) > 2 else ''
                    })
            return containers
    except Exception:
        pass
    return None

# =============================================================================
# FLASK API SERVER
# =============================================================================

def run_server(host: str = SERVER_HOST, port: int = SERVER_PORT, debug: bool = False):
    """Run Flask API server."""
    try:
        from flask import Flask, jsonify, request, send_from_directory
    except ImportError:
        print(f"{C.RED}Error: Flask not installed. Run: pip install flask{C.RESET}")
        sys.exit(1)

    app = Flask(__name__)

    # Enable CORS for API endpoints
    @app.after_request
    def add_cors_headers(response):
        # Allow requests from any origin for the dashboard
        origin = request.headers.get('Origin', '*')
        response.headers['Access-Control-Allow-Origin'] = origin
        response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
        response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
        response.headers['Access-Control-Allow-Credentials'] = 'true'
        return response

    @app.route('/api/<path:path>', methods=['OPTIONS'])
    def handle_options(path):
        """Handle CORS preflight requests."""
        return '', 204

    # -------------------------------------------------------------------------
    # Health & Config
    # -------------------------------------------------------------------------

    @app.route('/api/health')
    def api_health():
        return jsonify({'status': 'ok', 'service': 'cloud-dashboard', 'version': VERSION})

    @app.route('/api/config')
    def api_config():
        try:
            return jsonify(load_config())
        except FileNotFoundError as e:
            return jsonify({'error': str(e)}), 404

    @app.route('/api/config/reload', methods=['POST'])
    def api_config_reload():
        try:
            load_config(force_reload=True)
            return jsonify({'status': 'ok', 'message': 'Configuration reloaded'})
        except FileNotFoundError as e:
            return jsonify({'error': str(e)}), 404

    # -------------------------------------------------------------------------
    # VMs
    # -------------------------------------------------------------------------

    @app.route('/api/vms')
    def api_list_vms():
        category = request.args.get('category')
        vm_ids = get_vm_ids_by_category(category) if category else get_vm_ids()

        vms = []
        for vm_id in vm_ids:
            vm_data = get_vm(vm_id)
            vms.append({
                'id': vm_id,
                'name': vm_data.get('name'),
                'provider': vm_data.get('provider'),
                'category': vm_data.get('category'),
                'ip': vm_data.get('network', {}).get('publicIp'),
                'instanceType': vm_data.get('instanceType'),
                'configStatus': vm_data.get('status')
            })
        return jsonify({'vms': vms})

    @app.route('/api/vms/categories')
    def api_vm_categories():
        categories = [{'id': c, 'name': get_vm_category_name(c)} for c in get_vm_categories()]
        return jsonify({'categories': categories})

    @app.route('/api/vms/<vm_id>')
    def api_get_vm(vm_id: str):
        vm_data = get_vm(vm_id)
        if not vm_data:
            return jsonify({'error': f'VM not found: {vm_id}'}), 404
        return jsonify({'id': vm_id, **vm_data})

    @app.route('/api/vms/<vm_id>/status')
    def api_vm_status(vm_id: str):
        vm_data = get_vm(vm_id)
        if not vm_data:
            return jsonify({'error': f'VM not found: {vm_id}'}), 404

        status = get_vm_status_dict(vm_id)
        ram = get_vm_ram_percent(vm_id)

        return jsonify({
            'id': vm_id,
            'name': vm_data.get('name'),
            'ip': vm_data.get('network', {}).get('publicIp'),
            **status,
            'ram_percent': ram
        })

    @app.route('/api/vms/<vm_id>/details')
    def api_vm_details(vm_id: str):
        vm_data = get_vm(vm_id)
        if not vm_data:
            return jsonify({'error': f'VM not found: {vm_id}'}), 404

        details = get_vm_details(vm_id)
        if details is None:
            return jsonify({'error': 'Failed to connect to VM'}), 503

        return jsonify({'id': vm_id, 'name': vm_data.get('name'), 'details': details})

    @app.route('/api/vms/<vm_id>/containers')
    def api_vm_containers(vm_id: str):
        vm_data = get_vm(vm_id)
        if not vm_data:
            return jsonify({'error': f'VM not found: {vm_id}'}), 404

        containers = get_container_status(vm_id)
        if containers is None:
            return jsonify({'error': 'Failed to get container status'}), 503

        return jsonify({'id': vm_id, 'name': vm_data.get('name'), 'containers': containers})

    # -------------------------------------------------------------------------
    # Services
    # -------------------------------------------------------------------------

    @app.route('/api/services')
    def api_list_services():
        category = request.args.get('category')
        svc_ids = get_service_ids_by_category(category) if category else get_service_ids()

        services = []
        for svc_id in svc_ids:
            svc_data = get_svc(svc_id)
            url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
            services.append({
                'id': svc_id,
                'name': svc_data.get('name'),
                'displayName': svc_data.get('displayName'),
                'category': svc_data.get('category'),
                'vmId': svc_data.get('vmId'),
                'url': url,
                'configStatus': svc_data.get('status')
            })
        return jsonify({'services': services})

    @app.route('/api/services/categories')
    def api_service_categories():
        categories = [{'id': c, 'name': get_service_category_name(c)} for c in get_service_categories()]
        return jsonify({'categories': categories})

    @app.route('/api/services/<svc_id>')
    def api_get_service(svc_id: str):
        svc_data = get_svc(svc_id)
        if not svc_data:
            return jsonify({'error': f'Service not found: {svc_id}'}), 404
        return jsonify({'id': svc_id, **svc_data})

    @app.route('/api/services/<svc_id>/status')
    def api_service_status(svc_id: str):
        svc_data = get_svc(svc_id)
        if not svc_data:
            return jsonify({'error': f'Service not found: {svc_id}'}), 404

        status = get_svc_status_dict(svc_id)
        url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')

        return jsonify({
            'id': svc_id,
            'name': svc_data.get('name'),
            'displayName': svc_data.get('displayName'),
            'url': url,
            **status
        })

    # -------------------------------------------------------------------------
    # Dashboard Summary
    # -------------------------------------------------------------------------

    @app.route('/api/dashboard/summary')
    def api_dashboard_summary():
        """Full summary with health checks."""
        vm_summary = []
        for cat_id in get_vm_categories():
            cat_vms = []
            for vm_id in get_vm_ids_by_category(cat_id):
                vm_data = get_vm(vm_id)
                status = get_vm_status_dict(vm_id)
                ram = get_vm_ram_percent(vm_id)
                cat_vms.append({
                    'id': vm_id,
                    'name': vm_data.get('name'),
                    'ip': vm_data.get('network', {}).get('publicIp'),
                    'instanceType': vm_data.get('instanceType'),
                    **status,
                    'ram_percent': ram
                })
            if cat_vms:
                vm_summary.append({
                    'category': cat_id,
                    'categoryName': get_vm_category_name(cat_id),
                    'vms': cat_vms
                })

        svc_summary = []
        for cat_id in get_service_categories():
            cat_svcs = []
            for svc_id in get_service_ids_by_category(cat_id):
                svc_data = get_svc(svc_id)
                status = get_svc_status_dict(svc_id)
                url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
                cat_svcs.append({
                    'id': svc_id,
                    'name': svc_data.get('name'),
                    'displayName': svc_data.get('displayName'),
                    'url': url,
                    **status
                })
            if cat_svcs:
                svc_summary.append({
                    'category': cat_id,
                    'categoryName': get_service_category_name(cat_id),
                    'services': cat_svcs
                })

        return jsonify({'vms': vm_summary, 'services': svc_summary})

    @app.route('/api/dashboard/quick-status')
    def api_quick_status():
        """Quick status from config only (no health checks)."""
        vms = []
        for vm_id in get_vm_ids():
            vm_data = get_vm(vm_id)
            vms.append({
                'id': vm_id,
                'name': vm_data.get('name'),
                'ip': vm_data.get('network', {}).get('publicIp'),
                'provider': vm_data.get('provider'),
                'category': vm_data.get('category'),
                'configStatus': vm_data.get('status')
            })

        services = []
        for svc_id in get_service_ids():
            svc_data = get_svc(svc_id)
            url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin')
            services.append({
                'id': svc_id,
                'name': svc_data.get('name'),
                'displayName': svc_data.get('displayName'),
                'category': svc_data.get('category'),
                'vmId': svc_data.get('vmId'),
                'url': url,
                'configStatus': svc_data.get('status')
            })

        return jsonify({'vms': vms, 'services': services})

    @app.route('/api/providers')
    def api_providers():
        return jsonify({'providers': load_config().get('providers', {})})

    @app.route('/api/domains')
    def api_domains():
        return jsonify(load_config().get('domains', {}))

    # -------------------------------------------------------------------------
    # Cost API Endpoints
    # -------------------------------------------------------------------------

    @app.route('/api/costs/infra')
    def api_costs_infra():
        """Get infrastructure costs from config."""
        config = load_config()
        return jsonify(config.get("costs", {}).get("infra", {}))

    @app.route('/api/costs/ai/now')
    def api_costs_ai_now():
        """Current 5h block with projections."""
        return jsonify(run_ccusage(['blocks', '-a']))

    @app.route('/api/costs/ai/daily')
    def api_costs_ai_daily():
        """Daily breakdown with model costs."""
        return jsonify(run_ccusage(['daily', '-b']))

    @app.route('/api/costs/ai/weekly')
    def api_costs_ai_weekly():
        """Weekly aggregation."""
        return jsonify(run_ccusage(['weekly', '-b']))

    @app.route('/api/costs/ai/monthly')
    def api_costs_ai_monthly():
        """Monthly totals."""
        return jsonify(run_ccusage(['monthly', '-b']))

    # -------------------------------------------------------------------------
    # Wake-on-Demand API Endpoints
    # -------------------------------------------------------------------------

    @app.route('/api/wake/status')
    def api_wake_status():
        """Check if dormant VM is running."""
        config = load_config()
        wake_config = config.get("wakeOnDemand", {})
        target_vm = wake_config.get("targetVm", "oracle-dev-server")

        # Get VM details from config
        vm = config.get("virtualMachines", {}).get(target_vm, {})
        oci_instance_id = vm.get("ociInstanceId")

        if not oci_instance_id:
            return jsonify({
                "vm": target_vm,
                "state": "UNKNOWN",
                "message": "No OCI instance ID configured"
            })

        # Try to check OCI instance state using OCI CLI
        # This requires OCI CLI to be configured with proper credentials
        try:
            import subprocess
            result = subprocess.run(
                ['oci', 'compute', 'instance', 'get', '--instance-id', oci_instance_id, '--query', 'data."lifecycle-state"', '--raw-output'],
                capture_output=True,
                text=True,
                timeout=10
            )

            if result.returncode == 0:
                state = result.stdout.strip()
                return jsonify({
                    "vm": target_vm,
                    "state": state,
                    "ociInstanceId": oci_instance_id,
                    "message": f"VM is {state.lower()}"
                })
            else:
                return jsonify({
                    "vm": target_vm,
                    "state": "ERROR",
                    "message": "Failed to check OCI instance state",
                    "error": result.stderr
                })
        except Exception as e:
            return jsonify({
                "vm": target_vm,
                "state": "ERROR",
                "message": str(e)
            })

    @app.route('/api/wake/trigger', methods=['POST'])
    def api_wake_trigger():
        """Trigger VM wake via OCI Function or OCI CLI."""
        config = load_config()
        wake_config = config.get("wakeOnDemand", {})
        target_vm = wake_config.get("targetVm", "oracle-dev-server")

        # Get VM details from config
        vm = config.get("virtualMachines", {}).get(target_vm, {})
        oci_instance_id = vm.get("ociInstanceId")

        if not oci_instance_id:
            return jsonify({
                "success": False,
                "message": "No OCI instance ID configured"
            }), 400

        # Try to start the instance using OCI CLI
        try:
            import subprocess
            result = subprocess.run(
                ['oci', 'compute', 'instance', 'action', '--instance-id', oci_instance_id, '--action', 'START'],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                return jsonify({
                    "success": True,
                    "vm": target_vm,
                    "ociInstanceId": oci_instance_id,
                    "message": "Wake command sent successfully",
                    "estimatedWakeTime": wake_config.get("wakeTimeSeconds", 60)
                })
            else:
                return jsonify({
                    "success": False,
                    "message": "Failed to start instance",
                    "error": result.stderr
                }), 500
        except Exception as e:
            return jsonify({
                "success": False,
                "message": f"Error triggering wake: {str(e)}"
            }), 500

    # -------------------------------------------------------------------------
    # Metrics API Endpoints
    # -------------------------------------------------------------------------

    @app.route('/api/metrics/vms')
    def api_metrics_vms():
        """Get metrics for all active VMs."""
        config = load_config()
        vms = config.get("virtualMachines", {})
        results = {}

        for vm_id, vm in vms.items():
            if vm.get("status") not in ["active", "on"]:
                continue

            ip = vm.get("network", {}).get("publicIp")
            if not ip or ip == "pending":
                continue

            # Collect metrics via SSH
            memory = run_ssh_command(vm_id, "free -m")
            disk = run_ssh_command(vm_id, "df -h /")
            load = run_ssh_command(vm_id, "uptime")
            docker = run_ssh_command(vm_id, "sudo docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'")

            results[vm_id] = {
                "name": vm.get("name"),
                "ip": ip,
                "memory": parse_free_output(memory.get("output", "")) if not memory.get("error") else None,
                "disk": parse_df_output(disk.get("output", "")) if not disk.get("error") else None,
                "load": parse_uptime_output(load.get("output", "")) if not load.get("error") else None,
                "containers": parse_docker_stats(docker.get("output", "")) if not docker.get("error") else [],
                "error": memory.get("error") or disk.get("error") or load.get("error")
            }

        return jsonify(results)

    @app.route('/api/metrics/vms/<vm_id>')
    def api_metrics_vm(vm_id: str):
        """Get metrics for single VM."""
        config = load_config()
        vm = config.get("virtualMachines", {}).get(vm_id)

        if not vm:
            return jsonify({"error": f"VM {vm_id} not found"}), 404

        memory = run_ssh_command(vm_id, "free -m")
        disk = run_ssh_command(vm_id, "df -h /")
        load = run_ssh_command(vm_id, "uptime")
        docker = run_ssh_command(vm_id, "sudo docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'")

        return jsonify({
            "vm_id": vm_id,
            "name": vm.get("name"),
            "memory": parse_free_output(memory.get("output", "")) if not memory.get("error") else {"error": memory.get("error")},
            "disk": parse_df_output(disk.get("output", "")) if not disk.get("error") else {"error": disk.get("error")},
            "load": parse_uptime_output(load.get("output", "")) if not load.get("error") else {"error": load.get("error")},
            "containers": parse_docker_stats(docker.get("output", "")) if not docker.get("error") else {"error": docker.get("error")}
        })

    @app.route('/api/metrics/services/<service_id>')
    def api_metrics_service(service_id: str):
        """Get metrics for a specific Docker container."""
        config = load_config()
        service = config.get("services", {}).get(service_id)

        if not service:
            return jsonify({"error": f"Service {service_id} not found"}), 404

        # Find which VM runs this service
        for vm_id, vm in config.get("virtualMachines", {}).items():
            if service_id in vm.get("services", []):
                container_name = service.get("deployment", {}).get("containerName", service_id)
                stats = run_ssh_command(vm_id, f"sudo docker stats --no-stream --format 'json' {container_name}")

                if stats.get("error"):
                    return jsonify({"error": stats.get("error")}), 500

                try:
                    return jsonify(json.loads(stats.get("output", "{}")))
                except:
                    return jsonify({"raw": stats.get("output")})

        return jsonify({"error": "Service VM not found"}), 404

    @app.route('/api/capacity')
    def api_capacity():
        """Get infrastructure capacity assessment."""
        config = load_config()
        estimates = config.get("resourceEstimates", {})

        return jsonify({
            "vms": {
                "oracle-web-server-1": {
                    "total_ram_mb": 1024,
                    "estimated_used": estimates.get("vmAllocations", {}).get("oracle-web-server-1", {}).get("ram", {}),
                    "services": config.get("virtualMachines", {}).get("oracle-web-server-1", {}).get("services", []),
                    "status": "AT_LIMIT"
                },
                "oracle-services-server-1": {
                    "total_ram_mb": 1024,
                    "estimated_used": estimates.get("vmAllocations", {}).get("oracle-services-server-1", {}).get("ram", {}),
                    "services": config.get("virtualMachines", {}).get("oracle-services-server-1", {}).get("services", []),
                    "status": "CLOSE"
                },
                "gcloud-arch-1": {
                    "total_ram_mb": 1024,
                    "estimated_used": estimates.get("vmAllocations", {}).get("gcloud-arch-1", {}).get("ram", {}),
                    "services": config.get("virtualMachines", {}).get("gcloud-arch-1", {}).get("services", []),
                    "status": "DEV"
                },
                "oracle-arm-server": {
                    "total_ram_mb": 24576,
                    "estimated_used": estimates.get("vmAllocations", {}).get("oracle-arm-server", {}).get("ram", {}),
                    "services": config.get("virtualMachines", {}).get("oracle-arm-server", {}).get("services", []),
                    "status": "HOLD"
                }
            },
            "summary": {
                "nonAi": estimates.get("nonAi", {}),
                "ai": estimates.get("ai", {})
            },
            "recommendations": [
                "oracle-web-server-1 is at RAM limit - consider moving services",
                "gcloud-arch-1 needs deployment (mail, terminal)",
                "oracle-arm-server waiting for Oracle approval (AI workloads)"
            ]
        })

    # -------------------------------------------------------------------------
    # GitHub OAuth & Authentication
    # -------------------------------------------------------------------------

    @app.route('/api/auth/callback')
    def api_github_callback():
        """Exchange GitHub OAuth code for access token and redirect back to frontend."""
        import requests as req
        from urllib.parse import urlencode

        code = request.args.get('code')
        frontend_url = FRONTEND_URL

        if not code:
            return f'<script>window.location.href="{frontend_url}?error=no_code";</script>'

        if not GITHUB_CLIENT_ID or not GITHUB_CLIENT_SECRET:
            return f'<script>window.location.href="{frontend_url}?error=not_configured";</script>'

        # Exchange code for access token
        try:
            token_response = req.post(
                'https://github.com/login/oauth/access_token',
                headers={'Accept': 'application/json'},
                data={
                    'client_id': GITHUB_CLIENT_ID,
                    'client_secret': GITHUB_CLIENT_SECRET,
                    'code': code
                },
                timeout=10
            )
            token_data = token_response.json()

            if 'error' in token_data:
                return f'<script>window.location.href="{frontend_url}?error=oauth_failed";</script>'

            access_token = token_data.get('access_token')
            if not access_token:
                return f'<script>window.location.href="{frontend_url}?error=no_token";</script>'

            # Get user info
            user_response = req.get(
                'https://api.github.com/user',
                headers={
                    'Authorization': f'Bearer {access_token}',
                    'Accept': 'application/json'
                },
                timeout=10
            )
            user_data = user_response.json()

            # Check if user is allowed
            username = user_data.get('login', '')
            is_admin = username in GITHUB_ALLOWED_USERS

            # Redirect back to frontend with token in URL fragment (not query param for security)
            import json
            user_json = json.dumps({
                'login': username,
                'avatar_url': user_data.get('avatar_url', ''),
                'name': user_data.get('name', ''),
                'is_admin': is_admin
            })

            # Use JavaScript to store in localStorage and redirect
            return f'''
            <script>
                localStorage.setItem('github_token', '{access_token}');
                localStorage.setItem('github_user', '{user_json}');
                window.location.href = '{frontend_url}';
            </script>
            '''

        except Exception as e:
            return f'<script>window.location.href="{frontend_url}?error=exception";</script>'

    def verify_github_token(token: str) -> Optional[Dict]:
        """Verify GitHub token and return user info if valid and authorized."""
        import requests as req

        if not token:
            return None

        try:
            response = req.get(
                'https://api.github.com/user',
                headers={
                    'Authorization': f'Bearer {token}',
                    'Accept': 'application/json'
                },
                timeout=10
            )
            if response.status_code != 200:
                return None

            user_data = response.json()
            username = user_data.get('login', '')

            if username not in GITHUB_ALLOWED_USERS:
                return None

            return user_data
        except Exception:
            return None

    # -------------------------------------------------------------------------
    # VM Actions (Authenticated)
    # -------------------------------------------------------------------------

    @app.route('/api/vm/<vm_id>/reboot', methods=['POST'])
    def api_vm_reboot(vm_id: str):
        """Reboot a VM (requires GitHub authentication)."""
        # Check authorization
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization required'}), 401

        token = auth_header[7:]  # Remove 'Bearer ' prefix
        user = verify_github_token(token)
        if not user:
            return jsonify({'error': 'Invalid token or unauthorized user'}), 403

        # Get VM info
        vm_data = get_vm(vm_id)
        if not vm_data:
            return jsonify({'error': f'VM not found: {vm_id}'}), 404

        ip = get_vm(vm_id, 'network.publicIp')
        if ip == 'pending':
            return jsonify({'error': 'VM IP is pending'}), 400

        user_ssh = get_vm(vm_id, 'ssh.user')
        key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

        # Execute reboot
        try:
            subprocess.run(
                ['ssh', '-i', key_path,
                 '-o', 'BatchMode=yes',
                 '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                 '-o', 'StrictHostKeyChecking=no',
                 f'{user_ssh}@{ip}', 'sudo reboot'],
                capture_output=True,
                timeout=SSH_TIMEOUT + 5
            )
            return jsonify({
                'status': 'ok',
                'message': f'Reboot signal sent to {vm_id}',
                'vm': vm_id,
                'initiated_by': user.get('login')
            })
        except subprocess.TimeoutExpired:
            # Timeout is expected as connection drops during reboot
            return jsonify({
                'status': 'ok',
                'message': f'Reboot signal sent to {vm_id}',
                'vm': vm_id,
                'initiated_by': user.get('login')
            })
        except Exception as e:
            return jsonify({'error': f'Failed to reboot: {str(e)}'}), 500

    # -------------------------------------------------------------------------
    # Root redirect to frontend
    # -------------------------------------------------------------------------

    @app.route('/')
    def root_redirect():
        """Redirect to the frontend dashboard."""
        return f'<script>window.location.href="{FRONTEND_URL}";</script>'

    # -------------------------------------------------------------------------
    # Run Server
    # -------------------------------------------------------------------------

    print(f"{C.CYAN}Starting Cloud Dashboard Server v{VERSION}{C.RESET}")
    print(f"{C.GREEN}  API:       http://{host}:{port}/api/health{C.RESET}")
    print(f"{C.GREEN}  Dashboard: http://{host}:{port}/dashboard{C.RESET}")
    print(f"{C.DIM}  Config:    {CONFIG_FILE}{C.RESET}")
    print()

    app.run(host=host, port=port, debug=debug)

# =============================================================================
# TUI HELPERS
# =============================================================================

def cls():
    """Clear screen."""
    print('\033[2J\033[H', end='')

def hline(width: int = 78, char: str = '-') -> str:
    """Create horizontal line."""
    return char * width

def wait_key():
    """Wait for user input."""
    input(f"\n{C.DIM}Press Enter to continue...{C.RESET}")

def confirm(message: str) -> bool:
    """Ask for confirmation."""
    response = input(f"{C.YELLOW}{message} [y/N]: {C.RESET}").strip().lower()
    return response in ('y', 'yes')

def move_cursor(row: int, col: int):
    """Move cursor to position (1-indexed)."""
    print(f"\033[{row};{col}H", end='', flush=True)

def save_cursor():
    """Save cursor position."""
    print("\033[s", end='', flush=True)

def restore_cursor():
    """Restore cursor position."""
    print("\033[u", end='', flush=True)

def hide_cursor():
    """Hide cursor."""
    print("\033[?25l", end='', flush=True)

def show_cursor():
    """Show cursor."""
    print("\033[?25h", end='', flush=True)

# Global tracking for status box positions
_status_positions: Dict[str, tuple] = {}  # id -> (row, col)
_current_row: int = 1

# =============================================================================
# TUI DISPLAY FUNCTIONS - Render then Update Pattern
# =============================================================================

# Status box placeholder (9 chars wide to match column)
CHECKING = f"{C.DIM}checking.{C.RESET}"

def get_mode_badge(status: str) -> str:
    """Get colored mode badge."""
    if status in ('on', 'active'):
        return f"{C.GREEN}ON  {C.RESET}"
    elif status in ('dev', 'development', 'planned'):
        return f"{C.BLUE}DEV {C.RESET}"
    elif status == 'hold':
        return f"{C.YELLOW}HOLD{C.RESET}"
    elif status == 'tbd':
        return f"{C.DIM}TBD {C.RESET}"
    else:
        return f"{C.DIM}--- {C.RESET}"

def get_vm_role(vm_id: str) -> str:
    """Get VM role/purpose from config."""
    # Map VMs to their primary roles based on services
    roles = {
        'gcloud-arch-1': 'NPM Proxy',
        'oracle-web-server-1': 'Mail',
        'oracle-services-server-1': 'Matomo',
        'oracle-dev-server': 'Dev Services',
        'oracle-arm-server': 'AI/ML',
    }
    return roles.get(vm_id, '-')[:12]

def render_dashboard():
    """Render full dashboard structure with placeholder status boxes.
    Returns dict mapping item IDs to their status box (row, col) positions.
    """
    global _status_positions, _current_row
    _status_positions = {}
    _current_row = 1

    cls()
    hide_cursor()

    # Table width = 118 (matches Services table - the widest, with checkbox)
    W = 118

    # Header
    print()
    print(f"  {C.BOLD}{C.CYAN}+{'=' * W}+{C.RESET}")
    title = f"CLOUD INFRASTRUCTURE DASHBOARD v{VERSION}"
    padding = (W - len(title)) // 2
    print(f"  {C.BOLD}{C.CYAN}|{C.RESET}{' ' * padding}{title}{' ' * (W - padding - len(title))}{C.BOLD}{C.CYAN}|{C.RESET}")
    print(f"  {C.BOLD}{C.CYAN}+{'=' * W}+{C.RESET}")
    print()
    _current_row = 5

    # =========================================================================
    # VMs TABLE - Fixed widths (total inner width = 110)
    # | ☐ | # | SVC | MODE | NAME                 | IP              | RAM    | VRAM   | STORAGE | MEM%  | DISK% | STATUS    |
    # | 1 | 1 | 3   | 4    | 20                   | 15              | 6      | 6      | 7       | 5     | 5     | 10        |
    # Borders: 12 pipes x 1 = 12, spaces already in format
    # =========================================================================
    VM_TABLE_W = 110
    print(f"  {C.BOLD}+{'-' * VM_TABLE_W}+{C.RESET}")
    print(f"  {C.BOLD}| {'VIRTUAL MACHINES':<{VM_TABLE_W-2}} |{C.RESET}")
    print(f"  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+")
    print(f"  | ☐ | # | SVC | MODE | NAME                 | IP              | RAM    | VRAM   | STORAGE | MEM%  | DISK% | STATUS   |")
    print(f"  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+")
    _current_row += 5

    # Build VM index mapping for services to reference
    vm_index = 0
    _vm_index_map = {}  # vm_id -> index number

    for cat in get_vm_categories():
        vms = get_vm_ids_by_category(cat)
        if not vms:
            continue

        cat_name = get_vm_category_name(cat)
        print(f"  {C.BOLD}{C.MAGENTA}| {cat_name:<{VM_TABLE_W-2}} |{C.RESET}")
        _current_row += 1

        for vm_id in vms:
            vm_data = get_vm(vm_id)
            name = (vm_data.get('name') or '')[:20]
            ip = (vm_data.get('network', {}).get('publicIp') or '')[:15]
            status_cfg = vm_data.get('status', 'on')

            # Get specs from VM data
            specs = vm_data.get('specs', {})
            ram = specs.get('ram', '-')[:6]
            vram = specs.get('vram', '-')[:6]
            storage = specs.get('storage', '-')[:7]
            mem_pct = '-'   # Will be updated live
            disk_pct = '-'  # Will be updated live

            # Store VM index
            _vm_index_map[vm_id] = vm_index

            # Checkbox (unchecked by default)
            checkbox = "☐"

            # Service column placeholder (for alignment with services table)
            svc_col = "-"

            # Mode badge (4 visible chars, padded to fit 4-char cell)
            if status_cfg in ('on', 'active'):
                mode_str = f"{C.GREEN}ON{C.RESET}"
            elif status_cfg in ('dev', 'development', 'planned'):
                mode_str = f"{C.BLUE}DEV{C.RESET}"
            elif status_cfg == 'hold':
                mode_str = f"{C.YELLOW}HOLD{C.RESET}"
            elif status_cfg == 'pending':
                mode_str = f"{C.YELLOW}PEND{C.RESET}"
            else:
                mode_str = "---"

            # Mode visible text (for padding calculation)
            mode_visible = "ON" if status_cfg in ('on', 'active') else \
                          "DEV" if status_cfg in ('dev', 'development', 'planned') else \
                          "HOLD" if status_cfg == 'hold' else \
                          "PEND" if status_cfg == 'pending' else "---"
            mode_pad = 4 - len(mode_visible)

            # Build row - matching header widths exactly:
            # | ☐ | # | SVC | MODE | NAME                 | IP              | RAM    | VRAM   | STORAGE | MEM%  | DISK% | STATUS   |
            # | 1 | 1 | 3   | 4    | 20                   | 15              | 6      | 6      | 7       | 5     | 5     | 8        |
            row_str = f"  | {checkbox} | {vm_index} | {svc_col:<3} | {mode_str}{' ' * mode_pad} | {name:<20} | {ip:<15} | {ram:<6} | {vram:<6} | {storage:<7} | {mem_pct:<5} | {disk_pct:<5} |          |"
            print(row_str)

            # Status column position: calculate from left edge to status cell
            # 2 (indent) + 4 (☐|) + 4 (#|) + 6 (SVC|) + 7 (MODE|) + 23 (NAME|) + 18 (IP|) + 9 (RAM|) + 9 (VRAM|) + 10 (STORAGE|) + 8 (MEM%|) + 8 (DISK%|) = 106
            _status_positions[f"vm:{vm_id}"] = (_current_row, 106)
            _current_row += 1
            vm_index += 1

    print(f"  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+")
    print()
    _current_row += 2

    # =========================================================================
    # SERVICES TABLE - Fixed widths (total inner width = 116)
    # | ☐ | #  | VM | MODE | NAME                 | URL                        | PROXY ADDRESS        | %MEM  | %DISK | STATUS   |
    # | 1 | 2  | 2  | 4    | 20                   | 26                         | 20                   | 5     | 5     | 8        |
    # View modes: 'category' (by service type) or 'vm' (by VM parent)
    # =========================================================================
    SVC_TABLE_W = 116
    view_label = "BY SERVICE TYPE" if _view_mode == 'category' else "BY VM"
    header_text = f"SERVICES ({view_label}) [V] to toggle"
    print(f"  {C.BOLD}+{'-' * SVC_TABLE_W}+{C.RESET}")
    print(f"  {C.BOLD}| {header_text:<{SVC_TABLE_W-2}} |{C.RESET}")
    print(f"  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+")
    print(f"  | ☐ | #  | VM | MODE | NAME                 | URL                        | PROXY ADDRESS        | %MEM  | %DISK | STATUS   |")
    print(f"  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+")
    _current_row += 5

    # Service index counter (a, b, c, ...)
    svc_index = 0

    # Choose data source based on view mode
    if _view_mode == 'vm':
        # VM-centric view: services grouped by VM
        for vm_data in get_services_by_vm():
            vm_name = vm_data['vm_name']
            vm_idx = vm_data['vm_index']
            services = vm_data['services']  # list of (svc_id, is_child) tuples

            if not services:
                continue

            # VM header row
            vm_header = f"VM {vm_idx}: {vm_name}"
            print(f"  {C.BOLD}{C.CYAN}| {vm_header:<{SVC_TABLE_W-2}} |{C.RESET}")
            _current_row += 1

            for svc_id, is_child in services:
                svc_data = get_svc(svc_id)
                raw_name = svc_data.get('displayName') or svc_data.get('name') or svc_id

                # Indent child services
                if is_child:
                    display_name = f"  └─ {raw_name}"[:20]
                else:
                    display_name = raw_name[:20]

                status_cfg = svc_data.get('status', 'on')
                vm_ref = str(vm_idx)

                # URL
                url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin') or ''
                if url and url != 'null':
                    short_url = url.replace('https://', '').replace('http://', '')[:26]
                else:
                    short_url = '-'

                # Proxy Address
                proxy_addr = svc_data.get('network', {}).get('proxyAddress', '-')[:20]
                mem_pct = '-'
                disk_pct = '-'

                # Service index
                if svc_index < 26:
                    svc_letter = chr(ord('a') + svc_index)
                else:
                    first = chr(ord('a') + (svc_index - 26) // 26)
                    second = chr(ord('a') + (svc_index - 26) % 26)
                    svc_letter = f"{first}{second}"

                checkbox = "☐"

                # Mode badge
                if status_cfg in ('on', 'active'):
                    mode_str = f"{C.GREEN}ON{C.RESET}"
                elif status_cfg in ('dev', 'development', 'planned'):
                    mode_str = f"{C.BLUE}DEV{C.RESET}"
                elif status_cfg == 'hold':
                    mode_str = f"{C.YELLOW}HOLD{C.RESET}"
                else:
                    mode_str = "---"

                mode_visible = "ON" if status_cfg in ('on', 'active') else \
                              "DEV" if status_cfg in ('dev', 'development', 'planned') else \
                              "HOLD" if status_cfg == 'hold' else "---"
                mode_pad = 4 - len(mode_visible)

                row_str = f"  | {checkbox} | {svc_letter:<2} | {vm_ref:<2} | {mode_str}{' ' * mode_pad} | {display_name:<20} | {short_url:<26} | {proxy_addr:<20} | {mem_pct:<5} | {disk_pct:<5} |          |"
                print(row_str)

                _status_positions[f"svc:{svc_id}"] = (_current_row, 112)
                _current_row += 1
                svc_index += 1
    else:
        # Category view: services grouped by service type (original behavior)
        for cat_data in get_services_hierarchical():
            cat_name = cat_data['category_name']
            services = cat_data['services']  # list of (svc_id, is_child) tuples

            if not services:
                continue

            print(f"  {C.BOLD}{C.MAGENTA}| {cat_name:<{SVC_TABLE_W-2}} |{C.RESET}")
            _current_row += 1

            for svc_id, is_child in services:
                svc_data = get_svc(svc_id)
                raw_name = svc_data.get('displayName') or svc_data.get('name') or svc_id

                # Indent child services
                if is_child:
                    display_name = f"  └─ {raw_name}"[:20]
                else:
                    display_name = raw_name[:20]

                status_cfg = svc_data.get('status', 'on')

                # VM reference - get VM index from the map
                vm_id = svc_data.get('vmId', '')
                vm_ref = str(_vm_index_map.get(vm_id, '-')) if vm_id and vm_id in _vm_index_map else '-'

                # URL
                url = svc_data.get('urls', {}).get('gui') or svc_data.get('urls', {}).get('admin') or ''
                if url and url != 'null':
                    short_url = url.replace('https://', '').replace('http://', '')[:26]
                else:
                    short_url = '-'

                # Proxy Address (container_name:port that NPM routes to)
                proxy_addr = svc_data.get('network', {}).get('proxyAddress', '-')[:20]

                # Resource usage (placeholder for live data)
                mem_pct = '-'
                disk_pct = '-'

                # Service index (a-z, then aa-az, ba-bz, etc.)
                if svc_index < 26:
                    svc_letter = chr(ord('a') + svc_index)
                else:
                    # After z: aa, ab, ..., az, ba, bb, ...
                    first = chr(ord('a') + (svc_index - 26) // 26)
                    second = chr(ord('a') + (svc_index - 26) % 26)
                    svc_letter = f"{first}{second}"

                # Checkbox (unchecked by default)
                checkbox = "☐"

                # Mode badge (4 visible chars, padded to fit 4-char cell)
                if status_cfg in ('on', 'active'):
                    mode_str = f"{C.GREEN}ON{C.RESET}"
                elif status_cfg in ('dev', 'development', 'planned'):
                    mode_str = f"{C.BLUE}DEV{C.RESET}"
                elif status_cfg == 'hold':
                    mode_str = f"{C.YELLOW}HOLD{C.RESET}"
                else:
                    mode_str = "---"

                # Mode visible text (for padding calculation)
                mode_visible = "ON" if status_cfg in ('on', 'active') else \
                              "DEV" if status_cfg in ('dev', 'development', 'planned') else \
                              "HOLD" if status_cfg == 'hold' else "---"
                mode_pad = 4 - len(mode_visible)

                # Build row - matching header widths exactly:
                # | ☐ | #  | VM | MODE | NAME                 | URL                        | PROXY ADDRESS        | %MEM  | %DISK | STATUS   |
                # | 1 | 2  | 2  | 4    | 20                   | 26                         | 20                   | 5     | 5     | 8        |
                row_str = f"  | {checkbox} | {svc_letter:<2} | {vm_ref:<2} | {mode_str}{' ' * mode_pad} | {display_name:<20} | {short_url:<26} | {proxy_addr:<20} | {mem_pct:<5} | {disk_pct:<5} |          |"
                print(row_str)

                # Status column position: 2 + 4 + 5 + 5 + 7 + 23 + 29 + 23 + 8 + 8 = 112
                _status_positions[f"svc:{svc_id}"] = (_current_row, 112)
                _current_row += 1
                svc_index += 1

    print(f"  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+")
    print()
    _current_row += 2

    # Menu
    print(f"  {C.BOLD}+{'-' * W}+{C.RESET}")
    print(f"  {C.BOLD}| {'COMMANDS':<{W-2}} |{C.RESET}")
    print(f"  +{'-' * W}+")
    print(f"  |  {C.CYAN}[1]{C.RESET} VM Details    {C.CYAN}[2]{C.RESET} Containers   {C.CYAN}[3]{C.RESET} Reboot VM    {C.CYAN}[4]{C.RESET} Restart Container    {C.CYAN}[5]{C.RESET} Logs              {C.CYAN}[6]{C.RESET} Stop/Start          |")
    print(f"  |  {C.CYAN}[7]{C.RESET} SSH to VM     {C.CYAN}[8]{C.RESET} Open URL     {C.CYAN}[V]{C.RESET} Toggle View  {C.CYAN}[R]{C.RESET} Refresh      {C.CYAN}[Q]{C.RESET} Quit                                       |")
    print(f"  +{'-' * W}+")
    _current_row += 6

    return _status_positions

def update_status_box(item_id: str, status_text: str):
    """Update a single status box in-place using cursor positioning."""
    if item_id not in _status_positions:
        return

    row, col = _status_positions[item_id]
    save_cursor()
    move_cursor(row, col)
    # Overwrite the 9-char status cell
    print(f"{status_text}", end='', flush=True)
    restore_cursor()

def get_vm_status_display(vm_id: str) -> str:
    """Get formatted VM status (8 chars padded)."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return f"{C.YELLOW}◐ PEND  {C.RESET}"

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    if check_ssh(ip, user, key_path):
        return f"{C.GREEN}● ONLINE{C.RESET}"
    elif check_ping(ip):
        return f"{C.YELLOW}◐ NOSSH {C.RESET}"
    else:
        return f"{C.RED}○ OFF   {C.RESET}"

def get_svc_status_display(svc_id: str) -> str:
    """Get formatted service status (8 chars padded)."""
    status = get_svc(svc_id, 'status')

    if status in ('dev', 'development', 'planned'):
        return f"{C.BLUE}◑ DEV   {C.RESET}"
    if status == 'hold':
        return f"{C.YELLOW}◐ HOLD  {C.RESET}"
    if status == 'tbd':
        return f"{C.DIM}○ TBD   {C.RESET}"

    url = get_svc(svc_id, 'urls.health') or get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')

    if not url or url == 'null':
        return f"{C.DIM}- N/A   {C.RESET}"

    if check_http(url):
        return f"{C.GREEN}● OK    {C.RESET}"
    else:
        return f"{C.RED}✖ ERROR {C.RESET}"

def refresh_all_status():
    """Refresh all status boxes by checking each VM/service."""
    # Update runtime status in JSON
    update_all_vm_runtime_status()

    # Update VMs
    for cat in get_vm_categories():
        for vm_id in get_vm_ids_by_category(cat):
            status = get_vm_status_display(vm_id)
            update_status_box(f"vm:{vm_id}", status)

    # Update Services
    for cat in get_service_categories():
        for svc_id in get_service_ids_by_category(cat):
            status = get_svc_status_display(svc_id)
            update_status_box(f"svc:{svc_id}", status)

def display_dashboard():
    """Display full dashboard with live status updates."""
    render_dashboard()
    refresh_all_status()
    show_cursor()

# Keep old functions for backward compatibility
def print_header():
    """Print dashboard header (legacy)."""
    print()
    print(f"  {C.BOLD}{C.CYAN}+{hline(76, '=')}+{C.RESET}")
    print(f"  {C.BOLD}{C.CYAN}|{C.RESET}           CLOUD INFRASTRUCTURE DASHBOARD v{VERSION}                   {C.BOLD}{C.CYAN}|{C.RESET}")
    print(f"  {C.BOLD}{C.CYAN}+{hline(76, '=')}+{C.RESET}")
    print()

def print_vm_table():
    """Print VM status table (legacy - calls new render)."""
    pass

def print_svc_table():
    """Print service status table (legacy - calls new render)."""
    pass

def print_menu():
    """Print command menu (legacy - included in render_dashboard)."""
    pass

# =============================================================================
# TUI SELECTION HELPERS
# =============================================================================

def select_vm(filter_type: str = 'all') -> Optional[str]:
    """Interactive VM selection. Returns VM ID or None."""
    print(f"\n{C.BOLD}Select VM:{C.RESET}")

    options = []
    for vm_id in get_vm_ids():
        ip = get_vm(vm_id, 'network.publicIp')
        name = get_vm(vm_id, 'name')

        if filter_type == 'online' and ip == 'pending':
            continue
        elif filter_type == 'pending' and ip != 'pending':
            continue

        options.append((vm_id, name, ip))

    for i, (vm_id, name, ip) in enumerate(options, 1):
        print(f"  [{i}] {name} ({ip})")

    print("  [0] Cancel")

    try:
        choice = input("Choice: ").strip()
        if not choice or choice == '0':
            return None
        idx = int(choice) - 1
        if 0 <= idx < len(options):
            return options[idx][0]
    except (ValueError, IndexError):
        pass

    return None

def select_service(filter_type: str = 'all') -> Optional[str]:
    """Interactive service selection. Returns service ID or None."""
    print(f"\n{C.BOLD}Select Service:{C.RESET}")

    options = []
    for svc_id in get_service_ids():
        name = get_svc(svc_id, 'name')
        container = get_svc(svc_id, 'docker.containerName')
        status = get_svc(svc_id, 'status')

        if filter_type == 'docker':
            if not container or container == 'null':
                continue
        elif filter_type == 'active':
            if status in ('dev', 'development', 'planned', 'hold', 'tbd'):
                continue

        options.append((svc_id, name, container))

    for i, (svc_id, name, container) in enumerate(options, 1):
        if container and container != 'null':
            print(f"  [{i}] {name} (container: {container})")
        else:
            print(f"  [{i}] {name}")

    print("  [0] Cancel")

    try:
        choice = input("Choice: ").strip()
        if not choice or choice == '0':
            return None
        idx = int(choice) - 1
        if 0 <= idx < len(options):
            return options[idx][0]
    except (ValueError, IndexError):
        pass

    return None

# =============================================================================
# TUI ACTIONS
# =============================================================================

def action_vm_details():
    """Show detailed VM information."""
    vm_id = select_vm('online')
    if not vm_id:
        return

    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
    name = get_vm(vm_id, 'name')

    cls()
    print(f"\n{C.BOLD}{C.CYAN}=== VM Details: {name} ==={C.RESET}\n")

    print(f"{C.BOLD}Local Config:{C.RESET}")
    print(f"  ID:       {vm_id}")
    print(f"  IP:       {ip}")
    print(f"  User:     {user}")
    print(f"  Provider: {get_vm(vm_id, 'provider')}")
    print(f"  Category: {get_vm(vm_id, 'category')}")
    print(f"  Type:     {get_vm(vm_id, 'instanceType')}\n")

    print(f"{C.BOLD}Remote System Info:{C.RESET}")

    details = get_vm_details(vm_id)
    if details:
        print(f"  Hostname: {details.get('hostname', '-')}")
        print(f"  Uptime:   {details.get('uptime', '-')}")
        print(f"  Kernel:   {details.get('kernel', '-')}")
        print(f"\nResources:")
        print(f"  CPU:      {details.get('cpu', '-')} cores")
        print(f"  RAM:      {details.get('ram_used', '-')}/{details.get('ram_total', '-')} ({details.get('ram_percent', '-')}%)")
        print(f"  Disk:     {details.get('disk_used', '-')}/{details.get('disk_total', '-')}")
        print(f"\nDocker:")
        print(f"  Running:  {details.get('containers', '-')} containers")
    else:
        print(f"  {C.RED}Failed to connect{C.RESET}")

    wait_key()

def action_container_status():
    """Show container status on a VM."""
    vm_id = select_vm('online')
    if not vm_id:
        return

    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
    name = get_vm(vm_id, 'name')

    cls()
    print(f"\n{C.BOLD}{C.CYAN}=== Containers on {name} ==={C.RESET}\n")

    try:
        result = subprocess.run(
            ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
             '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}',
             'sudo docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'],
            capture_output=True, text=True, timeout=SSH_TIMEOUT + 5
        )
        print(result.stdout)
    except Exception:
        print(f"{C.RED}Failed to connect{C.RESET}")

    wait_key()

def action_reboot_vm():
    """Reboot a VM."""
    vm_id = select_vm('online')
    if not vm_id:
        return

    name = get_vm(vm_id, 'name')
    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    print()
    if confirm(f"REBOOT {name} ({ip})?"):
        print(f"{C.YELLOW}Sending reboot command...{C.RESET}")
        try:
            subprocess.run(
                ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                 '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}', 'sudo reboot'],
                capture_output=True, timeout=SSH_TIMEOUT + 2
            )
        except Exception:
            pass
        print(f"{C.GREEN}Reboot signal sent.{C.RESET}")
        wait_key()

def action_restart_container():
    """Restart a Docker container."""
    svc_id = select_service('docker')
    if not svc_id:
        return

    name = get_svc(svc_id, 'name')
    container = get_svc(svc_id, 'docker.containerName')
    vm_id = get_svc(svc_id, 'vmId')
    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    print()
    if confirm(f"Restart container '{container}' ({name})?"):
        print(f"{C.YELLOW}Restarting...{C.RESET}")
        try:
            subprocess.run(
                ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                 '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}',
                 f'sudo docker restart {container}'],
                capture_output=True, timeout=60
            )
            print(f"{C.GREEN}Done.{C.RESET}")
        except Exception:
            print(f"{C.RED}Failed{C.RESET}")
        wait_key()

def action_view_logs():
    """View container logs."""
    svc_id = select_service('docker')
    if not svc_id:
        return

    container = get_svc(svc_id, 'docker.containerName')
    vm_id = get_svc(svc_id, 'vmId')
    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    lines = input("Lines to show [50]: ").strip() or '50'

    cls()
    print(f"\n{C.BOLD}{C.CYAN}=== Logs: {container} (last {lines} lines) ==={C.RESET}\n")

    try:
        result = subprocess.run(
            ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
             '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}',
             f'sudo docker logs --tail {lines} {container}'],
            capture_output=True, text=True, timeout=30
        )
        print(result.stdout)
        print(result.stderr)
    except Exception as e:
        print(f"{C.RED}Failed to get logs: {e}{C.RESET}")

    wait_key()

def action_stop_start():
    """Stop or start a container."""
    svc_id = select_service('docker')
    if not svc_id:
        return

    container = get_svc(svc_id, 'docker.containerName')
    vm_id = get_svc(svc_id, 'vmId')
    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    print("\n  [1] Start\n  [2] Stop")
    action = input("Action: ").strip()

    cmd = 'start' if action == '1' else 'stop' if action == '2' else None
    if not cmd:
        return

    if confirm(f"{cmd} container '{container}'?"):
        print(f"{C.YELLOW}Executing docker {cmd}...{C.RESET}")
        try:
            subprocess.run(
                ['ssh', '-i', key_path, '-o', f'ConnectTimeout={SSH_TIMEOUT}',
                 '-o', 'StrictHostKeyChecking=no', f'{user}@{ip}',
                 f'sudo docker {cmd} {container}'],
                capture_output=True, timeout=60
            )
            print(f"{C.GREEN}Done.{C.RESET}")
        except Exception:
            print(f"{C.RED}Failed{C.RESET}")
        wait_key()

def action_ssh():
    """Open interactive SSH session."""
    vm_id = select_vm('online')
    if not vm_id:
        return

    ip = get_vm(vm_id, 'network.publicIp')
    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
    name = get_vm(vm_id, 'name')

    print(f"\n{C.CYAN}Connecting to {name}...{C.RESET}")
    print(f"{C.DIM}Type 'exit' to return{C.RESET}\n")

    os.system(f'ssh -i {key_path} -o StrictHostKeyChecking=no {user}@{ip}')

def action_open_url():
    """Open service URL in browser."""
    svc_id = select_service('active')
    if not svc_id:
        return

    url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')

    if not url or url == 'null':
        print(f"{C.YELLOW}No URL available.{C.RESET}")
        wait_key()
        return

    print(f"{C.CYAN}Opening {url}...{C.RESET}")

    if shutil.which('xdg-open'):
        subprocess.Popen(['xdg-open', url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    elif shutil.which('open'):
        subprocess.Popen(['open', url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        print(f"{C.YELLOW}No browser opener. URL: {url}{C.RESET}")
        wait_key()
        return

    import time
    time.sleep(1)

def action_quick_status():
    """Show quick status summary."""
    print(f"\n{C.BOLD}{C.CYAN}=== Quick Status ==={C.RESET}\n")

    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        vms = get_vm_ids_by_category(cat)
        if not vms:
            continue

        print(f"{C.BOLD}{C.MAGENTA}{cat_name} VMs:{C.RESET}")
        for vm_id in vms:
            name = get_vm(vm_id, 'name')
            ip = get_vm(vm_id, 'network.publicIp')
            status = get_vm_status(vm_id)
            ram = get_vm_ram_percent(vm_id)

            if not ram:
                print(f"  {name:<25} {ip:<16} {status}")
            else:
                print(f"  {name:<25} {ip:<16} {status} RAM: {ram}%")
        print()

    for cat in get_service_categories():
        cat_name = get_service_category_name(cat)
        svcs = get_service_ids_by_category(cat)
        if not svcs:
            continue

        print(f"{C.BOLD}{C.MAGENTA}{cat_name} Services:{C.RESET}")
        for svc_id in svcs:
            display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
            status = get_svc_status(svc_id)
            print(f"  {display_name:<25} {status}")
        print()

    wait_key()

# =============================================================================
# CLI MODE
# =============================================================================

def cli_status():
    """Print status for CLI mode (no colors)."""
    print(f"Cloud Infrastructure Status v{VERSION}")
    print("=" * 40)
    print()

    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        vms = get_vm_ids_by_category(cat)
        if not vms:
            continue

        print(f"{cat_name} VMs:")
        for vm_id in vms:
            name = get_vm(vm_id, 'name')
            ip = get_vm(vm_id, 'network.publicIp')

            if ip == 'pending':
                print(f"  {name}: PENDING")
            else:
                user = get_vm(vm_id, 'ssh.user')
                key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
                if check_ssh(ip, user, key_path):
                    print(f"  {name} ({ip}): ONLINE")
                else:
                    print(f"  {name} ({ip}): OFFLINE")
        print()

    for cat in get_service_categories():
        cat_name = get_service_category_name(cat)
        svcs = get_service_ids_by_category(cat)
        if not svcs:
            continue

        print(f"{cat_name} Services:")
        for svc_id in svcs:
            display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
            url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')
            status = get_svc(svc_id, 'status')

            if status in ('dev', 'development', 'planned'):
                print(f"  {display_name}: DEV")
            elif status == 'hold':
                print(f"  {display_name}: HOLD")
            elif status == 'tbd':
                print(f"  {display_name}: TBD")
            elif not url or url == 'null':
                print(f"  {display_name}: NO URL")
            elif check_http(url):
                print(f"  {display_name}: HEALTHY")
            else:
                print(f"  {display_name}: ERROR")
        print()

def export_js(output_path: str = None) -> str:
    """Export config as JavaScript file for browser use (avoids CORS issues with JSON)."""
    if not output_path:
        output_path = SCRIPT_DIR / "cloud_dash_data.js"

    config = load_config()

    js_content = f"// Auto-generated by cloud_dash.py\n"
    js_content += f"// Generated: {datetime.now().isoformat()}\n"
    js_content += f"const CONFIG = {json.dumps(config, indent=2)};\n"

    with open(output_path, 'w') as f:
        f.write(js_content)

    return str(output_path)


def export_csv(output_path: str = None) -> str:
    """Export status to CSV file (using semicolon as delimiter)."""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    if not output_path:
        output_path = f"cloud_status_{timestamp}.csv"

    lines = []

    # VMs header
    lines.append("TYPE;CATEGORY;NAME;IP;STATUS;RAM%;INSTANCE_TYPE")

    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        for vm_id in get_vm_ids_by_category(cat):
            name = get_vm(vm_id, 'name') or ''
            ip = get_vm(vm_id, 'network.publicIp') or ''
            vm_type = get_vm(vm_id, 'instanceType') or ''

            # Get raw status without colors
            if ip == 'pending':
                status = 'PENDING'
            else:
                user = get_vm(vm_id, 'ssh.user')
                key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
                if check_ssh(ip, user, key_path):
                    status = 'ONLINE'
                elif check_ping(ip):
                    status = 'NO_SSH'
                else:
                    status = 'OFFLINE'

            ram = get_vm_ram_percent(vm_id)
            ram_str = f"{ram}%" if ram else '-'

            lines.append(f"VM;{cat_name};{name};{ip};{status};{ram_str};{vm_type}")

    # Services header
    lines.append("")
    lines.append("TYPE;CATEGORY;NAME;URL;STATUS")

    for cat in get_service_categories():
        cat_name = get_service_category_name(cat)
        for svc_id in get_service_ids_by_category(cat):
            display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
            url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin') or '-'
            svc_status = get_svc(svc_id, 'status')

            if svc_status in ('dev', 'development', 'planned'):
                status = 'DEV'
            elif svc_status == 'hold':
                status = 'HOLD'
            elif svc_status == 'tbd':
                status = 'TBD'
            elif not url or url == 'null':
                status = 'NO_URL'
            elif check_http(url):
                status = 'HEALTHY'
            else:
                status = 'ERROR'

            if url and url != 'null':
                url = url.replace('https://', '').replace('http://', '')
            else:
                url = '-'

            lines.append(f"SERVICE;{cat_name};{display_name};{url};{status}")

    with open(output_path, 'w') as f:
        f.write('\n'.join(lines))

    return output_path


def export_markdown(output_path: str = None) -> str:
    """Export status to Markdown file."""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    if not output_path:
        output_path = f"cloud_status_{timestamp}.md"

    lines = []
    lines.append(f"# Cloud Infrastructure Status Report")
    lines.append(f"")
    lines.append(f"**Generated**: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(f"**Version**: {VERSION}")
    lines.append(f"")

    # VMs
    lines.append(f"## Virtual Machines")
    lines.append(f"")

    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        vms = get_vm_ids_by_category(cat)

        if not vms:
            continue

        lines.append(f"### {cat_name}")
        lines.append(f"")
        lines.append(f"| Name | IP | Status | RAM% | Type |")
        lines.append(f"|------|-----|--------|------|------|")

        for vm_id in vms:
            name = get_vm(vm_id, 'name') or ''
            ip = get_vm(vm_id, 'network.publicIp') or ''
            vm_type = get_vm(vm_id, 'instanceType') or ''

            if ip == 'pending':
                status = '🟡 PENDING'
            else:
                user = get_vm(vm_id, 'ssh.user')
                key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
                if check_ssh(ip, user, key_path):
                    status = '🟢 ONLINE'
                elif check_ping(ip):
                    status = '🟡 NO SSH'
                else:
                    status = '🔴 OFFLINE'

            ram = get_vm_ram_percent(vm_id)
            ram_str = f"{ram}%" if ram else '-'

            lines.append(f"| {name} | {ip} | {status} | {ram_str} | {vm_type} |")

        lines.append(f"")

    # Services
    lines.append(f"## Services")
    lines.append(f"")

    for cat in get_service_categories():
        cat_name = get_service_category_name(cat)
        svcs = get_service_ids_by_category(cat)

        if not svcs:
            continue

        lines.append(f"### {cat_name}")
        lines.append(f"")
        lines.append(f"| Name | URL | Status |")
        lines.append(f"|------|-----|--------|")

        for svc_id in svcs:
            display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
            url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin') or ''
            svc_status = get_svc(svc_id, 'status')

            if svc_status in ('dev', 'development', 'planned'):
                status = '🔵 DEV'
            elif svc_status == 'hold':
                status = '🟡 HOLD'
            elif svc_status == 'tbd':
                status = '⚪ TBD'
            elif not url or url == 'null':
                status = '⚪ N/A'
            elif check_http(url):
                status = '🟢 HEALTHY'
            else:
                status = '🔴 ERROR'

            if url and url != 'null':
                short_url = url.replace('https://', '').replace('http://', '')
            else:
                short_url = '-'

            lines.append(f"| {display_name} | {short_url} | {status} |")

        lines.append(f"")

    lines.append(f"---")
    lines.append(f"*Report generated by Cloud Dashboard v{VERSION}*")

    with open(output_path, 'w') as f:
        f.write('\n'.join(lines))

    return output_path


def export_html(output_path: str = None) -> str:
    """Export status to HTML file with CSS styling."""
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    if not output_path:
        output_path = f"cloud_status_{timestamp}.html"

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cloud Infrastructure Status - {datetime.now().strftime('%Y-%m-%d %H:%M')}</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #e0e0e0;
            min-height: 100vh;
            padding: 2rem;
        }}
        .container {{ max-width: 1400px; margin: 0 auto; }}
        h1 {{
            text-align: center;
            color: #00d4ff;
            margin-bottom: 0.5rem;
            font-size: 2rem;
        }}
        .subtitle {{
            text-align: center;
            color: #888;
            margin-bottom: 2rem;
        }}
        .section {{
            background: rgba(255,255,255,0.05);
            border-radius: 12px;
            padding: 1.5rem;
            margin-bottom: 2rem;
            border: 1px solid rgba(255,255,255,0.1);
        }}
        h2 {{
            color: #00d4ff;
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid rgba(0,212,255,0.3);
        }}
        h3 {{
            color: #bb86fc;
            margin: 1rem 0 0.5rem 0;
            font-size: 1rem;
        }}
        table {{
            width: 100%;
            border-collapse: collapse;
            margin-top: 0.5rem;
        }}
        th, td {{
            padding: 0.75rem 1rem;
            text-align: left;
            border-bottom: 1px solid rgba(255,255,255,0.1);
        }}
        th {{
            background: rgba(0,212,255,0.1);
            color: #00d4ff;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.8rem;
            letter-spacing: 0.5px;
        }}
        tr:hover {{ background: rgba(255,255,255,0.05); }}
        .status {{
            display: inline-block;
            padding: 0.25rem 0.75rem;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 600;
        }}
        .status-online, .status-healthy {{ background: rgba(34,197,94,0.2); color: #22c55e; }}
        .status-offline, .status-error {{ background: rgba(239,68,68,0.2); color: #ef4444; }}
        .status-pending, .status-hold, .status-nossh {{ background: rgba(234,179,8,0.2); color: #eab308; }}
        .status-dev {{ background: rgba(59,130,246,0.2); color: #3b82f6; }}
        .status-na, .status-tbd {{ background: rgba(156,163,175,0.2); color: #9ca3af; }}
        .footer {{
            text-align: center;
            color: #666;
            margin-top: 2rem;
            padding-top: 1rem;
            border-top: 1px solid rgba(255,255,255,0.1);
        }}
        a {{ color: #00d4ff; text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Cloud Infrastructure Status</h1>
        <p class="subtitle">Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Version: {VERSION}</p>
"""

    # VMs Section
    html += '        <div class="section">\n'
    html += '            <h2>Virtual Machines</h2>\n'

    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        vms = get_vm_ids_by_category(cat)
        if not vms:
            continue

        html += f'            <h3>{cat_name}</h3>\n'
        html += '            <table>\n'
        html += '                <tr><th>Name</th><th>IP</th><th>RAM</th><th>Storage</th><th>Type</th><th>Status</th></tr>\n'

        for vm_id in vms:
            name = get_vm(vm_id, 'name') or ''
            ip = get_vm(vm_id, 'network.publicIp') or ''
            vm_type = get_vm(vm_id, 'instanceType') or ''
            specs = get_vm(vm_id, 'specs') or {{}}
            ram = specs.get('ram', '-')
            storage = specs.get('storage', '-')

            if ip == 'pending':
                status = 'PENDING'
                status_class = 'status-pending'
            else:
                user = get_vm(vm_id, 'ssh.user')
                key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
                if check_ssh(ip, user, key_path):
                    status = 'ONLINE'
                    status_class = 'status-online'
                elif check_ping(ip):
                    status = 'NO SSH'
                    status_class = 'status-nossh'
                else:
                    status = 'OFFLINE'
                    status_class = 'status-offline'

            html += f'                <tr><td>{name}</td><td>{ip}</td><td>{ram}</td><td>{storage}</td><td>{vm_type}</td><td><span class="status {status_class}">{status}</span></td></tr>\n'

        html += '            </table>\n'

    html += '        </div>\n'

    # Services Section
    html += '        <div class="section">\n'
    html += '            <h2>Services</h2>\n'

    for cat in get_service_categories():
        cat_name = get_service_category_name(cat)
        svcs = get_service_ids_by_category(cat)
        if not svcs:
            continue

        html += f'            <h3>{cat_name}</h3>\n'
        html += '            <table>\n'
        html += '                <tr><th>Name</th><th>URL</th><th>Status</th></tr>\n'

        for svc_id in svcs:
            display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
            url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin') or ''
            svc_status = get_svc(svc_id, 'status')

            if svc_status in ('dev', 'development', 'planned'):
                status = 'DEV'
                status_class = 'status-dev'
            elif svc_status == 'hold':
                status = 'HOLD'
                status_class = 'status-hold'
            elif svc_status == 'tbd':
                status = 'TBD'
                status_class = 'status-tbd'
            elif not url or url == 'null':
                status = 'N/A'
                status_class = 'status-na'
            elif check_http(url):
                status = 'HEALTHY'
                status_class = 'status-healthy'
            else:
                status = 'ERROR'
                status_class = 'status-error'

            if url and url != 'null':
                short_url = url.replace('https://', '').replace('http://', '')
                url_display = f'<a href="{url}" target="_blank">{short_url}</a>'
            else:
                url_display = '-'

            html += f'                <tr><td>{display_name}</td><td>{url_display}</td><td><span class="status {status_class}">{status}</span></td></tr>\n'

        html += '            </table>\n'

    html += '        </div>\n'

    # Footer
    html += f"""
        <div class="footer">
            <p>Report generated by Cloud Dashboard v{VERSION}</p>
        </div>
    </div>
</body>
</html>
"""

    with open(output_path, 'w') as f:
        f.write(html)

    return output_path


def export_html_live(refresh_seconds: int = 30) -> str:
    """Export status to HTML file with exact terminal-style ASCII layout and auto-refresh.

    Args:
        refresh_seconds: Auto-refresh interval in seconds

    Returns:
        Path to the generated HTML file (always cloud_dash.html)
    """
    output_path = SCRIPT_DIR / "cloud_dash.html"
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    # Build VM index map for services
    vm_index_map = {}
    vm_index = 0
    for cat in get_vm_categories():
        for vm_id in get_vm_ids_by_category(cat):
            vm_index_map[vm_id] = vm_index
            vm_index += 1

    # Helper to create colored spans
    def c(text, color):
        return f'<span class="{color}">{text}</span>'

    # Build terminal output as text lines
    lines = []

    # Title box
    lines.append(c('  +======================================================================================================================+', 'cyan bold'))
    lines.append(c('  |', 'cyan bold') + c('                                        CLOUD INFRASTRUCTURE DASHBOARD v' + VERSION + '                                         ', 'cyan bold') + c('|', 'cyan bold'))
    lines.append(c('  +======================================================================================================================+', 'cyan bold'))
    lines.append('')

    # VMs Section - fixed widths (inner width = 110)
    VM_W = 110
    lines.append(c(f'  +{"-" * VM_W}+', 'white bold'))
    lines.append(c(f'  | {"VIRTUAL MACHINES":<{VM_W-2}} |', 'white bold'))
    lines.append(f'  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+')
    lines.append(f'  | ☐ | # | SVC | MODE | NAME                 | IP              | RAM    | VRAM   | STORAGE | MEM%  | DISK% | STATUS   |')
    lines.append(f'  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+')

    vm_index = 0
    for cat in get_vm_categories():
        cat_name = get_vm_category_name(cat)
        vms = get_vm_ids_by_category(cat)
        if not vms:
            continue

        # Category header
        cat_line = f'  ' + c(f'| {cat_name:<{VM_W-2}} |', 'magenta bold')
        lines.append(cat_line)

        for vm_id in vms:
            name = (get_vm(vm_id, 'name') or '')[:20].ljust(20)
            ip = (get_vm(vm_id, 'network.publicIp') or '').ljust(15)
            specs = get_vm(vm_id, 'specs') or {}
            ram = specs.get('ram', '-')[:6].ljust(6)
            storage = specs.get('storage', '-')[:7].ljust(7)
            vram = '-'.ljust(6)
            mem_pct = '-'.ljust(5)
            disk_pct = '-'.ljust(5)

            vm_status = get_vm(vm_id, 'status')
            if vm_status == 'pending':
                mode_str = c('PEND', 'yellow')
            elif vm_status in ('dev', 'development'):
                mode_str = c('DEV ', 'blue')
            elif vm_status == 'hold':
                mode_str = c('HOLD', 'yellow')
            else:
                mode_str = c('ON  ', 'green')

            if ip.strip() == 'pending':
                status_str = c('◐ PEND ', 'yellow')
            else:
                user = get_vm(vm_id, 'ssh.user')
                key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')
                if check_ssh(ip.strip(), user, key_path):
                    status_str = c('● ONLINE', 'green')
                    ram_pct = get_vm_ram_percent(vm_id)
                    if ram_pct is not None:
                        mem_pct = f"{ram_pct}%".ljust(5)
                elif check_ping(ip.strip()):
                    status_str = c('◐ NOSSH ', 'yellow')
                else:
                    status_str = c('○ OFF   ', 'red')

            row = f'  | ☐ | {vm_index} | -   | {mode_str} | {name} | {ip} | {ram} | {vram} | {storage} | {mem_pct} | {disk_pct} | {status_str} |'
            lines.append(row)
            vm_index += 1

    lines.append(f'  +---+---+-----+------+----------------------+-----------------+--------+--------+---------+-------+-------+----------+')
    lines.append('')

    # Services Section - using hierarchical structure (inner width = 116)
    # Supports both view modes: 'category' (by service type) or 'vm' (by VM parent)
    SVC_W = 116
    view_label = "BY SERVICE TYPE" if _view_mode == 'category' else "BY VM"
    header_text = f"SERVICES ({view_label})"
    lines.append(c(f'  +{"-" * SVC_W}+', 'white bold'))
    lines.append(c(f'  | {header_text:<{SVC_W-2}} |', 'white bold'))
    lines.append(f'  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+')
    lines.append(f'  | ☐ | #  | VM | MODE | NAME                 | URL                        | PROXY ADDRESS        | %MEM  | %DISK | STATUS   |')
    lines.append(f'  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+')

    svc_index = 0

    # Helper function to render a service row
    def render_service_row(svc_id, is_child, vm_ref_str, svc_idx):
        display_name = get_svc(svc_id, 'displayName') or get_svc(svc_id, 'name') or svc_id
        if is_child:
            display_name = f"  └─ {display_name}"
        display_name = display_name[:20].ljust(20)

        url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin') or ''
        proxy_addr = (get_svc(svc_id, 'network.proxyAddress') or '-')[:20].ljust(20)
        mem_pct = '-'.ljust(5)
        disk_pct = '-'.ljust(5)

        svc_status = get_svc(svc_id, 'status')
        if svc_status in ('dev', 'development', 'planned'):
            mode_str = c('DEV ', 'blue')
            status_str = c('◑ DEV  ', 'blue')
        elif svc_status == 'hold':
            mode_str = c('HOLD', 'yellow')
            status_str = c('◐ HOLD ', 'yellow')
        elif svc_status == 'tbd':
            mode_str = c('TBD ', 'yellow')
            status_str = c('○ TBD  ', 'gray')
        elif not url or url == 'null':
            mode_str = c('ON  ', 'green')
            status_str = c('- N/A  ', 'gray')
        elif check_http(url):
            mode_str = c('ON  ', 'green')
            status_str = c('● OK   ', 'green')
        else:
            mode_str = c('ON  ', 'green')
            status_str = c('✗ ERROR', 'red')

        if url and url != 'null':
            short_url = url.replace('https://', '').replace('http://', '')[:26].ljust(26)
            url_display = f'<a href="{url}" class="cyan">{short_url}</a>'
        else:
            url_display = '-'.ljust(26)

        # Service index (a-z, then aa-az, ba-bz, etc.)
        if svc_idx < 26:
            svc_letter = chr(ord('a') + svc_idx)
        else:
            first = chr(ord('a') + (svc_idx - 26) // 26)
            second = chr(ord('a') + (svc_idx - 26) % 26)
            svc_letter = f"{first}{second}"

        return f'  | ☐ | {svc_letter:<2} | {vm_ref_str.ljust(2)} | {mode_str} | {display_name} | {url_display} | {proxy_addr} | {mem_pct} | {disk_pct} | {status_str} |'

    if _view_mode == 'vm':
        # VM-centric view: services grouped by VM
        for vm_data in get_services_by_vm():
            vm_name = vm_data['vm_name']
            vm_idx = vm_data['vm_index']
            services = vm_data['services']

            if not services:
                continue

            # VM header row
            vm_header = f"VM {vm_idx}: {vm_name}"
            lines.append(f'  ' + c(f'| {vm_header:<{SVC_W-2}} |', 'cyan bold'))

            for svc_id, is_child in services:
                row = render_service_row(svc_id, is_child, str(vm_idx), svc_index)
                lines.append(row)
                svc_index += 1
    else:
        # Category view: services grouped by service type (default)
        for cat_data in get_services_hierarchical():
            cat_name = cat_data['category_name']
            services = cat_data['services']  # list of (svc_id, is_child) tuples

            if not services:
                continue

            # Category header
            cat_line = f'  ' + c(f'| {cat_name:<{SVC_W-2}} |', 'magenta bold')
            lines.append(cat_line)

            for svc_id, is_child in services:
                vm_id = get_svc(svc_id, 'vmId')
                vm_ref = str(vm_index_map.get(vm_id, '-')) if vm_id and vm_id in vm_index_map else '-'
                row = render_service_row(svc_id, is_child, vm_ref, svc_index)
                lines.append(row)
                svc_index += 1

    lines.append(f'  +---+----+----+------+----------------------+----------------------------+----------------------+-------+-------+----------+')
    lines.append('')

    # Commands box
    lines.append(c('  +----------------------------------------------------------------------------------------------------------------------+', 'white bold'))
    lines.append(c('  | COMMANDS                                                                                                             |', 'white bold'))
    lines.append('  +----------------------------------------------------------------------------------------------------------------------+')
    lines.append(f'  |  {c("[1]", "cyan")} VM Details    {c("[2]", "cyan")} Containers   {c("[3]", "cyan")} Reboot VM    {c("[4]", "cyan")} Restart Container    {c("[5]", "cyan")} Logs              {c("[6]", "cyan")} Stop/Start          |')
    lines.append(f'  |  {c("[7]", "cyan")} SSH to VM     {c("[8]", "cyan")} Open URL     {c("[V]", "cyan")} Toggle View  {c("[R]", "cyan")} Refresh      {c("[Q]", "cyan")} Quit                                       |')
    lines.append('  +----------------------------------------------------------------------------------------------------------------------+')

    terminal_content = '\n'.join(lines)

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="refresh" content="{refresh_seconds}">
    <title>Cloud Dashboard - Live</title>
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: 'Cascadia Code', 'Fira Code', 'JetBrains Mono', 'Consolas', 'Monaco', monospace;
            background: #0c0c0c;
            color: #cccccc;
            min-height: 100vh;
            padding: 0;
        }}
        .refresh-bar {{
            background: #1a1a1a;
            border-bottom: 1px solid #333;
            padding: 8px 16px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 12px;
            color: #888;
        }}
        .refresh-bar .interval {{ color: #00d4ff; font-weight: bold; }}
        pre {{
            margin: 0;
            padding: 8px;
            font-family: inherit;
            font-size: 13px;
            line-height: 1.3;
            overflow-x: auto;
        }}
        /* ANSI Colors */
        .green {{ color: #00ff00; }}
        .red {{ color: #ff5555; }}
        .yellow {{ color: #ffff55; }}
        .blue {{ color: #5555ff; }}
        .cyan {{ color: #00d4ff; }}
        .magenta {{ color: #ff55ff; }}
        .gray {{ color: #808080; }}
        .white {{ color: #ffffff; }}
        .bold {{ font-weight: bold; }}
        /* Links */
        a {{ color: #00d4ff; text-decoration: none; }}
        a:hover {{ text-decoration: underline; }}
    </style>
</head>
<body>
    <div class="refresh-bar">
        <span>Auto refresh every: <span class="interval">{refresh_seconds} seconds</span></span>
        <span>Last update: {timestamp}</span>
    </div>
    <pre>{terminal_content}</pre>
</body>
</html>
"""

    with open(output_path, 'w') as f:
        f.write(html)

    return str(output_path)


def parse_interval(interval_str: str) -> int:
    """Parse interval string like '10s', '30s', '1m' to seconds."""
    interval_str = interval_str.strip().lower()
    if interval_str.endswith('s'):
        return int(interval_str[:-1])
    elif interval_str.endswith('m'):
        return int(interval_str[:-1]) * 60
    else:
        return int(interval_str)


def cli_help():
    """Print help message."""
    print(f"""
{C.BOLD}{C.CYAN}CLOUD INFRASTRUCTURE DASHBOARD{C.RESET} v{VERSION}
{C.DIM}Monitor and manage cloud VMs and services{C.RESET}

{C.BOLD}SYNOPSIS{C.RESET}
    cloud_dash.py [{C.CYAN}-v{C.RESET} {C.YELLOW}<mode>{C.RESET}] [{C.CYAN}-e{C.RESET} {C.YELLOW}<format>{C.RESET}] [{C.CYAN}-l{C.RESET} {C.YELLOW}<interval>{C.RESET}] [{C.CYAN}-s{C.RESET}]

{C.BOLD}OPTIONS{C.RESET}
    {C.CYAN}-v{C.RESET}, {C.CYAN}--view{C.RESET} {C.YELLOW}<mode>{C.RESET}
            View mode: {C.DIM}vm{C.RESET} | {C.DIM}category{C.RESET} (default: {C.GREEN}vm{C.RESET})

    {C.CYAN}-e{C.RESET}, {C.CYAN}--export{C.RESET} {C.YELLOW}<format>{C.RESET}
            Output format: {C.DIM}tui{C.RESET} | {C.DIM}html{C.RESET} | {C.DIM}json{C.RESET} | {C.DIM}csv{C.RESET} | {C.DIM}md{C.RESET} | {C.DIM}terminal{C.RESET} (default: {C.GREEN}tui{C.RESET})

    {C.CYAN}-l{C.RESET}, {C.CYAN}--live{C.RESET} {C.YELLOW}<interval>{C.RESET}
            Auto-refresh HTML: {C.DIM}5s{C.RESET}, {C.DIM}10s{C.RESET}, {C.DIM}30s{C.RESET}, {C.DIM}1m{C.RESET}, ... (default: {C.GREEN}off{C.RESET})

    {C.CYAN}-s{C.RESET}, {C.CYAN}--serve{C.RESET}
            Start Flask API server on port 5000

    {C.CYAN}-h{C.RESET}, {C.CYAN}--help{C.RESET}
            Show this help message

{C.BOLD}ARGUMENTS{C.RESET}
    {C.YELLOW}<mode>{C.RESET}
        vm          Services grouped by parent VM
        category    Services grouped by type (User, Coder, AI, Infra)

    {C.YELLOW}<format>{C.RESET}
        tui         Interactive terminal UI
        html        Static HTML file
        json        JSON data
        csv         CSV spreadsheet
        md          Markdown table
        terminal    Plain text to stdout

    {C.YELLOW}<interval>{C.RESET}
        5s, 10s, 30s, 1m, 5m, ...

{C.BOLD}EXAMPLES{C.RESET}
    $ cloud_dash.py                        {C.DIM}# Interactive TUI{C.RESET}
    $ cloud_dash.py --view vm              {C.DIM}# TUI with VM grouping{C.RESET}
    $ cloud_dash.py --export html          {C.DIM}# Export HTML file{C.RESET}
    $ cloud_dash.py --live 30s             {C.DIM}# Live HTML (30s refresh){C.RESET}
    $ cloud_dash.py --live 1m --view vm    {C.DIM}# Live HTML + VM view{C.RESET}
    $ cloud_dash.py --serve                {C.DIM}# Start API server{C.RESET}

{C.BOLD}API ENDPOINTS{C.RESET} {C.DIM}(--serve mode){C.RESET}
    GET /api/health                 Health check
    GET /api/vms                    List all VMs
    GET /api/vms/{C.YELLOW}<id>{C.RESET}/status       VM status
    GET /api/services               List all services
    GET /api/services/{C.YELLOW}<id>{C.RESET}/status  Service status
    GET /api/dashboard/summary      Full dashboard data

{C.BOLD}FILES{C.RESET}
    {C.DIM}{CONFIG_FILE}{C.RESET}
""")

# =============================================================================
# MAIN
# =============================================================================

def toggle_view_mode():
    """Toggle between service view modes (by category / by VM)."""
    global _view_mode
    _view_mode = 'vm' if _view_mode == 'category' else 'category'


def main_loop():
    """Main interactive TUI loop."""
    while True:
        display_dashboard()
        cmd = input("  Command: ").strip().lower()

        actions = {
            '1': action_vm_details,
            '2': action_container_status,
            '3': action_reboot_vm,
            '4': action_restart_container,
            '5': action_view_logs,
            '6': action_stop_start,
            '7': action_ssh,
            '8': action_open_url,
            's': action_quick_status,
            'r': lambda: None,
            'v': toggle_view_mode,
        }

        if cmd == 'q':
            cls()
            print(f"{C.CYAN}Goodbye!{C.RESET}")
            break
        elif cmd in actions:
            actions[cmd]()
        else:
            print(f"{C.RED}Invalid command{C.RESET}")
            import time
            time.sleep(1)

def main():
    """Entry point."""
    global _view_mode

    # Check basic dependencies
    for cmd in ['ssh', 'curl', 'ping']:
        if not shutil.which(cmd):
            print(f"{C.RED}Error: Missing dependency: {cmd}{C.RESET}")
            sys.exit(1)

    # Validate config
    try:
        load_config()
    except FileNotFoundError as e:
        print(f"{C.RED}Error: {e}{C.RESET}")
        sys.exit(1)

    # Parse arguments
    args = sys.argv[1:]

    # Defaults
    view_mode = 'vm'
    export_format = 'tui'
    live_interval = None
    serve_mode = False
    show_help = False

    # Parse all arguments
    i = 0
    while i < len(args):
        arg = args[i]

        # View mode
        if arg in ('-v', '--view'):
            if i + 1 < len(args):
                view_arg = args[i + 1].lower()
                if view_arg in ('vm', 'by-vm', 'byvm'):
                    view_mode = 'vm'
                elif view_arg in ('category', 'cat', 'type', 'service'):
                    view_mode = 'category'
                else:
                    print(f"{C.YELLOW}Unknown view mode: {view_arg}. Using default 'category'{C.RESET}")
                i += 2
            else:
                print(f"{C.RED}Error: -v/--view requires a value (vm|category){C.RESET}")
                sys.exit(1)

        # Export format
        elif arg in ('-e', '--export'):
            if i + 1 < len(args):
                export_format = args[i + 1].lower()
                i += 2
            else:
                print(f"{C.RED}Error: -e/--export requires a value (tui|html|json|csv|md|terminal){C.RESET}")
                sys.exit(1)

        # Live mode
        elif arg in ('-l', '--live'):
            if i + 1 < len(args) and not args[i + 1].startswith('-'):
                try:
                    live_interval = parse_interval(args[i + 1])
                    i += 2
                except ValueError:
                    live_interval = 30  # default
                    i += 1
            else:
                live_interval = 30  # default 30s
                i += 1

        # Serve mode
        elif arg in ('-s', '--serve'):
            serve_mode = True
            i += 1

        # Help
        elif arg in ('-h', '--help', 'help'):
            show_help = True
            i += 1

        # Legacy commands (backwards compatibility)
        elif arg == 'serve':
            serve_mode = True
            i += 1
        elif arg == 'status':
            cli_status()
            return
        elif arg == 'export':
            # Legacy: cloud_dash.py export csv
            if i + 1 < len(args):
                export_format = args[i + 1].lower()
                i += 2
            else:
                print(f"{C.RED}Usage: {sys.argv[0]} export [csv|md|html]{C.RESET}")
                sys.exit(1)
        elif arg == '--debug':
            i += 1  # skip, handled by serve
        else:
            print(f"Unknown option: {arg}")
            cli_help()
            sys.exit(1)

    # Set global view mode
    _view_mode = view_mode

    # Handle help
    if show_help:
        cli_help()
        return

    # Handle serve mode
    if serve_mode:
        debug = '--debug' in sys.argv
        run_server(debug=debug)
        return

    # Handle live mode
    if live_interval is not None:
        # Minimum 5 seconds
        if live_interval < 5:
            live_interval = 5
            print(f"{C.YELLOW}Interval too short, using minimum 5s{C.RESET}")

        view_label = "BY VM" if _view_mode == 'vm' else "BY SERVICE TYPE"
        print(f"{C.CYAN}Starting live HTML export with {live_interval}s refresh...{C.RESET}")
        print(f"{C.CYAN}View mode: {view_label}{C.RESET}")
        print(f"{C.CYAN}Output: {SCRIPT_DIR / 'cloud_dash.html'}{C.RESET}")
        print(f"{C.YELLOW}Press Ctrl+C to stop{C.RESET}")
        print()

        try:
            import time as time_module
            while True:
                result = export_html_live(live_interval)
                print(f"\r{C.GREEN}Updated: {datetime.now().strftime('%H:%M:%S')}{C.RESET}", end='', flush=True)
                time_module.sleep(live_interval)
        except KeyboardInterrupt:
            print(f"\n{C.CYAN}Live export stopped.{C.RESET}")
        return

    # Handle export formats
    if export_format != 'tui':
        if export_format == 'csv':
            result = export_csv()
            print(f"{C.GREEN}Exported to: {result}{C.RESET}")
        elif export_format in ('md', 'markdown'):
            result = export_markdown()
            print(f"{C.GREEN}Exported to: {result}{C.RESET}")
        elif export_format == 'html':
            result = export_html()
            print(f"{C.GREEN}Exported to: {result}{C.RESET}")
        elif export_format == 'json':
            import json as json_mod
            config = load_config()
            print(json_mod.dumps(config, indent=2))
        elif export_format == 'js':
            result = export_js()
            print(f"{C.GREEN}Exported to: {result}{C.RESET}")
        elif export_format == 'terminal':
            render_dashboard()
        else:
            print(f"{C.RED}Unknown format: {export_format}. Use 'tui', 'html', 'json', 'js', 'csv', 'md', or 'terminal'{C.RESET}")
            sys.exit(1)
        return

    # Default: TUI mode
    main_loop()

if __name__ == '__main__':
    main()
