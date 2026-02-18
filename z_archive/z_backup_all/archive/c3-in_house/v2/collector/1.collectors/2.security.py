#!/usr/bin/env python3
"""
Security Collector - Attack detection, access control, compliance
Collects: SSH failures, auth logs, firewall, file integrity, users, Docker security
"""
import subprocess
import json
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip
from typing import Optional

# Configuration
SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "security"
DATE = datetime.now().strftime("%Y-%m-%d")
HOUR = datetime.now().strftime("%H")

# VMs via WireGuard VPN



def ssh_cmd(vm_id: str, cmd: str) -> str:
    """Execute command on remote host using config.py."""
    try:
        ssh_command = get_ssh_command(vm_id, cmd)
        result = subprocess.run(ssh_command, capture_output=True, text=True, timeout=30)
        return result.stdout if result.returncode == 0 else f"ERROR: {result.stderr}"
    except subprocess.TimeoutExpired:
        return "ERROR: Timeout"
    except Exception as e:
        return f"ERROR: {e}"


def collect_failed_ssh(vm_id: str) -> dict:
    """Collect failed SSH attempts."""
    cmd = """
    if [ -f /var/log/auth.log ]; then
        grep -E 'Failed password|Invalid user|authentication failure' /var/log/auth.log 2>/dev/null | tail -200
    else
        journalctl -u sshd --since '24 hours ago' 2>/dev/null | grep -iE 'failed|invalid|error' | tail -200
    fi
    """
    output = ssh_cmd(vm_id, cmd)

    # Parse IPs
    ips = {}
    for line in output.split('\n'):
        import re
        matches = re.findall(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', line)
        for ip in matches:
            ips[ip] = ips.get(ip, 0) + 1

    return {
        "raw": output,
        "top_ips": sorted(ips.items(), key=lambda x: x[1], reverse=True)[:20],
        "total_attempts": sum(ips.values())
    }


def collect_auth_events(vm_id: str) -> dict:
    """Collect authentication events."""
    cmd = """
    echo '=== LOGINS ==='
    last -n 30 2>/dev/null || echo 'N/A'
    echo '=== SESSIONS ==='
    who 2>/dev/null || echo 'N/A'
    echo '=== SUDO ==='
    if [ -f /var/log/auth.log ]; then
        grep 'sudo:' /var/log/auth.log 2>/dev/null | tail -50
    else
        journalctl | grep 'sudo:' 2>/dev/null | tail -50
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_firewall(vm_id: str) -> dict:
    """Collect firewall blocks and rules."""
    cmd = """
    echo '=== IPTABLES ==='
    iptables -L -n -v 2>/dev/null | head -50 || echo 'N/A'
    echo '=== UFW ==='
    ufw status verbose 2>/dev/null || echo 'N/A'
    echo '=== BLOCKED ==='
    if [ -f /var/log/ufw.log ]; then
        grep 'BLOCK' /var/log/ufw.log 2>/dev/null | tail -30
    fi
    dmesg | grep -i 'dropped\|blocked' 2>/dev/null | tail -20
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_file_integrity(vm_id: str) -> dict:
    """Collect file integrity info."""
    cmd = """
    echo '=== MODIFIED /etc (24h) ==='
    find /etc -type f -mtime -1 2>/dev/null | head -30
    echo '=== SUID/SGID ==='
    find /usr -type f \\( -perm -4000 -o -perm -2000 \\) 2>/dev/null | head -30
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_users(vm_id: str) -> dict:
    """Collect user information."""
    cmd = """
    echo '=== USERS ==='
    cut -d: -f1,3,7 /etc/passwd | grep -v nologin | grep -v false
    echo '=== UID 0 ==='
    awk -F: '$3 == 0 {print $1}' /etc/passwd
    echo '=== SUDOERS ==='
    grep -v '^#' /etc/sudoers 2>/dev/null | grep -v '^$' | head -20
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_docker_security(vm_id: str) -> dict:
    """Collect Docker security info."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== PRIVILEGED ==='
        docker ps -q | xargs -I {} docker inspect {} --format '{{.Name}}: priv={{.HostConfig.Privileged}} net={{.HostConfig.NetworkMode}}' 2>/dev/null
        echo '=== EVENTS ==='
        docker events --since '24h' --until 'now' --filter 'type=container' 2>/dev/null | grep -E 'kill|die|oom' | tail -20
    else
        echo 'Docker not installed'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_open_ports(vm_id: str) -> dict:
    """Collect open ports."""
    cmd = "ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_all() -> dict:
    """Collect security data from all VMs."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {}
    }

    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"Collecting security data from {vm_id} ({ip})...")

        # Check connectivity
        ping = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True)
        if ping.returncode != 0:
            results["vms"][vm_id] = {"status": "unreachable", "ip": ip}
            continue

        results["vms"][vm_id] = {
            "status": "ok",
            "ip": ip,
            "failed_ssh": collect_failed_ssh(vm_id),
            "auth_events": collect_auth_events(vm_id),
            "firewall": collect_firewall(vm_id),
            "file_integrity": collect_file_integrity(vm_id),
            "users": collect_users(vm_id),
            "docker_security": collect_docker_security(vm_id),
            "open_ports": collect_open_ports(vm_id),
        }

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"security_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
