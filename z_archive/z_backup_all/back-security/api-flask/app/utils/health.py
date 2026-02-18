"""
Health check functions for VMs and services
"""
import subprocess
from typing import Dict, Optional

from app.config import (
    SSH_TIMEOUT, PING_TIMEOUT, CURL_TIMEOUT,
    get_vm, get_svc, expand_path
)


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


def get_vm_status(vm_id: str) -> Dict:
    """Get VM status information."""
    ip = get_vm(vm_id, 'network.publicIp')

    if ip == 'pending':
        return {
            'status': 'pending',
            'label': 'PENDING',
            'ping': False,
            'ssh': False
        }

    user = get_vm(vm_id, 'ssh.user')
    key_path = expand_path(get_vm(vm_id, 'ssh.keyPath') or '')

    ssh_ok = check_ssh(ip, user, key_path)
    ping_ok = check_ping(ip) if not ssh_ok else True

    if ssh_ok:
        return {
            'status': 'online',
            'label': 'ONLINE',
            'ping': True,
            'ssh': True
        }
    elif ping_ok:
        return {
            'status': 'no_ssh',
            'label': 'NO SSH',
            'ping': True,
            'ssh': False
        }
    else:
        return {
            'status': 'offline',
            'label': 'OFFLINE',
            'ping': False,
            'ssh': False
        }


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


def get_svc_status(svc_id: str) -> Dict:
    """Get service status information."""
    status = get_svc(svc_id, 'status')

    if status in ('planned', 'development'):
        return {
            'status': 'development',
            'label': 'DEV',
            'healthy': None
        }

    url = get_svc(svc_id, 'urls.gui') or get_svc(svc_id, 'urls.admin')

    if not url or url == 'null':
        return {
            'status': 'no_url',
            'label': 'N/A',
            'healthy': None
        }

    healthy = check_http(url)
    return {
        'status': 'healthy' if healthy else 'error',
        'label': 'HEALTHY' if healthy else 'ERROR',
        'healthy': healthy
    }


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


def run_ssh_command(vm_id: str, command: str) -> Optional[str]:
    """Run an SSH command on a VM and return output."""
    ip = get_vm(vm_id, 'network.publicIp')

    if not ip or ip == 'pending':
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
                f'{user}@{ip}', command
            ],
            capture_output=True,
            text=True,
            timeout=SSH_TIMEOUT + 10
        )
        return result.stdout + result.stderr
    except (subprocess.TimeoutExpired, Exception):
        return None
