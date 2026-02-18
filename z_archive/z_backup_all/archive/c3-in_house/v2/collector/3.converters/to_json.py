#!/usr/bin/env python3
"""
Converter: Raw logs → Clean JSON for API
Processes raw collector output into structured JSON for dashboard API
"""
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Optional

SCRIPT_DIR = Path(__file__).parent
RAW_DIR = SCRIPT_DIR.parent / "2.raw"
JSON_DIR = SCRIPT_DIR.parent / "4.jsons"
DATE = datetime.now().strftime("%Y-%m-%d")


def load_latest_raw(category: str) -> Optional[dict]:
    """Load the most recent raw file for a category."""
    raw_path = RAW_DIR / category / DATE
    if not raw_path.exists():
        # Try yesterday
        from datetime import timedelta
        yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        raw_path = RAW_DIR / category / yesterday

    if not raw_path.exists():
        return None

    # Get most recent file
    files = sorted(raw_path.glob("*.json"), reverse=True)
    if not files:
        return None

    with open(files[0], 'r') as f:
        return json.load(f)


# =============================================================================
# Security Converter
# =============================================================================

def convert_security() -> dict:
    """Convert raw security data to clean JSON."""
    raw = load_latest_raw("security")
    if not raw:
        return {"error": "No raw security data", "vms": {}, "alerts": [], "summary": {}}

    result = {
        "date": raw.get("date"),
        "timestamp": raw.get("timestamp"),
        "vms": {},
        "alerts": [],
        "summary": {
            "total_failed_ssh": 0,
            "unique_attackers": set(),
            "vms_with_issues": 0
        }
    }

    for vm, data in raw.get("vms", {}).items():
        if data.get("status") == "unreachable":
            result["alerts"].append({
                "level": "critical",
                "vm": vm,
                "message": "VM unreachable"
            })
            continue

        vm_result = {"failed_ssh": [], "open_ports": [], "issues": []}

        # Parse failed SSH
        if "failed_ssh" in data:
            ssh_data = data["failed_ssh"]
            vm_result["failed_ssh"] = ssh_data.get("top_ips", [])
            vm_result["total_failed_attempts"] = ssh_data.get("total_attempts", 0)
            result["summary"]["total_failed_ssh"] += ssh_data.get("total_attempts", 0)

            for ip, count in ssh_data.get("top_ips", []):
                result["summary"]["unique_attackers"].add(ip)
                if count > 100:
                    result["alerts"].append({
                        "level": "warning",
                        "vm": vm,
                        "message": f"High SSH attack volume from {ip}: {count} attempts"
                    })

        # Parse open ports
        if "open_ports" in data:
            raw_ports = data["open_ports"].get("raw", "")
            for line in raw_ports.split('\n'):
                if 'LISTEN' in line:
                    parts = line.split()
                    if len(parts) >= 5:
                        vm_result["open_ports"].append({
                            "port": parts[4],
                            "process": parts[-1] if len(parts) > 5 else "unknown"
                        })

        result["vms"][vm] = vm_result

    result["summary"]["unique_attackers"] = len(result["summary"]["unique_attackers"])
    return result


# =============================================================================
# Performance Converter
# =============================================================================

