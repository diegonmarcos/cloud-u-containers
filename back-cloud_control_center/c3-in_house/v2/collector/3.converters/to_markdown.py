#!/usr/bin/env python3
"""
Converter: JSON → Markdown Reports
Generates human-readable markdown reports from processed JSON data
"""
import json
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
JSON_DIR = SCRIPT_DIR.parent / "4.jsons"
MD_DIR = SCRIPT_DIR.parent / "4.md_csv"
DATE = datetime.now().strftime("%Y-%m-%d")


def load_json(filename: str) -> dict:
    """Load a JSON file from 4.jsons/."""
    path = JSON_DIR / filename
    if not path.exists():
        return {}
    with open(path, 'r') as f:
        return json.load(f)


# =============================================================================
# Dashboard Report
# =============================================================================

def generate_dashboard_md() -> str:
    """Generate main dashboard markdown report."""
    data = load_json("dashboard.json")
    if not data:
        return "# Dashboard\n\nNo data available.\n"

    lines = [
        f"# Cloud Dashboard Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"> **Date**: {data.get('date', DATE)}",
        f"",
        f"---",
        f"",
        f"## Status Overview",
        f"",
        f"| Category | Status |",
        f"|----------|--------|",
    ]

    status_emoji = {"ok": "✅", "warning": "⚠️", "critical": "❌"}
    for cat, status in data.get("status", {}).items():
        emoji = status_emoji.get(status, "❓")
        lines.append(f"| {cat.title()} | {emoji} {status} |")

    # Alerts
    alerts = data.get("alerts", [])
    if alerts:
        lines.extend([
            f"",
            f"---",
            f"",
            f"## Alerts ({len(alerts)})",
            f"",
        ])

        critical = [a for a in alerts if a.get("level") == "critical"]
        warning = [a for a in alerts if a.get("level") == "warning"]

        if critical:
            lines.append("### Critical")
            lines.append("")
            for a in critical:
                vm = f" [{a['vm']}]" if a.get("vm") else ""
                lines.append(f"- ❌{vm} {a.get('message')}")
            lines.append("")

        if warning:
            lines.append("### Warning")
            lines.append("")
            for a in warning:
                vm = f" [{a['vm']}]" if a.get("vm") else ""
                lines.append(f"- ⚠️{vm} {a.get('message')}")
            lines.append("")

    # Summary
    summary = data.get("summary", {})
    if summary:
        lines.extend([
            f"---",
            f"",
            f"## Summary",
            f"",
        ])

        # Availability
        avail = summary.get("availability", {})
        if avail:
            lines.extend([
                f"### Availability",
                f"- VMs: {avail.get('vms_reachable', 0)} up / {avail.get('vms_unreachable', 0)} down",
                f"- Endpoints: {avail.get('endpoints_up', 0)} up / {avail.get('endpoints_down', 0)} down",
                f"- SSL: {avail.get('ssl_ok', 0)} ok / {avail.get('ssl_warning', 0)} warning / {avail.get('ssl_critical', 0)} critical",
                f"",
            ])

        # Security
        sec = summary.get("security", {})
        if sec:
            lines.extend([
                f"### Security",
                f"- Total failed SSH: {sec.get('total_failed_ssh', 0)}",
                f"- Unique attackers: {sec.get('unique_attackers', 0)}",
                f"",
            ])

        # Docker
        docker = summary.get("docker", {})
        if docker:
            lines.extend([
                f"### Docker",
                f"- Containers: {docker.get('total_containers', 0)} total",
                f"- Running: {docker.get('running', 0)}",
                f"- Unhealthy: {docker.get('unhealthy', 0)}",
                f"",
            ])

        # Costs
        costs = summary.get("costs", {})
        if costs:
            lines.extend([
                f"### Costs",
                f"- Cloud: {costs.get('cloud_cost', 'N/A')}",
                f"- AI: ${costs.get('estimated_monthly_cost', 0):.2f}/month",
                f"",
            ])

    return "\n".join(lines)


# =============================================================================
# Availability Report
# =============================================================================

