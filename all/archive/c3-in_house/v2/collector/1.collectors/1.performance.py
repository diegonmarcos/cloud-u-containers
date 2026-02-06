#!/usr/bin/env python3
"""
Performance Collector - Resource usage, bottlenecks, health
Collects: CPU, RAM, disk, network, load, docker stats, OOM events
"""
import subprocess
import json
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "performance"
DATE = datetime.now().strftime("%Y-%m-%d")
HOUR = datetime.now().strftime("%H")


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


def collect_system_stats(vm_id: str) -> dict:
    """Collect CPU, RAM, load averages."""
    cmd = "uptime; echo '=== MEMORY ==='; free -m; echo '=== TOP ==='; ps aux --sort=-%mem | head -10"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_disk(vm_id: str) -> dict:
    """Collect disk space and I/O."""
    cmd = "df -h; echo '=== INODES ==='; df -i | grep -v tmpfs"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_network(vm_id: str) -> dict:
    """Collect network stats."""
    cmd = "ss -s 2>/dev/null || netstat -s | head -20"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_docker_stats(vm_id: str) -> dict:
    """Collect Docker container stats."""
    cmd = "docker ps --format 'table {{.Names}}\\t{{.Status}}' 2>/dev/null; docker stats --no-stream --format 'table {{.Name}}\\t{{.CPUPerc}}\\t{{.MemUsage}}' 2>/dev/null || echo 'No docker'"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_services(vm_id: str) -> dict:
    """Collect systemd service status."""
    cmd = "systemctl --failed 2>/dev/null || echo 'N/A'"
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_all() -> dict:
    """Collect performance data from all VMs."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {}
    }

    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"Collecting performance data from {vm_id} ({ip})...")

        # Quick ping check
        ping = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True)
        if ping.returncode != 0:
            results["vms"][vm_id] = {"status": "unreachable", "ip": ip}
            continue

        results["vms"][vm_id] = {
            "status": "ok",
            "ip": ip,
            "system": collect_system_stats(vm_id),
            "disk": collect_disk(vm_id),
            "network": collect_network(vm_id),
            "docker": collect_docker_stats(vm_id),
            "services": collect_services(vm_id),
        }

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"performance_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