def convert_performance() -> dict:
    """Convert raw performance data to clean JSON."""
    raw = load_latest_raw("performance")
    if not raw:
        return {"error": "No raw performance data", "vms": {}, "alerts": [], "summary": {}}

    result = {
        "date": raw.get("date"),
        "timestamp": raw.get("timestamp"),
        "vms": {},
        "alerts": [],
        "summary": {}
    }

    for vm, data in raw.get("vms", {}).items():
        if data.get("status") == "unreachable":
            continue

        vm_result = {}

        # Parse system stats
        if "system" in data:
            raw_sys = data["system"].get("raw", "")

            # Extract load average
            load_match = re.search(r'load average: ([\d.]+)', raw_sys)
            if load_match:
                load = float(load_match.group(1))
                vm_result["load_1m"] = load
                if load > 2.0:
                    result["alerts"].append({
                        "level": "warning",
                        "vm": vm,
                        "message": f"High load average: {load}"
                    })

            # Extract memory
            mem_match = re.search(r'Mem:\s+(\d+)\s+(\d+)\s+(\d+)', raw_sys)
            if mem_match:
                total, used, free = map(int, mem_match.groups())
                vm_result["memory"] = {
                    "total_mb": total,
                    "used_mb": used,
                    "free_mb": free,
                    "percent": round(used / total * 100, 1) if total > 0 else 0
                }
                if vm_result["memory"]["percent"] > 90:
                    result["alerts"].append({
                        "level": "critical",
                        "vm": vm,
                        "message": f"Memory critical: {vm_result['memory']['percent']}%"
                    })

        # Parse disk
        if "disk" in data:
            raw_disk = data["disk"].get("raw", "")
            vm_result["disk"] = []
            for line in raw_disk.split('\n'):
                if '%' in line and '/dev' in line:
                    parts = line.split()
                    if len(parts) >= 5:
                        usage = int(parts[4].replace('%', ''))
                        vm_result["disk"].append({
                            "mount": parts[5] if len(parts) > 5 else parts[0],
                            "size": parts[1],
                            "used": parts[2],
                            "percent": usage
                        })
                        if usage > 90:
                            result["alerts"].append({
                                "level": "critical",
                                "vm": vm,
                                "message": f"Disk critical: {parts[5] if len(parts) > 5 else parts[0]} at {usage}%"
                            })

        # Parse docker stats
        if "docker" in data:
            raw_docker = data["docker"].get("raw", "")
            vm_result["docker"] = []
            in_stats = False
            for line in raw_docker.split('\n'):
                if '=== STATS ===' in line:
                    in_stats = True
                    continue
                if in_stats and line.strip() and not line.startswith('NAME'):
                    parts = line.split()
                    if len(parts) >= 4:
                        vm_result["docker"].append({
                            "name": parts[0],
                            "cpu": parts[1],
                            "mem": parts[2]
                        })

        result["vms"][vm] = vm_result

    return result


# =============================================================================
# Availability Converter
# =============================================================================

def convert_availability() -> dict:
    """Convert raw availability data to clean JSON."""
    raw = load_latest_raw("availability")
    if not raw:
        return {"error": "No raw availability data", "current_status": {}, "alerts": [], "summary": {}}

    result = {
        "date": raw.get("date"),
        "timestamp": raw.get("timestamp"),
        "current_status": {
            "vms": [],
            "endpoints": [],
            "ssl": []
        },
        "alerts": [],
        "summary": {
            "vms_reachable": 0,
            "vms_unreachable": 0,
            "endpoints_up": 0,
            "endpoints_down": 0,
            "ssl_ok": 0,
            "ssl_warning": 0,
            "ssl_critical": 0
        }
    }

    # VMs
    for vm, data in raw.get("vms", {}).items():
        ping_status = data.get("ping", {}).get("status", "unknown")
        ssh_status = data.get("ssh", {}).get("status", "unknown")

        result["current_status"]["vms"].append({
            "name": vm,
            "ip": data.get("ip"),
            "ping": ping_status,
            "ssh": ssh_status,
            "latency_ms": data.get("ping", {}).get("latency_ms")
        })

        if ping_status == "up":
            result["summary"]["vms_reachable"] += 1
        else:
            result["summary"]["vms_unreachable"] += 1
            result["alerts"].append({
                "level": "critical",
                "message": f"VM {vm} unreachable"
            })

    # Endpoints
    for ep in raw.get("endpoints", []):
        result["current_status"]["endpoints"].append({
            "url": ep.get("url"),
            "status": ep.get("status"),
            "code": ep.get("code"),
            "latency_ms": ep.get("latency_ms")
        })

        if ep.get("status") == "up":
            result["summary"]["endpoints_up"] += 1
        else:
            result["summary"]["endpoints_down"] += 1
            result["alerts"].append({
                "level": "critical",
                "message": f"Endpoint down: {ep.get('url')}"
            })

    # SSL
    for cert in raw.get("ssl", []):
        result["current_status"]["ssl"].append({
            "domain": cert.get("domain"),
            "status": cert.get("status"),
            "days_left": cert.get("days_left"),
            "expires": cert.get("expires")
        })

        status = cert.get("status", "unknown")
        if status == "ok":
            result["summary"]["ssl_ok"] += 1
        elif status == "warning":
            result["summary"]["ssl_warning"] += 1
            result["alerts"].append({
                "level": "warning",
                "message": f"SSL expiring soon: {cert.get('domain')} ({cert.get('days_left')} days)"
            })
        elif status == "critical":
            result["summary"]["ssl_critical"] += 1
            result["alerts"].append({
                "level": "critical",
                "message": f"SSL critical: {cert.get('domain')} ({cert.get('days_left')} days)"
            })

    return result


