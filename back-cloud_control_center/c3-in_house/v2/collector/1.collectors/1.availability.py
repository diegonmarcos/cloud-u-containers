#!/usr/bin/env python3
"""
Availability Collector - Uptime, health checks, SSL expiry
Collects: Ping, SSH, HTTP endpoints, SSL certs, DNS, ports
"""
import subprocess
import socket
import ssl
import json
from datetime import datetime
from pathlib import Path
from config import get_active_vms, get_ssh_command, get_vm_ip
from urllib.request import urlopen, Request
from urllib.error import URLError

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw" / "availability"
DATE = datetime.now().strftime("%Y-%m-%d")
HOUR = datetime.now().strftime("%H")

# VMs to check

# HTTP endpoints to check
ENDPOINTS = [
    "https://diegonmarcos.com",
    "https://photos.app.diegonmarcos.com",
    "https://analytics.diegonmarcos.com",
    "https://sync.diegonmarcos.com",
    "https://n8n.diegonmarcos.com",
    "https://proxy.diegonmarcos.com",
    "https://auth.diegonmarcos.com",
]

# SSL certificates to check
SSL_DOMAINS = [
    "diegonmarcos.com",
    "photos.app.diegonmarcos.com",
    "analytics.diegonmarcos.com",
    "sync.diegonmarcos.com",
    "n8n.diegonmarcos.com",
]



def check_ping(host: str) -> dict:
    """Check if host is reachable via ping."""
    try:
        result = subprocess.run(
            ["ping", "-c", "3", "-W", "2", host],
            capture_output=True, text=True, timeout=10
        )
        # Parse average latency
        latency = None
        if "avg" in result.stdout:
            import re
            match = re.search(r'avg[^=]*=\s*[\d.]+/([\d.]+)', result.stdout)
            if match:
                latency = float(match.group(1))

        return {
            "status": "up" if result.returncode == 0 else "down",
            "latency_ms": latency,
            "raw": result.stdout
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def check_ssh(vm_id: str) -> dict:
    """Check if SSH is accessible using config.py."""
    try:
        ssh_command = get_ssh_command(vm_id, "echo OK")
        result = subprocess.run(ssh_command, capture_output=True, text=True, timeout=10)
        return {
            "status": "ok" if result.returncode == 0 else "fail",
            "output": result.stdout.strip()
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def check_http(url: str) -> dict:
    """Check HTTP endpoint."""
    try:
        start = datetime.now()
        req = Request(url, headers={"User-Agent": "C3-Monitor/1.0"})
        response = urlopen(req, timeout=10)
        elapsed = (datetime.now() - start).total_seconds() * 1000

        return {
            "status": "up",
            "code": response.getcode(),
            "latency_ms": round(elapsed, 2)
        }
    except URLError as e:
        return {"status": "down", "error": str(e.reason)}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def check_ssl(domain: str, port: int = 443) -> dict:
    """Check SSL certificate expiry."""
    try:
        context = ssl.create_default_context()
        with socket.create_connection((domain, port), timeout=10) as sock:
            with context.wrap_socket(sock, server_hostname=domain) as ssock:
                cert = ssock.getpeercert()
                expire_date = datetime.strptime(cert['notAfter'], '%b %d %H:%M:%S %Y %Z')
                days_left = (expire_date - datetime.now()).days

                return {
                    "status": "ok" if days_left > 14 else ("warning" if days_left > 7 else "critical"),
                    "expires": expire_date.isoformat(),
                    "days_left": days_left,
                    "issuer": dict(x[0] for x in cert.get('issuer', []))
                }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def check_dns(domain: str) -> dict:
    """Check DNS resolution."""
    try:
        result = subprocess.run(
            ["nslookup", domain],
            capture_output=True, text=True, timeout=10
        )
        return {
            "status": "ok" if result.returncode == 0 else "fail",
            "raw": result.stdout
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def check_port(host: str, port: int) -> dict:
    """Check if port is open."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        result = sock.connect_ex((host, port))
        sock.close()
        return {"status": "open" if result == 0 else "closed", "port": port}
    except Exception as e:
        return {"status": "error", "error": str(e)}


def collect_all() -> dict:
    """Collect availability data."""
    results = {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "hour": HOUR,
        "vms": {},
        "endpoints": [],
        "ssl": [],
        "dns": []
    }

    # Check VMs
    print("Checking VMs...")
    for vm_id, vm_config in get_active_vms().items():
        ip = get_vm_ip(vm_id)
        print(f"  {vm_id} ({ip})")
        results["vms"][vm_id] = {
            "ip": ip,
            "ping": check_ping(ip),
            "ssh": check_ssh(vm_id),
            "ports": {
                "22": check_port(ip, 22),
                "80": check_port(ip, 80),
                "443": check_port(ip, 443),
            }
        }

    # Check HTTP endpoints
    print("Checking HTTP endpoints...")
    for url in ENDPOINTS:
        print(f"  {url}")
        results["endpoints"].append({
            "url": url,
            **check_http(url)
        })

    # Check SSL certificates
    print("Checking SSL certificates...")
    for domain in SSL_DOMAINS:
        print(f"  {domain}")
        results["ssl"].append({
            "domain": domain,
            **check_ssl(domain)
        })

    # Check DNS
    print("Checking DNS...")
    for domain in SSL_DOMAINS:
        results["dns"].append({
            "domain": domain,
            **check_dns(domain)
        })

    return results


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / DATE
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"availability_{HOUR}00.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
