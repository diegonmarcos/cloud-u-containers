#!/usr/bin/env python3
"""
Converter: JSON → CSV Files
Generates structured CSV files for data analysis and spreadsheet import
"""
import csv
import json
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
JSON_DIR = SCRIPT_DIR.parent / "4.jsons"
CSV_DIR = SCRIPT_DIR.parent / "4.md_csv"
DATE = datetime.now().strftime("%Y-%m-%d")


def load_json(filename: str) -> dict:
    """Load a JSON file from 4.jsons/."""
    path = JSON_DIR / filename
    if not path.exists():
        return {}
    with open(path, 'r') as f:
        return json.load(f)


def write_csv(filename: str, rows: list, headers: list):
    """Write rows to a CSV file."""
    output_file = CSV_DIR / filename
    with open(output_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(headers)
        writer.writerows(rows)
    print(f"  Saved: {output_file}")


# =============================================================================
# Alerts CSV
# =============================================================================

def generate_alerts_csv():
    """Generate CSV of all alerts from dashboard."""
    data = load_json("dashboard.json")
    if not data:
        return

    rows = []
    for alert in data.get("alerts", []):
        rows.append([
            data.get("date", DATE),
            data.get("timestamp", ""),
            alert.get("level", ""),
            alert.get("vm", ""),
            alert.get("message", ""),
        ])

    write_csv("alerts.csv", rows, ["date", "timestamp", "level", "vm", "message"])


# =============================================================================
# Availability CSV
# =============================================================================

def generate_availability_csv():
    """Generate availability CSV files."""
    data = load_json("availability.json")
    if not data or data.get("error"):
        return

    current = data.get("current_status", {})
    timestamp = data.get("timestamp", "")

    # VMs
    vm_rows = []
    for vm in current.get("vms", []):
        vm_rows.append([
            DATE,
            timestamp,
            vm.get("name", ""),
            vm.get("ip", ""),
            vm.get("ping", ""),
            vm.get("ssh", ""),
            vm.get("latency_ms", ""),
        ])
    write_csv("availability_vms.csv", vm_rows,
              ["date", "timestamp", "vm", "ip", "ping", "ssh", "latency_ms"])

    # Endpoints
    ep_rows = []
    for ep in current.get("endpoints", []):
        ep_rows.append([
            DATE,
            timestamp,
            ep.get("url", ""),
            ep.get("status", ""),
            ep.get("code", ""),
            ep.get("latency_ms", ""),
        ])
    write_csv("availability_endpoints.csv", ep_rows,
              ["date", "timestamp", "url", "status", "code", "latency_ms"])

    # SSL
    ssl_rows = []
    for cert in current.get("ssl", []):
        ssl_rows.append([
            DATE,
            timestamp,
            cert.get("domain", ""),
            cert.get("status", ""),
            cert.get("days_left", ""),
            cert.get("expires", ""),
        ])
    write_csv("availability_ssl.csv", ssl_rows,
              ["date", "timestamp", "domain", "status", "days_left", "expires"])


# =============================================================================
# Security CSV
# =============================================================================

def generate_security_csv():
    """Generate security CSV files."""
    data = load_json("security.json")
    if not data or data.get("error"):
        return

    timestamp = data.get("timestamp", "")

    # Failed SSH per IP
    ssh_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for ip, count in vm_data.get("failed_ssh", []):
            ssh_rows.append([
                DATE,
                timestamp,
                vm,
                ip,
                count,
            ])
    write_csv("security_failed_ssh.csv", ssh_rows,
              ["date", "timestamp", "vm", "attacker_ip", "attempts"])

    # Open ports
    port_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for port in vm_data.get("open_ports", []):
            port_rows.append([
                DATE,
                timestamp,
                vm,
                port.get("port", ""),
                port.get("process", ""),
            ])
    write_csv("security_open_ports.csv", port_rows,
              ["date", "timestamp", "vm", "port", "process"])


# =============================================================================
# Performance CSV
# =============================================================================

def generate_performance_csv():
    """Generate performance CSV files."""
    data = load_json("performance.json")
    if not data or data.get("error"):
        return

    timestamp = data.get("timestamp", "")

    # System metrics
    sys_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        mem = vm_data.get("memory", {})
        sys_rows.append([
            DATE,
            timestamp,
            vm,
            vm_data.get("load_1m", ""),
            mem.get("total_mb", ""),
            mem.get("used_mb", ""),
            mem.get("free_mb", ""),
            mem.get("percent", ""),
        ])
    write_csv("performance_system.csv", sys_rows,
              ["date", "timestamp", "vm", "load_1m", "mem_total_mb", "mem_used_mb", "mem_free_mb", "mem_percent"])

    # Disk metrics
    disk_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for disk in vm_data.get("disk", []):
            disk_rows.append([
                DATE,
                timestamp,
                vm,
                disk.get("mount", ""),
                disk.get("size", ""),
                disk.get("used", ""),
                disk.get("percent", ""),
            ])
    write_csv("performance_disk.csv", disk_rows,
              ["date", "timestamp", "vm", "mount", "size", "used", "percent"])

    # Docker metrics
    docker_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for c in vm_data.get("docker", []):
            docker_rows.append([
                DATE,
                timestamp,
                vm,
                c.get("name", ""),
                c.get("cpu", ""),
                c.get("mem", ""),
            ])
    write_csv("performance_docker.csv", docker_rows,
              ["date", "timestamp", "vm", "container", "cpu", "memory"])


# =============================================================================
# Docker CSV
# =============================================================================

def generate_docker_csv():
    """Generate docker CSV files."""
    data = load_json("docker.json")
    if not data or data.get("error"):
        return

    timestamp = data.get("timestamp", "")

    # Container inventory
    container_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for c in vm_data.get("containers", []):
            container_rows.append([
                DATE,
                timestamp,
                vm,
                c.get("name", ""),
                c.get("cpu", ""),
                c.get("memory", ""),
                c.get("mem_percent", ""),
                c.get("net_io", ""),
                c.get("block_io", ""),
            ])
    write_csv("docker_containers.csv", container_rows,
              ["date", "timestamp", "vm", "name", "cpu", "memory", "mem_percent", "net_io", "block_io"])


# =============================================================================
# Web Traffic CSV
# =============================================================================

def generate_web_csv():
    """Generate web traffic CSV files."""
    data = load_json("web.json")
    if not data or data.get("error"):
        return

    timestamp = data.get("timestamp", "")

    # Top IPs
    ip_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for ip_data in vm_data.get("top_ips", []):
            ip_rows.append([
                DATE,
                timestamp,
                vm,
                ip_data.get("ip", ""),
                ip_data.get("count", ""),
            ])
    write_csv("web_top_ips.csv", ip_rows,
              ["date", "timestamp", "vm", "ip", "requests"])

    # Status codes
    code_rows = []
    for vm, vm_data in data.get("vms", {}).items():
        for code, count in vm_data.get("status_codes", {}).items():
            code_rows.append([
                DATE,
                timestamp,
                vm,
                code,
                count,
            ])
    write_csv("web_status_codes.csv", code_rows,
              ["date", "timestamp", "vm", "status_code", "count"])


# =============================================================================
# Costs CSV
# =============================================================================

def generate_costs_csv():
    """Generate costs CSV files."""
    data = load_json("costs.json")
    if not data or data.get("error"):
        return

    claude = data.get("claude", {})
    usage = claude.get("usage", {})

    # Token usage
    token_rows = []
    for period in ["today", "week", "month"]:
        period_data = usage.get(period, {})
        if period_data:
            token_rows.append([
                DATE,
                data.get("month", ""),
                period,
                period_data.get("input", 0),
                period_data.get("output", 0),
            ])

    write_csv("costs_tokens.csv", token_rows,
              ["date", "month", "period", "input_tokens", "output_tokens"])

    # Summary
    summary_rows = [[
        DATE,
        data.get("month", ""),
        data.get("gcp", {}).get("status", ""),
        data.get("gcp", {}).get("tier", ""),
        data.get("oci", {}).get("status", ""),
        data.get("oci", {}).get("tier", ""),
        usage.get("estimated_cost_usd", 0),
    ]]
    write_csv("costs_summary.csv", summary_rows,
              ["date", "month", "gcp_status", "gcp_tier", "oci_status", "oci_tier", "ai_cost_usd"])


# =============================================================================
# Main
# =============================================================================

def convert_all():
    """Generate all CSV files."""
    CSV_DIR.mkdir(parents=True, exist_ok=True)

    generators = [
        ("alerts", generate_alerts_csv),
        ("availability", generate_availability_csv),
        ("security", generate_security_csv),
        ("performance", generate_performance_csv),
        ("docker", generate_docker_csv),
        ("web", generate_web_csv),
        ("costs", generate_costs_csv),
    ]

    for name, generator in generators:
        print(f"Generating {name} CSVs...")
        generator()


if __name__ == "__main__":
    convert_all()