# =============================================================================
# Web Converter
# =============================================================================

def convert_web() -> dict:
    """Convert raw web data to clean JSON."""
    raw = load_latest_raw("web")
    if not raw:
        return {"error": "No raw web data", "vms": {}, "alerts": [], "summary": {}}

    result = {
        "date": raw.get("date"),
        "timestamp": raw.get("timestamp"),
        "vms": {},
        "alerts": [],
        "summary": {
            "total_requests": 0,
            "total_errors": 0,
            "suspicious_count": 0
        }
    }

    for vm, data in raw.get("vms", {}).items():
        if data.get("status") == "unreachable":
            continue

        vm_result = {
            "top_ips": [],
            "top_error_ips": [],
            "status_codes": {},
            "suspicious_requests": [],
            "scanner_agents": []
        }

        # Parse top IPs
        if "top_ips" in data:
            raw_ips = data["top_ips"].get("raw", "")
            for line in raw_ips.split('\n'):
                if line.strip() and re.match(r'\s*\d+\s+\d+\.', line):
                    parts = line.split()
                    if len(parts) >= 2:
                        vm_result["top_ips"].append({
                            "ip": parts[1],
                            "count": int(parts[0])
                        })

        # Parse status codes
        if "status_codes" in data:
            raw_codes = data["status_codes"].get("raw", "")
            for line in raw_codes.split('\n'):
                if '" ' in line:
                    parts = line.split()
                    if len(parts) >= 2:
                        code = parts[1].strip('"').strip()
                        if code.isdigit():
                            vm_result["status_codes"][code] = int(parts[0])

        # Parse suspicious requests
        if "suspicious" in data:
            raw_susp = data["suspicious"].get("raw", "")
            lines = [l for l in raw_susp.split('\n') if l.strip() and 'SUSPICIOUS' not in l and '===' not in l]
            vm_result["suspicious_requests"] = lines[:20]
            result["summary"]["suspicious_count"] += len(lines)

            if len(lines) > 10:
                result["alerts"].append({
                    "level": "warning",
                    "vm": vm,
                    "message": f"{len(lines)} suspicious requests detected"
                })

        result["vms"][vm] = vm_result

    return result


# =============================================================================
# Docker Converter
# =============================================================================

def convert_docker() -> dict:
    """Convert raw docker data to clean JSON."""
    raw = load_latest_raw("docker")
    if not raw:
        return {"error": "No raw docker data", "vms": {}, "alerts": [], "summary": {}}

    result = {
        "date": raw.get("date"),
        "timestamp": raw.get("timestamp"),
        "vms": {},
        "alerts": [],
        "summary": {
            "total_containers": 0,
            "running": 0,
            "stopped": 0,
            "unhealthy": 0
        }
    }

    for vm, data in raw.get("vms", {}).items():
        if data.get("status") == "unreachable":
            continue

        vm_result = {"containers": [], "errors": []}

        # Parse container stats
        if "stats" in data:
            raw_stats = data["stats"].get("raw", "")
            in_json = False
            for line in raw_stats.split('\n'):
                if line.startswith('{'):
                    try:
                        c = json.loads(line)
                        vm_result["containers"].append({
                            "name": c.get("Name"),
                            "cpu": c.get("CPUPerc"),
                            "memory": c.get("MemUsage"),
                            "mem_percent": c.get("MemPerc"),
                            "net_io": c.get("NetIO"),
                            "block_io": c.get("BlockIO")
                        })
                        result["summary"]["total_containers"] += 1
                        result["summary"]["running"] += 1
                    except json.JSONDecodeError:
                        continue

        # Parse health status
        if "health" in data:
            raw_health = data["health"].get("raw", "")
            for line in raw_health.split('\n'):
                if 'health=' in line:
                    if 'unhealthy' in line:
                        result["summary"]["unhealthy"] += 1
                        name = line.split(':')[0].strip('/')
                        result["alerts"].append({
                            "level": "warning",
                            "vm": vm,
                            "message": f"Unhealthy container: {name}"
                        })

        # Parse restarts
        if "restarts" in data:
            raw_restarts = data["restarts"].get("raw", "")
            for line in raw_restarts.split('\n'):
                if 'restarts' in line and ':' in line:
                    parts = line.split(':')
                    name = parts[0].strip()
                    count = int(re.search(r'(\d+)', parts[1]).group(1)) if re.search(r'(\d+)', parts[1]) else 0
                    if count > 5:
                        result["alerts"].append({
                            "level": "warning",
                            "vm": vm,
                            "message": f"Container {name} has {count} restarts"
                        })

        # Parse errors
        if "logs_errors" in data:
            raw_errors = data["logs_errors"].get("raw", "")
            lines = [l for l in raw_errors.split('\n') if l.strip() and '---' not in l and '===' not in l]
            vm_result["errors"] = lines[:20]

        result["vms"][vm] = vm_result

    return result


