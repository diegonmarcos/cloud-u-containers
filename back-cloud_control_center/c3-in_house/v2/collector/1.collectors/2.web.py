#!/usr/bin/env python3
"""
Web/HTTP Collector - Access logs, errors, suspicious patterns
Collects: NPM logs, HTTP 4xx/5xx, suspicious requests, scanners, top IPs
"""
import subprocess
import json
import re
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "web"
DATE = datetime.now().strftime("%Y-%m-%d")
HOUR = datetime.now().strftime("%H")

# Only GCP hub has NPM


# Suspicious patterns
SUSPICIOUS_PATTERNS = [
    r'\.\./',                    # Path traversal
    r'etc/passwd',               # File access
    r'\.php',                    # PHP probes
    r'wp-admin|wp-login',        # WordPress probes
    r'\.env',                    # Env file access
    r'\.git',                    # Git exposure
    r'admin|phpmyadmin',         # Admin probes
    r'shell|cmd|exec',           # Command injection
    r'<script|javascript:',      # XSS attempts
    r'SELECT.*FROM|UNION.*SELECT', # SQL injection
]


def ssh_cmd(vm_id: str, cmd: str) -> str:
    """Execute command on remote host using config.py."""
    try:
        ssh_command = get_ssh_command(vm_id, cmd)
        result = subprocess.run(ssh_command, capture_output=True, text=True, timeout=60)
        return result.stdout if result.returncode == 0 else f"ERROR: {result.stderr}"
    except subprocess.TimeoutExpired:
        return "ERROR: Timeout"
    except Exception as e:
        return f"ERROR: {e}"


def collect_npm_access(vm_id: str) -> dict:
    """Collect NPM access logs."""
    cmd = """
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== RECENT ACCESS ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec tail -200 {} \\; 2>/dev/null | tail -500
    else
        echo 'NPM logs not found'
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_npm_errors(vm_id: str) -> dict:
    """Collect NPM error logs."""
    cmd = """
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== ERROR LOGS ==='
        find "$NPM_LOGS" -name 'error*.log' -mtime -1 -exec cat {} \\; 2>/dev/null | tail -200
        echo '=== 4XX/5XX ERRORS ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec grep -E '" (4[0-9]{2}|5[0-9]{2}) ' {} \\; 2>/dev/null | tail -200
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_suspicious_requests(vm_id: str) -> dict:
    """Collect suspicious HTTP requests."""
    patterns = '|'.join(SUSPICIOUS_PATTERNS)
    cmd = f"""
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== SUSPICIOUS REQUESTS ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec grep -iE '{patterns}' {{}} \\; 2>/dev/null | tail -100
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_scanner_agents(vm_id: str) -> dict:
    """Collect scanner/bot user agents."""
    cmd = """
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== SCANNER USER AGENTS ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec cat {} \\; 2>/dev/null | \
            grep -iE 'nikto|sqlmap|nmap|masscan|zgrab|censys|shodan|nuclei|dirbuster|gobuster|wpscan|acunetix' | tail -50
        echo '=== BOT AGENTS ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec cat {} \\; 2>/dev/null | \
            grep -iE 'bot|crawler|spider|scraper' | head -50
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_top_ips(vm_id: str) -> dict:
    """Collect top requesting IPs."""
    cmd = """
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== TOP IPs (all) ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec cat {} \\; 2>/dev/null | \
            grep -oE '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | sort | uniq -c | sort -rn | head -30
        echo '=== TOP IPs (errors) ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec grep -E '" (4[0-9]{2}|5[0-9]{2}) ' {} \\; 2>/dev/null | \
            grep -oE '^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | sort | uniq -c | sort -rn | head -20
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_status_codes(vm_id: str) -> dict:
    """Collect HTTP status code distribution."""
    cmd = """
    NPM_LOGS="/home/diego/npm/data/logs"
    if [ -d "$NPM_LOGS" ]; then
        echo '=== STATUS CODE DISTRIBUTION ==='
        find "$NPM_LOGS" -name 'proxy-host-*.log' -mtime -1 -exec cat {} \\; 2>/dev/null | \
            grep -oE '" [0-9]{3} ' | sort | uniq -c | sort -rn
    fi
    """
    return {"raw": ssh_cmd(vm_id, cmd)}


def collect_all() -> dict:
    """Collect web data from all VMs."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {}
    }

    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"Collecting web data from {vm_id} ({ip})...")

        ping = subprocess.run(["ping", "-c", "1", "-W", "2", ip], capture_output=True)
        if ping.returncode != 0:
            results["vms"][vm_id] = {"status": "unreachable", "ip": ip}
            continue

        results["vms"][vm_id] = {
            "status": "ok",
            "ip": ip,
            "access": collect_npm_access(vm_id),
            "errors": collect_npm_errors(vm_id),
            "suspicious": collect_suspicious_requests(vm_id),
            "scanners": collect_scanner_agents(vm_id),
            "top_ips": collect_top_ips(vm_id),
            "status_codes": collect_status_codes(vm_id),
        }

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"web_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
