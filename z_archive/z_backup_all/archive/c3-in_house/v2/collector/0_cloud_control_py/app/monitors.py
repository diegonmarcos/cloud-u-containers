"""
Status monitoring for Cloud Control Center
"""

import subprocess
from typing import Optional, Dict

from .models import Host, RuntimeStatus
from .config_loader import get_ssh_key


def check_ping(host: str, timeout: int = 2) -> bool:
    """Check if host responds to ping."""
    try:
        result = subprocess.run(
            ["ping", "-c", "1", "-W", str(timeout), host],
            capture_output=True, timeout=timeout + 1
        )
        return result.returncode == 0
    except:
        return False


def check_ssh(ip: str, user: str = "ubuntu", key_path: str = None, timeout: int = 5) -> bool:
    """Check if SSH connection works."""
    if not key_path:
        key_path = get_ssh_key()
    try:
        cmd = f"ssh -o ConnectTimeout={timeout} -o StrictHostKeyChecking=no -i {key_path} {user}@{ip} echo ok"
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout + 2)
        return result.returncode == 0 and "ok" in result.stdout.decode()
    except:
        return False


def check_http(url: str, timeout: int = 5) -> bool:
    """Check if HTTP endpoint responds."""
    try:
        cmd = f"curl -s -o /dev/null -w '%{{http_code}}' --max-time {timeout} {url}"
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout + 2)
        code = result.stdout.decode().strip()
        return code.startswith("2") or code.startswith("3")
    except:
        return False


def check_port(host: str, port: int, timeout: int = 3) -> bool:
    """Check if TCP port is open."""
    try:
        cmd = f"nc -z -w{timeout} {host} {port}"
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout + 1)
        return result.returncode == 0
    except:
        return False


def get_host_status(host: Host) -> RuntimeStatus:
    """Get complete runtime status of a host."""
    status = RuntimeStatus()

    if not host.ip or host.ip == "pending":
        return status

    # Check connectivity
    status.ping = check_ping(host.ip)

    if status.ping:
        user = "ubuntu" if host.provider == "oci" else "diego"
        status.ssh = check_ssh(host.ip, user)
        status.online = status.ssh

    from datetime import datetime
    status.last_check = datetime.now().isoformat()

    return status


def get_ram_percent(host: Host) -> Optional[int]:
    """Get RAM usage percentage from host."""
    from .commands import vm_ssh
    try:
        output = vm_ssh(host, "free | grep Mem | awk '{print int($3/$2 * 100)}'")
        return int(output.strip())
    except:
        return None


def get_cpu_percent(host: Host) -> Optional[float]:
    """Get CPU usage percentage from host."""
    from .commands import vm_ssh
    try:
        output = vm_ssh(host, "top -bn1 | grep 'Cpu(s)' | awk '{print $2}'")
        return float(output.strip())
    except:
        return None


def get_docker_containers(host: Host) -> list:
    """Get list of docker containers on host."""
    from .commands import vm_ssh
    try:
        output = vm_ssh(host, "docker ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}'")
        containers = []
        for line in output.strip().split('\n'):
            if line and '|' in line:
                parts = line.split('|')
                containers.append({
                    "name": parts[0],
                    "status": parts[1] if len(parts) > 1 else "",
                    "image": parts[2] if len(parts) > 2 else ""
                })
        return containers
    except:
        return []
