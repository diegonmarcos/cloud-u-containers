#!/usr/bin/env python3
"""
Docker Collector - Container health, stats, logs, restarts
Collects: Container status, health, resources, restarts, errors
"""
import subprocess
import json
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "docker"
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


def collect_containers(vm_id: str) -> dict:
    """Collect container list and status."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== ALL CONTAINERS ==='
        docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'
        echo '=== JSON ==='
        docker ps -a --format '{{json .}}'
    else
        echo 'Docker not installed'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_stats(vm_id: str) -> dict:
    """Collect container resource stats."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== STATS ==='
        docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}'
        echo '=== JSON ==='
        docker stats --no-stream --format '{{json .}}'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_health(vm_id: str) -> dict:
    """Collect container health status."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== HEALTH STATUS ==='
        for c in $(docker ps -q); do
            name=$(docker inspect $c --format '{{.Name}}')
            health=$(docker inspect $c --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}')
            restarts=$(docker inspect $c --format '{{.RestartCount}}')
            started=$(docker inspect $c --format '{{.State.StartedAt}}')
            echo "$name: health=$health restarts=$restarts started=$started"
        done
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_restarts(vm_id: str) -> dict:
    """Collect containers with high restart counts."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== RESTART COUNTS ==='
        docker ps -a --format '{{.Names}}' | while read name; do
            restarts=$(docker inspect "$name" --format '{{.RestartCount}}' 2>/dev/null)
            if [ "$restarts" -gt 0 ] 2>/dev/null; then
                echo "$name: $restarts restarts"
            fi
        done
        echo '=== RECENTLY DIED ==='
        docker ps -a --filter 'status=exited' --format 'table {{.Names}}\t{{.Status}}'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_logs_errors(vm_id: str) -> dict:
    """Collect error logs from containers."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== CONTAINER ERRORS (last 1h) ==='
        for c in $(docker ps -q); do
            name=$(docker inspect $c --format '{{.Name}}' | tr -d '/')
            errors=$(docker logs --since 1h "$c" 2>&1 | grep -iE 'error|fail|exception|fatal|panic|crash' | tail -10)
            if [ -n "$errors" ]; then
                echo "--- $name ---"
                echo "$errors"
            fi
        done
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_images(vm_id: str) -> dict:
    """Collect Docker images info."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== IMAGES ==='
        docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}'
        echo '=== DISK USAGE ==='
        docker system df
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_networks(vm_id: str) -> dict:
    """Collect Docker networks."""
    cmd = """
    if command -v docker &>/dev/null; then
        echo '=== NETWORKS ==='
        docker network ls
        echo '=== NETWORK DETAILS ==='
        for net in $(docker network ls -q); do
            echo "--- $net ---"
            docker network inspect $net --format '{{.Name}}: {{range .Containers}}{{.Name}} {{end}}' 2>/dev/null
        done
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_all() -> dict:
    """Collect Docker data from all VMs."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {}
    }

    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"Collecting Docker data from {vm_id} ({ip})...")

        ping = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True)
        if ping.returncode != 0:
            results["vms"][vm_id] = {"status": "unreachable", "ip": ip}
            continue

        results["vms"][vm_id] = {
            "status": "ok",
            "ip": ip,
            "containers": collect_containers(vm_id),
            "stats": collect_stats(vm_id),
            "health": collect_health(vm_id),
            "restarts": collect_restarts(vm_id),
            "logs_errors": collect_logs_errors(vm_id),
            "images": collect_images(vm_id),
            "networks": collect_networks(vm_id),
        }

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"docker_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