def generate_availability_md() -> str:
    """Generate availability markdown report."""
    data = load_json("availability.json")
    if not data or data.get("error"):
        return "# Availability\n\nNo data available.\n"

    lines = [
        f"# Availability Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    current = data.get("current_status", {})

    # VMs
    vms = current.get("vms", [])
    if vms:
        lines.extend([
            f"## Virtual Machines ({len(vms)})",
            f"",
            f"| VM | IP | Ping | SSH | Latency |",
            f"|----|----|------|-----|---------|",
        ])
        for vm in vms:
            ping_emoji = "✅" if vm.get("ping") == "up" else "❌"
            ssh_emoji = "✅" if vm.get("ssh") == "ok" else "❌"
            latency = f"{vm.get('latency_ms', 'N/A')} ms" if vm.get("latency_ms") else "N/A"
            lines.append(f"| {vm.get('name')} | {vm.get('ip', 'N/A')} | {ping_emoji} | {ssh_emoji} | {latency} |")
        lines.append("")

    # Endpoints
    endpoints = current.get("endpoints", [])
    if endpoints:
        lines.extend([
            f"## Endpoints ({len(endpoints)})",
            f"",
            f"| URL | Status | Code | Latency |",
            f"|-----|--------|------|---------|",
        ])
        for ep in endpoints:
            status_emoji = "✅" if ep.get("status") == "up" else "❌"
            latency = f"{ep.get('latency_ms', 'N/A')} ms" if ep.get("latency_ms") else "N/A"
            lines.append(f"| {ep.get('url')} | {status_emoji} | {ep.get('code', 'N/A')} | {latency} |")
        lines.append("")

    # SSL
    ssl = current.get("ssl", [])
    if ssl:
        lines.extend([
            f"## SSL Certificates ({len(ssl)})",
            f"",
            f"| Domain | Status | Days Left | Expires |",
            f"|--------|--------|-----------|---------|",
        ])
        for cert in ssl:
            status = cert.get("status", "unknown")
            emoji = {"ok": "✅", "warning": "⚠️", "critical": "❌"}.get(status, "❓")
            lines.append(f"| {cert.get('domain')} | {emoji} {status} | {cert.get('days_left', 'N/A')} | {cert.get('expires', 'N/A')} |")
        lines.append("")

    return "\n".join(lines)


# =============================================================================
# Security Report
# =============================================================================

def generate_security_md() -> str:
    """Generate security markdown report."""
    data = load_json("security.json")
    if not data or data.get("error"):
        return "# Security\n\nNo data available.\n"

    lines = [
        f"# Security Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    # Summary
    summary = data.get("summary", {})
    lines.extend([
        f"## Summary",
        f"",
        f"- **Total Failed SSH**: {summary.get('total_failed_ssh', 0)}",
        f"- **Unique Attackers**: {summary.get('unique_attackers', 0)}",
        f"",
    ])

    # Per-VM details
    vms = data.get("vms", {})
    if vms:
        lines.extend([
            f"## Per-VM Details",
            f"",
        ])
        for vm, vm_data in vms.items():
            lines.append(f"### {vm}")
            lines.append("")

            # Failed SSH
            failed_ssh = vm_data.get("failed_ssh", [])
            total = vm_data.get("total_failed_attempts", 0)
            if failed_ssh:
                lines.append(f"**Failed SSH** ({total} total)")
                lines.append("")
                lines.append("| IP | Attempts |")
                lines.append("|----|----------|")
                for ip, count in failed_ssh[:10]:
                    lines.append(f"| {ip} | {count} |")
                lines.append("")

            # Open ports
            open_ports = vm_data.get("open_ports", [])
            if open_ports:
                lines.append(f"**Open Ports** ({len(open_ports)})")
                lines.append("")
                lines.append("| Port | Process |")
                lines.append("|------|---------|")
                for port in open_ports[:20]:
                    lines.append(f"| {port.get('port')} | {port.get('process')} |")
                lines.append("")

    # Alerts
    alerts = data.get("alerts", [])
    if alerts:
        lines.extend([
            f"## Alerts ({len(alerts)})",
            f"",
        ])
        for a in alerts:
            level_emoji = {"critical": "❌", "warning": "⚠️"}.get(a.get("level"), "ℹ️")
            vm = f" [{a['vm']}]" if a.get("vm") else ""
            lines.append(f"- {level_emoji}{vm} {a.get('message')}")
        lines.append("")

    return "\n".join(lines)


# =============================================================================
# Performance Report
# =============================================================================

def generate_performance_md() -> str:
    """Generate performance markdown report."""
    data = load_json("performance.json")
    if not data or data.get("error"):
        return "# Performance\n\nNo data available.\n"

    lines = [
        f"# Performance Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    vms = data.get("vms", {})
    for vm, vm_data in vms.items():
        lines.append(f"## {vm}")
        lines.append("")

        # Load
        load = vm_data.get("load_1m")
        if load is not None:
            load_bar = "🟢" if load < 1.0 else "🟡" if load < 2.0 else "🔴"
            lines.append(f"**Load**: {load_bar} {load}")
            lines.append("")

        # Memory
        mem = vm_data.get("memory", {})
        if mem:
            pct = mem.get("percent", 0)
            mem_bar = "🟢" if pct < 70 else "🟡" if pct < 90 else "🔴"
            lines.append(f"**Memory**: {mem_bar} {pct}% ({mem.get('used_mb', 0)} / {mem.get('total_mb', 0)} MB)")
            lines.append("")

        # Disk
        disks = vm_data.get("disk", [])
        if disks:
            lines.append("**Disk**")
            lines.append("")
            lines.append("| Mount | Size | Used | % |")
            lines.append("|-------|------|------|---|")
            for d in disks:
                pct = d.get("percent", 0)
                disk_bar = "🟢" if pct < 70 else "🟡" if pct < 90 else "🔴"
                lines.append(f"| {d.get('mount')} | {d.get('size')} | {d.get('used')} | {disk_bar} {pct}% |")
            lines.append("")

        # Docker
        docker = vm_data.get("docker", [])
        if docker:
            lines.append("**Docker Containers**")
            lines.append("")
            lines.append("| Name | CPU | Memory |")
            lines.append("|------|-----|--------|")
            for c in docker:
                lines.append(f"| {c.get('name')} | {c.get('cpu')} | {c.get('mem')} |")
            lines.append("")

    return "\n".join(lines)


# =============================================================================
# Docker Report
# =============================================================================

def generate_docker_md() -> str:
    """Generate docker markdown report."""
    data = load_json("docker.json")
    if not data or data.get("error"):
        return "# Docker\n\nNo data available.\n"

    lines = [
        f"# Docker Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    # Summary
    summary = data.get("summary", {})
    lines.extend([
        f"## Summary",
        f"",
        f"| Metric | Value |",
        f"|--------|-------|",
        f"| Total | {summary.get('total_containers', 0)} |",
        f"| Running | {summary.get('running', 0)} |",
        f"| Stopped | {summary.get('stopped', 0)} |",
        f"| Unhealthy | {summary.get('unhealthy', 0)} |",
        f"",
    ])

    # Per-VM
    vms = data.get("vms", {})
    for vm, vm_data in vms.items():
        containers = vm_data.get("containers", [])
        lines.append(f"## {vm} ({len(containers)} containers)")
        lines.append("")

        if containers:
            lines.append("| Name | CPU | Memory | Mem% | Net I/O |")
            lines.append("|------|-----|--------|------|---------|")
            for c in containers:
                lines.append(f"| {c.get('name')} | {c.get('cpu')} | {c.get('memory')} | {c.get('mem_percent')} | {c.get('net_io')} |")
            lines.append("")

        errors = vm_data.get("errors", [])
        if errors:
            lines.append("**Recent Errors**")
            lines.append("")
            lines.append("```")
            for err in errors[:10]:
                lines.append(err)
            lines.append("```")
            lines.append("")

    return "\n".join(lines)


# =============================================================================
# Web Report
# =============================================================================

def generate_web_md() -> str:
    """Generate web traffic markdown report."""
    data = load_json("web.json")
    if not data or data.get("error"):
        return "# Web Traffic\n\nNo data available.\n"

    lines = [
        f"# Web Traffic Report",
        f"",
        f"> **Generated**: {data.get('timestamp', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    # Summary
    summary = data.get("summary", {})
    lines.extend([
        f"## Summary",
        f"",
        f"- **Total Requests**: {summary.get('total_requests', 0)}",
        f"- **Total Errors**: {summary.get('total_errors', 0)}",
        f"- **Suspicious Requests**: {summary.get('suspicious_count', 0)}",
        f"",
    ])

    # Per-VM
    vms = data.get("vms", {})
    for vm, vm_data in vms.items():
        lines.append(f"## {vm}")
        lines.append("")

        # Top IPs
        top_ips = vm_data.get("top_ips", [])
        if top_ips:
            lines.append("**Top IPs**")
            lines.append("")
            lines.append("| IP | Requests |")
            lines.append("|----|----------|")
            for ip_data in top_ips[:10]:
                lines.append(f"| {ip_data.get('ip')} | {ip_data.get('count')} |")
            lines.append("")

        # Status codes
        status_codes = vm_data.get("status_codes", {})
        if status_codes:
            lines.append("**Status Codes**")
            lines.append("")
            lines.append("| Code | Count |")
            lines.append("|------|-------|")
            for code, count in sorted(status_codes.items()):
                lines.append(f"| {code} | {count} |")
            lines.append("")

        # Suspicious
        suspicious = vm_data.get("suspicious_requests", [])
        if suspicious:
            lines.append(f"**Suspicious Requests** ({len(suspicious)})")
            lines.append("")
            lines.append("```")
            for req in suspicious[:10]:
                lines.append(req[:100])
            lines.append("```")
            lines.append("")

    return "\n".join(lines)


# =============================================================================
# Costs Report
# =============================================================================

def generate_costs_md() -> str:
    """Generate costs markdown report."""
    data = load_json("costs.json")
    if not data or data.get("error"):
        return "# Costs\n\nNo data available.\n"

    lines = [
        f"# Costs Report",
        f"",
        f"> **Month**: {data.get('month', 'N/A')}",
        f"> **Generated**: {data.get('date', 'N/A')}",
        f"",
        f"---",
        f"",
    ]

    # Cloud costs
    lines.extend([
        f"## Cloud Infrastructure",
        f"",
        f"| Provider | Status | Tier |",
        f"|----------|--------|------|",
    ])

    gcp = data.get("gcp", {})
    if gcp:
        lines.append(f"| GCP | {gcp.get('status', 'N/A')} | {gcp.get('tier', 'N/A')} |")

    oci = data.get("oci", {})
    if oci:
        lines.append(f"| OCI | {oci.get('status', 'N/A')} | {oci.get('tier', 'N/A')} |")

    lines.append("")

    # Claude costs
    claude = data.get("claude", {})
    if claude:
        usage = claude.get("usage", {})
        lines.extend([
            f"## AI / Claude Usage",
            f"",
            f"| Period | Input Tokens | Output Tokens |",
            f"|--------|--------------|---------------|",
            f"| Today | {usage.get('today', {}).get('input', 0):,} | {usage.get('today', {}).get('output', 0):,} |",
            f"| Week | {usage.get('week', {}).get('input', 0):,} | {usage.get('week', {}).get('output', 0):,} |",
            f"| Month | {usage.get('month', {}).get('input', 0):,} | {usage.get('month', {}).get('output', 0):,} |",
            f"",
            f"**Estimated Monthly Cost**: ${usage.get('estimated_cost_usd', 0):.2f}",
            f"",
        ])

    return "\n".join(lines)


# =============================================================================
# Main
# =============================================================================

def convert_all():
    """Generate all markdown reports."""
    MD_DIR.mkdir(parents=True, exist_ok=True)

    generators = {
        "dashboard.md": generate_dashboard_md,
        "availability.md": generate_availability_md,
        "security.md": generate_security_md,
        "performance.md": generate_performance_md,
        "docker.md": generate_docker_md,
        "web.md": generate_web_md,
        "costs.md": generate_costs_md,
    }

    for filename, generator in generators.items():
        print(f"Generating {filename}...")
        content = generator()
        output_file = MD_DIR / filename

        with open(output_file, 'w') as f:
            f.write(content)

        print(f"  Saved: {output_file}")


if __name__ == "__main__":
    convert_all()