# =============================================================================
# Costs Converter
# =============================================================================

def convert_costs() -> dict:
    """Convert raw costs data to clean JSON."""
    month = datetime.now().strftime("%Y-%m")
    raw_path = RAW_DIR / "costs" / month

    if not raw_path.exists():
        return {"error": "No raw costs data", "summary": {}}

    files = sorted(raw_path.glob("*.json"), reverse=True)
    if not files:
        return {"error": "No raw costs data", "summary": {}}

    with open(files[0], 'r') as f:
        raw = json.load(f)

    return {
        "date": raw.get("date"),
        "month": raw.get("month"),
        "gcp": raw.get("gcp", {}),
        "oci": raw.get("oci", {}),
        "claude": raw.get("claude", {}),
        "resources": raw.get("resources", {}),
        "summary": {
            "estimated_monthly_cost": raw.get("claude", {}).get("usage", {}).get("estimated_cost_usd", 0),
            "cloud_cost": "Free tier"
        }
    }


# =============================================================================
# Dashboard Aggregator
# =============================================================================

def create_dashboard() -> dict:
    """Create combined dashboard JSON with all alerts."""
    security = convert_security()
    performance = convert_performance()
    availability = convert_availability()
    web = convert_web()
    docker = convert_docker()
    costs = convert_costs()

    # Combine all alerts
    all_alerts = []
    for data in [security, performance, availability, web, docker]:
        all_alerts.extend(data.get("alerts", []))

    # Sort by level
    level_order = {"critical": 0, "warning": 1, "info": 2}
    all_alerts.sort(key=lambda x: level_order.get(x.get("level"), 3))

    return {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "status": {
            "security": "ok" if not security.get("alerts") else "warning",
            "performance": "ok" if not performance.get("alerts") else "warning",
            "availability": "ok" if not availability.get("alerts") else "warning",
            "web": "ok" if not web.get("alerts") else "warning",
            "docker": "ok" if not docker.get("alerts") else "warning",
        },
        "alerts": all_alerts[:50],  # Top 50 alerts
        "summary": {
            "security": security.get("summary", {}),
            "performance": performance.get("summary", {}),
            "availability": availability.get("summary", {}),
            "web": web.get("summary", {}),
            "docker": docker.get("summary", {}),
            "costs": costs.get("summary", {}),
        }
    }


# =============================================================================
# Main
# =============================================================================

def convert_all():
    """Convert all raw data to clean JSON."""
    JSON_DIR.mkdir(parents=True, exist_ok=True)

    converters = {
        "security.json": convert_security,
        "performance.json": convert_performance,
        "availability.json": convert_availability,
        "web.json": convert_web,
        "docker.json": convert_docker,
        "costs.json": convert_costs,
        "dashboard.json": create_dashboard,
    }

    for filename, converter in converters.items():
        print(f"Converting {filename}...")
        data = converter()
        output_file = JSON_DIR / filename

        with open(output_file, 'w') as f:
            json.dump(data, f, indent=2, default=str)

        print(f"  Saved: {output_file}")


if __name__ == "__main__":
    convert_all()
