#!/usr/bin/env python3
"""
Backups/Data Collector - Backup status, sync health, data integrity
Collects: Backup status, backup size, restore test, Syncthing status
"""
import subprocess
import json
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "backups"
DATE = datetime.now().strftime("%Y-%m-%d")
HOUR = datetime.now().strftime("%H")

# VMs with backup/sync services


# Syncthing API (if accessible)
SYNCTHING_API = "http://10.0.0.3:8384"


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


def collect_syncthing_status(vm_id: str) -> dict:
    """Collect Syncthing sync status."""
    cmd = """
    # Check if Syncthing is running
    echo '=== SYNCTHING PROCESS ==='
    pgrep -a syncthing || echo 'Syncthing not running'

    # Check Syncthing container if Docker
    if command -v docker &>/dev/null; then
        echo '=== SYNCTHING CONTAINER ==='
        docker ps -a --filter 'name=syncthing' --format 'table {{.Names}}\t{{.Status}}'

        echo '=== SYNCTHING LOGS ==='
        docker logs syncthing --tail 50 2>&1 | grep -iE 'sync|error|warning|completed' | tail -20
    fi

    # Check sync folders size
    echo '=== SYNC FOLDERS ==='
    if [ -d ~/Sync ]; then
        du -sh ~/Sync/* 2>/dev/null | head -20
    fi
    if [ -d /data/syncthing ]; then
        du -sh /data/syncthing/* 2>/dev/null | head -20
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_backup_status(vm_id: str) -> dict:
    """Collect backup job status."""
    cmd = """
    echo '=== RECENT BACKUPS ==='
    # Check for common backup locations
    for dir in /backup /var/backup ~/backup /data/backup; do
        if [ -d "$dir" ]; then
            echo "--- $dir ---"
            ls -lht "$dir" 2>/dev/null | head -10
        fi
    done

    echo '=== BACKUP CRON JOBS ==='
    crontab -l 2>/dev/null | grep -i backup || echo 'No backup cron jobs'

    echo '=== SYSTEMD BACKUP TIMERS ==='
    systemctl list-timers 2>/dev/null | grep -i backup || echo 'No backup timers'
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_backup_sizes(vm_id: str) -> dict:
    """Collect backup sizes and growth."""
    cmd = """
    echo '=== BACKUP SIZES ==='
    for dir in /backup /var/backup ~/backup /data/backup /data/syncthing; do
        if [ -d "$dir" ]; then
            echo "--- $dir ---"
            du -sh "$dir" 2>/dev/null
            echo "Files by date:"
            find "$dir" -type f -mtime -7 -exec ls -lh {} \\; 2>/dev/null | tail -10
        fi
    done

    echo '=== DISK USAGE ==='
    df -h | grep -E '/data|/backup|/home'
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_database_backups(vm_id: str) -> dict:
    """Collect database backup status."""
    cmd = """
    echo '=== DATABASE BACKUPS ==='
    # Check for SQL dumps
    for dir in /backup /var/backup ~/backup /data/backup; do
        if [ -d "$dir" ]; then
            find "$dir" -name '*.sql*' -o -name '*.dump*' -mtime -7 2>/dev/null | head -10
        fi
    done

    # Check Docker volumes
    if command -v docker &>/dev/null; then
        echo '=== DOCKER VOLUMES ==='
        docker volume ls --format 'table {{.Name}}\t{{.Driver}}'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_restore_test(vm_id: str) -> dict:
    """Check if restore scripts exist and last test."""
    cmd = """
    echo '=== RESTORE SCRIPTS ==='
    for script in restore.sh backup-restore.sh recover.sh; do
        find /home -name "$script" 2>/dev/null
        find /opt -name "$script" 2>/dev/null
        find /root -name "$script" 2>/dev/null
    done

    echo '=== RESTORE LOGS ==='
    for log in /var/log/restore.log /var/log/backup-restore.log; do
        if [ -f "$log" ]; then
            echo "--- $log ---"
            tail -20 "$log"
        fi
    done
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_data_integrity(vm_id: str) -> dict:
    """Check data integrity (checksums, etc)."""
    cmd = """
    echo '=== CHECKSUM FILES ==='
    find /backup /data -name '*.sha256' -o -name '*.md5' 2>/dev/null | head -10

    echo '=== RECENT MODIFICATIONS ==='
    # Check for unexpected modifications in data dirs
    find /data -type f -mmin -60 2>/dev/null | head -20
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_all() -> dict:
    """Collect backup/data status from all VMs."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {}
    }

    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"Collecting backup data from {vm_id} ({ip})...")

        ping = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True)
        if ping.returncode != 0:
            results["vms"][vm_id] = {"status": "unreachable", "ip": ip}
            continue

        results["vms"][vm_id] = {
            "status": "ok",
            "ip": ip,
            "syncthing": collect_syncthing_status(vm_id),
            "backup_status": collect_backup_status(vm_id),
            "backup_sizes": collect_backup_sizes(vm_id),
            "database_backups": collect_database_backups(vm_id),
            "restore_test": collect_restore_test(vm_id),
            "data_integrity": collect_data_integrity(vm_id),
        }

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"backups_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
