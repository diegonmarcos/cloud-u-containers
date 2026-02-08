#!/usr/bin/env python3
"""
cloud_json_export.py - Export cloud JSON files to markdown

Usage:
    python cloud_json_export.py           # Export both arch and monitor
    python cloud_json_export.py arch      # Export architecture only
    python cloud_json_export.py monitor   # Export monitor only
    python cloud_json_export.py -h        # Show help
"""

import json
import sys
from pathlib import Path
from datetime import datetime

SCRIPT_DIR = Path(__file__).parent
DATA_DIR = SCRIPT_DIR / "data"
OUTPUT_DIR = SCRIPT_DIR / "dist"
MD_DIR = OUTPUT_DIR / "md"
API_DIR = OUTPUT_DIR / "api"
JINJA2_DIR = OUTPUT_DIR / "jinja2"
TEMPLATES_DIR = SCRIPT_DIR / "templates"

# Input JSON files
ARCH_JSON = DATA_DIR / "cloud_architecture.json"
MONITOR_JSON = DATA_DIR / "cloud_control.json"
ARCH_API_JSON = DATA_DIR / "cloud_architecture_api.json"
CTRL_API_JSON = DATA_DIR / "cloud_control_api.json"

# Output files
ARCH_MD = MD_DIR / "cloud_architecture.md"
MONITOR_MD = MD_DIR / "cloud_control.md"
ARCH_API_MD = MD_DIR / "cloud_architecture_api.md"
CTRL_API_MD = MD_DIR / "cloud_control_api.md"
OPENAPI_ARCH_JSON = API_DIR / "openapi_architecture.json"
OPENAPI_ARCH_YAML = API_DIR / "openapi_architecture.yaml"
OPENAPI_CTRL_JSON = API_DIR / "openapi_control.json"
OPENAPI_CTRL_YAML = API_DIR / "openapi_control.yaml"


def load_json(path: Path) -> dict:
    with open(path, "r") as f:
        return json.load(f)


def fmt(value) -> str:
    """Format value for display, handling None."""
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "Yes" if value else "No"
    return str(value)


def table(headers: list[str], rows: list[list[str]]) -> str:
    """Generate a markdown table."""
    if not rows:
        return "*No data*\n"

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(widths):
                widths[i] = max(widths[i], len(str(cell)))

    lines = []
    lines.append("| " + " | ".join(h.ljust(widths[i]) for i, h in enumerate(headers)) + " |")
    lines.append("| " + " | ".join("-" * widths[i] for i in range(len(headers))) + " |")
    for row in rows:
        lines.append("| " + " | ".join(str(cell).ljust(widths[i]) for i, cell in enumerate(row)) + " |")

    return "\n".join(lines) + "\n"


# =============================================================================
# ARCHITECTURE EXPORT
# =============================================================================

def arch_part1(data: dict) -> str:
    output = []
    output.append("## Part I: Overview\n")
    part1 = data.get("partI_overview", {})

    output.append("### Cloud Providers\n")
    providers = part1.get("providers", {})
    rows = []
    for pid, p in providers.items():
        cli = p.get("cli", {})
        rows.append([p.get("name", pid), p.get("tier", ""), p.get("region", ""),
                     f"[Console]({p.get('consoleUrl', '#')})", f"`{cli.get('name', '')}`"])
    output.append(table(["Provider", "Tier", "Region", "Console", "CLI"], rows))

    output.append("### Active Services Summary\n")
    services = part1.get("activeServicesSummary", [])
    rows = [[s.get("name", ""), s.get("url", ""), s.get("availability", "")] for s in services]
    output.append(table(["Service", "URL", "Availability"], rows))

    proxy = part1.get("proxyAdmin", {})
    if proxy:
        output.append("### Central Proxy\n")
        output.append(f"**Name**: {proxy.get('name', 'N/A')}\n")
        output.append(f"**URL**: {proxy.get('url', 'N/A')}\n")
        output.append(f"**VM**: {proxy.get('vmId', 'N/A')}\n")

    return "\n".join(output)


def arch_part2(data: dict) -> str:
    output = []
    output.append("## Part II: Infrastructure\n")
    part2 = data.get("partII_infrastructure", {})

    output.append("### VM Categories\n")
    cats = part2.get("vmCategories", {})
    rows = [[cid, c.get("name", ""), c.get("description", "")] for cid, c in cats.items()]
    output.append(table(["ID", "Name", "Description"], rows))

    output.append("### Virtual Machines\n")
    vms = part2.get("virtualMachines", {})
    rows = []
    for vmid, vm in vms.items():
        specs = vm.get("specs", {})
        network = vm.get("network", {})
        cost = vm.get("cost", {})
        monthly = cost.get("monthly", 0) if isinstance(cost, dict) else cost
        rows.append([vmid, vm.get("displayName", vm.get("name", "")), vm.get("provider", ""),
                     network.get("publicIp", ""), specs.get("ram", ""), specs.get("storage", ""),
                     vm.get("availability", "24/7"), f"${monthly}/mo"])
    output.append(table(["VM ID", "Name", "Provider", "Public IP", "RAM", "Storage", "Availability", "Cost"], rows))

    output.append("### Service Categories\n")
    scats = part2.get("serviceCategories", {})
    rows = [[cid, c.get("name", ""), c.get("description", "")] for cid, c in scats.items()]
    output.append(table(["ID", "Name", "Description"], rows))

    output.append("### Services Registry\n")
    services = part2.get("services", {})
    rows = []
    for sid, s in services.items():
        urls = s.get("urls", {})
        main_url = list(urls.values())[0] if urls else ""
        rows.append([sid, s.get("displayName", ""), s.get("category", ""), s.get("vmId", ""), main_url])
    output.append(table(["Service ID", "Name", "Category", "VM", "URL"], rows))

    output.append("### Docker Networks\n")
    networks = part2.get("dockerNetworks", {})
    rows = [[nid, n.get("vmId", ""), n.get("subnet", ""), n.get("purpose", "")] for nid, n in networks.items()]
    output.append(table(["Network", "VM", "Subnet", "Purpose"], rows))

    output.append("### VM Ports\n")
    rows = []
    for vmid, vm in vms.items():
        ports = vm.get("ports", {})
        external = ", ".join(map(str, ports.get("external", []))) or "-"
        internal = ", ".join(map(str, ports.get("internal", []))) or "-"
        rows.append([vmid, external, internal])
    output.append(table(["VM", "External Ports", "Internal Ports"], rows))

    return "\n".join(output)


def arch_part3(data: dict) -> str:
    output = []
    output.append("## Part III: Security\n")
    part3 = data.get("partIII_security", {})

    domains = part3.get("domains", {})
    output.append("### Domain Configuration\n")
    output.append(f"**Primary Domain**: {domains.get('primary', 'N/A')}\n")
    output.append(f"**Registrar**: {domains.get('registrar', 'N/A')}\n")
    ns = domains.get("nameservers", [])
    if ns:
        output.append(f"**Nameservers**: {', '.join(ns)}\n")

    output.append("\n### Subdomain Routing\n")
    subdomains = domains.get("subdomains", {})
    rows = []
    for subdomain, info in subdomains.items():
        rows.append([subdomain, info.get("service", ""), info.get("vmId", info.get("hosting", "")),
                     info.get("proxyVia", "direct"), info.get("auth", "none"),
                     "Yes" if info.get("ssl", False) else "No"])
    output.append(table(["Domain", "Service", "VM/Host", "Proxy Via", "Auth", "SSL"], rows))

    output.append("### Firewall Rules\n")
    rules = part3.get("firewallRules", {})
    rows = []
    for vmid, rule_list in rules.items():
        for r in rule_list:
            rows.append([vmid, r.get("port", ""), r.get("protocol", ""), r.get("service", "")])
    output.append(table(["VM", "Port", "Protocol", "Service"], rows))

    output.append("### Authentication Methods\n")
    auth = part3.get("authentication", {})
    methods = auth.get("methods", {})
    rows = []
    for method, info in methods.items():
        services = ", ".join(info.get("services", []))
        rows.append([method, info.get("description", ""), services])
    output.append(table(["Method", "Description", "Services"], rows))

    authelia = auth.get("authelia", {})
    if authelia:
        output.append("\n### Authelia OIDC Endpoints\n")
        output.append(f"**Issuer**: {authelia.get('issuer', 'N/A')}\n")
        for name, url in authelia.get("endpoints", {}).items():
            output.append(f"- **{name}**: `{url}`\n")

    return "\n".join(output)


def arch_part4(data: dict) -> str:
    output = []
    output.append("## Part IV: Data\n")
    part4 = data.get("partIV_data", {})

    output.append("### Databases\n")
    dbs = part4.get("databases", {})
    rows = [[dbid, db.get("technology", ""), db.get("service", ""), db.get("vmId", ""), db.get("storage", "")]
            for dbid, db in dbs.items()]
    output.append(table(["Database", "Technology", "Service", "VM", "Storage"], rows))

    output.append("### Object Storage\n")
    storage = part4.get("objectStorage", {})
    rows = []
    for sid, s in storage.items():
        for bid, b in s.get("buckets", {}).items():
            rows.append([bid, s.get("provider", ""), b.get("size", ""), b.get("contents", "")])
    output.append(table(["Bucket", "Provider", "Size", "Contents"], rows))

    output.append("### Rclone Remotes\n")
    remotes = part4.get("rcloneRemotes", {})
    rows = [[rid, r.get("type", ""), r.get("purpose", "")] for rid, r in remotes.items()]
    output.append(table(["Remote", "Type", "Purpose"], rows))

    return "\n".join(output)


def arch_part5(data: dict) -> str:
    output = []
    output.append("## Part V: Operations\n")
    part5 = data.get("partV_operations", {})

    output.append("### SSH Commands\n")
    ssh = part5.get("sshCommands", {})
    rows = [[vmid, f"`{cmd}`"] for vmid, cmd in ssh.items()]
    output.append(table(["VM", "SSH Command"], rows))

    output.append("### Docker Commands\n")
    docker = part5.get("dockerCommands", {})
    rows = [[name, f"`{cmd}`"] for name, cmd in docker.items()]
    output.append(table(["Action", "Command"], rows))

    output.append("### Monitoring Commands\n")
    monitoring = part5.get("monitoringCommands", {})
    rows = [[name, f"`{cmd}`"] for name, cmd in monitoring.items()]
    output.append(table(["Action", "Command"], rows))

    output.append("### Status Legend\n")
    legend = part5.get("statusLegend", {})
    rows = [[status, info.get("color", ""), info.get("description", "")] for status, info in legend.items()]
    output.append(table(["Status", "Color", "Description"], rows))

    return "\n".join(output)


def arch_part6(data: dict) -> str:
    output = []
    output.append("## Part VI: Reference\n")
    part6 = data.get("partVI_reference", {})

    output.append("### Monthly Costs Summary\n")
    costs = part6.get("costs", {})
    total = costs.get("total", {})
    output.append(f"**Infrastructure**: ${total.get('infra', 0)}/mo\n")
    output.append(f"**AI Services**: ${total.get('ai', 0)}/mo\n")
    output.append(f"**Total**: ${total.get('total', 0)}/mo {total.get('currency', 'USD')}\n")

    output.append("\n### Infrastructure Costs\n")
    infra = costs.get("infra", {})
    rows = []
    for provider, info in infra.items():
        tier = info.get("tier", "")
        monthly = info.get("monthly", 0)
        paid = info.get("paidVms", {})
        if paid:
            for vm, cost in paid.items():
                rows.append([provider, vm, tier, f"${cost}/mo"])
        else:
            rows.append([provider, "-", tier, f"${monthly}/mo"])
    output.append(table(["Provider", "VM", "Tier", "Cost"], rows))

    output.append("### Wake-on-Demand Configuration\n")
    wod = part6.get("wakeOnDemand", {})
    output.append(f"**Enabled**: {'Yes' if wod.get('enabled', False) else 'No'}\n")
    output.append(f"**Target VM**: {wod.get('targetVm', 'N/A')}\n")
    output.append(f"**Health Check**: {wod.get('healthCheckUrl', 'N/A')}\n")
    output.append(f"**Idle Timeout**: {wod.get('idleTimeoutSeconds', 0)} seconds\n")
    services = wod.get("services", [])
    if services:
        output.append(f"**Services**: {', '.join(services)}\n")

    output.append("\n### Port Mapping\n")
    ports = part6.get("portMapping", [])
    rows = [[p.get("service", ""), str(p.get("internal", "")), str(p.get("external", "")), p.get("notes", "")]
            for p in ports]
    output.append(table(["Service", "Internal Port", "External Port", "Notes"], rows))

    output.append("### Docker Images\n")
    images = part6.get("dockerImages", [])
    rows = [[img.get("service", ""), img.get("image", ""), img.get("version", "")] for img in images]
    output.append(table(["Service", "Image", "Version"], rows))

    return "\n".join(output)


def export_architecture() -> int:
    """Export architecture JSON to markdown."""
    print(f"Loading: {ARCH_JSON}")
    data = load_json(ARCH_JSON)

    version = data.get("version", "0.0.0")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")

    header = f"""# Cloud Infrastructure Tables

> **Version**: {version}
> **Generated**: {timestamp}
> **Source**: `cloud_architecture.json`

This document is auto-generated from `cloud_architecture.json` using `cloud_json_export.py`.
Do not edit manually - changes will be overwritten.

---

"""

    sections = [header, arch_part1(data), arch_part2(data), arch_part3(data),
                arch_part4(data), arch_part5(data), arch_part6(data)]
    markdown = "\n".join(sections)

    print(f"Writing: {ARCH_MD}")
    with open(ARCH_MD, "w") as f:
        f.write(markdown)

    print(f"  -> {len(markdown)} chars, 21 tables")
    return len(markdown)


# =============================================================================
# CLOUD CONTROL EXPORT (topology, cost, monitor)
# =============================================================================

def export_topology(data: dict) -> str:
    """Export topology section to markdown."""
    output = []
    topology = data.get("topology", {})
    output.append("# Topology\n")
    output.append(f"*{topology.get('_description', '')}*\n")

    # Virtual Machines table
    output.append("## Virtual Machines\n")
    vms = topology.get("virtualMachines", {})
    if vms.get("data"):
        rows = [[vm.get("host"), vm.get("vmId"), vm.get("ip"), vm.get("dockerNetwork"), vm.get("os")]
                for vm in vms.get("data", [])]
        output.append(table(["Host", "VM ID", "IP", "Docker Network", "OS"], rows))

    # Services by VM
    output.append("## Services by VM\n")
    services_by_vm = topology.get("servicesByVm", {})
    for vmid, services in services_by_vm.items():
        if vmid.startswith("_"):
            continue
        output.append(f"### {vmid}\n")
        rows = [[s.get("service"), s.get("description"), s.get("ports"), s.get("status")] for s in services]
        output.append(table(["Service", "Description", "Ports", "Status"], rows))

    # Service Types
    output.append("## Service Types\n")
    service_types = topology.get("serviceTypes", {})
    for type_id, type_data in service_types.items():
        if type_id.startswith("_"):
            continue
        output.append(f"### {type_data.get('name', type_id)}\n")
        output.append(f"*{type_data.get('description', '')}*\n")
        services = type_data.get("services", [])
        if services:
            rows = [[s.get("service"), s.get("vm"), s.get("description")] for s in services]
            output.append(table(["Service", "VM", "Description"], rows))
        else:
            output.append("*No services*\n")

    # Database Allocations
    output.append("## Database Allocations\n")
    db_alloc = topology.get("databaseAllocations", {})
    for vmid, vm_data in db_alloc.items():
        if vmid.startswith("_"):
            continue
        output.append(f"### {vmid} (Boot: {vm_data.get('bootSize', 'N/A')})\n")
        dbs = vm_data.get("databases", [])
        if dbs:
            rows = [[d.get("name"), d.get("type"), d.get("service"), d.get("size"), f"`{d.get('path')}`"] for d in dbs]
            output.append(table(["Database", "Type", "Service", "Size", "Path"], rows))

    # Containers
    output.append("## Containers\n")
    containers = topology.get("containers", {})
    for vmid, vm_data in containers.items():
        if vmid.startswith("_"):
            continue
        count = vm_data.get("count", 0)
        output.append(f"### {vmid} ({count} containers)\n")
        items = vm_data.get("items", [])
        if items:
            rows = [[c.get("name"), c.get("image"), c.get("ports"), c.get("network"), c.get("status")] for c in items]
            output.append(table(["Container", "Image", "Ports", "Network", "Status"], rows))

    # Docker Networks
    output.append("## Docker Networks\n")
    networks = topology.get("dockerNetworks", {})
    if networks.get("data"):
        rows = [[n.get("network"), n.get("vm"), n.get("subnet"), n.get("purpose")] for n in networks.get("data", [])]
        output.append(table(["Network", "VM", "Subnet", "Purpose"], rows))

    # Summaries
    output.append("## Summaries\n")
    summaries = topology.get("summaries", {})
    for summary_name, summary_data in summaries.items():
        output.append(f"### {summary_name.title()}\n")
        rows = [[d.get("metric"), d.get("value")] for d in summary_data.get("data", [])]
        output.append(table(["Metric", "Value"], rows))

    return "\n".join(output)


def export_cost(data: dict) -> str:
    """Export cost section to markdown."""
    output = []
    cost = data.get("cost", {})
    output.append("# Cost\n")
    output.append(f"*{cost.get('_description', '')}*\n")

    # Summary
    output.append("## Cost Summary\n")
    summary = cost.get("summary", {})
    if summary.get("data"):
        rows = [[d.get("metric"), d.get("value")] for d in summary.get("data", [])]
        output.append(table(["Metric", "Value"], rows))

    # Provider Distribution
    output.append("## Provider Distribution\n")
    dist = cost.get("providerDistribution", {})
    if dist.get("data"):
        rows = [[d.get("provider"), d.get("cost"), d.get("percentage")] for d in dist.get("data", [])]
        output.append(table(["Provider", "Cost", "Percentage"], rows))

    # Infrastructure Breakdown
    output.append("## Infrastructure Breakdown\n")
    breakdown = cost.get("infraBreakdown", {})
    if breakdown.get("data"):
        rows = [[d.get("provider"), d.get("vm"), d.get("tier"), d.get("cost")] for d in breakdown.get("data", [])]
        output.append(table(["Provider", "VM", "Tier", "Cost"], rows))

    # Resource Usage by VM
    output.append("## Resource Usage by VM\n")
    usage = cost.get("resourceUsageByVm", {})
    for vmid, vm_data in usage.items():
        if vmid.startswith("_"):
            continue
        output.append(f"### {vm_data.get('displayName', vmid)}\n")
        output.append(f"*Specs: {vm_data.get('specs', 'N/A')}*\n")
        total = vm_data.get("vmTotal", {})
        output.append(f"**Total**: CPU {total.get('cpu', '-')}%, RAM {total.get('ram', '-')}%, Storage {total.get('storage', '-')}%\n")
        services = vm_data.get("services", [])
        if services:
            rows = [[s.get("name"), f"{s.get('cpu')}%", f"{s.get('ram')}%", f"{s.get('storage')}%"] for s in services]
            output.append(table(["Service", "CPU", "RAM", "Storage"], rows))

    # Free Tier Utilization
    output.append("## Free Tier Utilization\n")
    free_tier = cost.get("freeTierUtilization", {})
    for provider, tier_data in free_tier.items():
        if provider.startswith("_"):
            continue
        output.append(f"### {tier_data.get('name', provider)} ({tier_data.get('tier', '')})\n")
        resources = tier_data.get("resources", [])
        if resources:
            rows = [[r.get("name"), f"{r.get('usage')}%", r.get("limit"), r.get("notes")] for r in resources]
            output.append(table(["Resource", "Usage", "Limit", "Notes"], rows))

    # Market Comparison
    output.append("## Market Comparison\n")
    comparison = cost.get("marketComparison", {})
    if comparison.get("data"):
        rows = [[d.get("provider"), d.get("cost"), d.get("specs")] for d in comparison.get("data", [])]
        output.append(table(["Provider", "Cost", "Equivalent Specs"], rows))

    return "\n".join(output)


def export_monitor_section(data: dict) -> str:
    """Export monitor section to markdown."""
    output = []
    monitor = data.get("monitor", {})
    output.append("# Monitor\n")
    output.append(f"*{monitor.get('_description', '')}*\n")

    # VM Overview
    output.append("## VM Overview\n")
    vm_overview = monitor.get("vmOverview", {})
    if vm_overview.get("data"):
        rows = [[d.get("vm"), d.get("cpu"), d.get("ram"), d.get("storage"), d.get("vram"), d.get("status")]
                for d in vm_overview.get("data", [])]
        output.append(table(["VM", "CPU", "RAM", "Storage", "VRAM", "Status"], rows))

    # Service Breakdown by VM
    output.append("## Service Breakdown by VM\n")
    breakdown = monitor.get("serviceBreakdownByVm", {})
    for vmid, vm_data in breakdown.items():
        if vmid.startswith("_"):
            continue
        output.append(f"### {vm_data.get('displayName', vmid)}\n")
        output.append(f"*Specs: {vm_data.get('specs', 'N/A')}*\n")
        total = vm_data.get("vmTotal", {})
        output.append(f"**Total**: CPU {total.get('cpu', '-')}, RAM {total.get('ram', '-')}, Storage {total.get('storage', '-')}\n")
        services = vm_data.get("services", [])
        if services:
            rows = [[s.get("name"), s.get("cpu"), s.get("ram"), s.get("storage")] for s in services]
            output.append(table(["Service", "CPU", "RAM", "Storage"], rows))

    # Audit Analytics
    output.append("## Audit Analytics\n")
    audit = monitor.get("auditAnalytics", {})
    if audit.get("data"):
        rows = [[d.get("service"), d.get("url"), d.get("status")] for d in audit.get("data", [])]
        output.append(table(["Service", "URL", "Status"], rows))

    # Audit Logs Metrics
    output.append("## Audit Logs Metrics\n")
    metrics = monitor.get("auditLogsMetrics", {})
    if metrics.get("data"):
        rows = [[d.get("metric"), d.get("value")] for d in metrics.get("data", [])]
        output.append(table(["Metric", "Value"], rows))

    # Event Type Distribution
    output.append("## Event Type Distribution\n")
    events = monitor.get("eventTypeDistribution", {})
    if events.get("data"):
        rows = [[d.get("type"), d.get("percentage")] for d in events.get("data", [])]
        output.append(table(["Type", "Percentage"], rows))

    # Status Breakdown
    output.append("## Status Breakdown\n")
    status = monitor.get("statusBreakdown", {})
    if status.get("data"):
        rows = [[d.get("status"), d.get("count"), d.get("percentage")] for d in status.get("data", [])]
        output.append(table(["Status", "Count", "Percentage"], rows))

    # Recent Audit Events
    output.append("## Recent Audit Events\n")
    events = monitor.get("recentAuditEvents", {})
    if events.get("data"):
        rows = [[d.get("timestamp"), d.get("event"), d.get("source"), d.get("userIp"), d.get("status")]
                for d in events.get("data", [])]
        output.append(table(["Timestamp", "Event", "Source", "User/IP", "Status"], rows))

    # Orchestrate (Dockge)
    output.append("## Container Orchestration (Dockge)\n")
    orch = monitor.get("orchestrate", {})
    if orch.get("data"):
        rows = [[d.get("vm"), d.get("ip"), d.get("description"), d.get("dockgeUrl")] for d in orch.get("data", [])]
        output.append(table(["VM", "IP", "Description", "Dockge URL"], rows))

    # SSH Commands
    output.append("## SSH Commands\n")
    ssh = monitor.get("sshCommands", {})
    if ssh.get("data"):
        rows = [[d.get("vm"), f"`{d.get('command')}`"] for d in ssh.get("data", [])]
        output.append(table(["VM", "Command"], rows))

    # Cloud Consoles
    output.append("## Cloud Consoles\n")
    consoles = monitor.get("cloudConsoles", {})
    if consoles.get("data"):
        rows = [[d.get("provider"), d.get("url")] for d in consoles.get("data", [])]
        output.append(table(["Provider", "Console URL"], rows))

    # Summary
    output.append("## Monitor Summary\n")
    summary = monitor.get("summary", {})
    rows = [
        ["Total VMs", fmt(summary.get("totalVMs"))],
        ["VMs Online", fmt(summary.get("vmsOnline"))],
        ["Total Endpoints", fmt(summary.get("totalEndpoints"))],
        ["Endpoints Healthy", fmt(summary.get("endpointsHealthy"))],
        ["Total Containers", fmt(summary.get("totalContainers"))],
        ["Containers Running", fmt(summary.get("containersRunning"))],
        ["Last Full Check", fmt(summary.get("lastFullCheck"))],
    ]
    output.append(table(["Metric", "Value"], rows))

    # Alerts
    output.append("## Alerts\n")
    alerts = monitor.get("alerts", [])
    if alerts:
        rows = [[fmt(a.get("timestamp")), fmt(a.get("severity")), fmt(a.get("source")), fmt(a.get("message"))]
                for a in alerts]
        output.append(table(["Timestamp", "Severity", "Source", "Message"], rows))
    else:
        output.append("*No active alerts*\n")

    return "\n".join(output)


def export_monitor() -> int:
    """Export cloud_control.json to three markdown files: topology, cost, monitor."""
    print(f"Loading: {MONITOR_JSON}")
    data = load_json(MONITOR_JSON)

    version = data.get("version", "0.0.0")
    last_updated = data.get("lastUpdated") or "Never"
    updated_by = data.get("updatedBy") or "N/A"
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")

    def make_header(title: str, source_section: str) -> str:
        return f"""# {title}

> **Version**: {version}
> **Generated**: {timestamp}
> **Last Data Update**: {last_updated}
> **Updated By**: {updated_by}
> **Source**: `cloud_control.json` -> `{source_section}`

This document is auto-generated from `cloud_control.json` using `cloud_json_export.py`.
Do not edit manually - changes will be overwritten.

---

"""

    total_chars = 0
    total_tables = 0

    # Export Topology
    topology_md = OUTPUT_DIR / "cloud_control_topology.md"
    topology_content = make_header("Cloud Control - Topology", "topology") + export_topology(data)
    print(f"Writing: {topology_md}")
    with open(topology_md, "w") as f:
        f.write(topology_content)
    print(f"  -> {len(topology_content)} chars")
    total_chars += len(topology_content)

    # Export Cost
    cost_md = OUTPUT_DIR / "cloud_control_cost.md"
    cost_content = make_header("Cloud Control - Cost", "cost") + export_cost(data)
    print(f"Writing: {cost_md}")
    with open(cost_md, "w") as f:
        f.write(cost_content)
    print(f"  -> {len(cost_content)} chars")
    total_chars += len(cost_content)

    # Export Monitor
    monitor_md = OUTPUT_DIR / "cloud_control_monitor.md"
    monitor_content = make_header("Cloud Control - Monitor", "monitor") + export_monitor_section(data)
    print(f"Writing: {monitor_md}")
    with open(monitor_md, "w") as f:
        f.write(monitor_content)
    print(f"  -> {len(monitor_content)} chars")
    total_chars += len(monitor_content)

    print(f"\nTotal: {total_chars} chars across 3 files")
    return total_chars


# =============================================================================
# API EXPORT
# =============================================================================

def api_overview(data: dict) -> str:
    output = []
    output.append("## API Overview\n")

    output.append(f"**Title**: {data.get('title', 'N/A')}\n")
    output.append(f"**Version**: {data.get('version', 'N/A')}\n")
    output.append(f"**Description**: {data.get('description', 'N/A')}\n")

    output.append("\n### Servers\n")
    servers = data.get("server", {})
    rows = [[name, s.get("baseUrl", ""), s.get("description", "")] for name, s in servers.items()]
    output.append(table(["Environment", "Base URL", "Description"], rows))

    output.append("### Authentication\n")
    auth = data.get("auth", {})
    output.append(f"**Type**: {auth.get('type', 'N/A')}\n")
    output.append(f"**Provider**: {auth.get('provider', 'N/A')}\n")
    output.append(f"**Token Endpoint**: `{auth.get('tokenEndpoint', 'N/A')}`\n")

    output.append("\n### Auth Scopes\n")
    scopes = auth.get("scopes", {})
    rows = [[scope, desc] for scope, desc in scopes.items()]
    output.append(table(["Scope", "Description"], rows))

    return "\n".join(output)


def api_endpoints_summary(data: dict) -> str:
    output = []
    output.append("## Endpoints Summary\n")

    endpoints = data.get("endpoints", {})
    rows = []
    for category, category_endpoints in endpoints.items():
        desc = category_endpoints.get("_description", "")
        count = len([k for k in category_endpoints.keys() if not k.startswith("_")])
        rows.append([category, desc, str(count)])
    output.append(table(["Category", "Description", "Endpoints"], rows))

    # Index summary
    index = data.get("_index", {})
    output.append(f"\n**Total Endpoints**: {index.get('endpointCount', 'N/A')}\n")

    return "\n".join(output)


def api_endpoints_detail(data: dict) -> str:
    output = []
    output.append("## Endpoints Detail\n")

    endpoints = data.get("endpoints", {})

    for category, category_endpoints in endpoints.items():
        desc = category_endpoints.get("_description", "")
        source = category_endpoints.get("_source", "")

        output.append(f"### {category.upper()}\n")
        if desc:
            output.append(f"*{desc}*\n")
        if source:
            output.append(f"**Source**: `{source}`\n")
        output.append("")

        rows = []
        for ep_name, ep in category_endpoints.items():
            if ep_name.startswith("_"):
                continue
            method = ep.get("method", "GET")
            path = ep.get("path", "")
            auth = ep.get("auth", "read")
            ep_desc = ep.get("description", "")
            rows.append([f"`{method}`", f"`{path}`", auth, ep_desc])

        if rows:
            output.append(table(["Method", "Path", "Auth", "Description"], rows))

    return "\n".join(output)


def api_endpoints_curl(data: dict) -> str:
    output = []
    output.append("## Curl Examples\n")

    endpoints = data.get("endpoints", {})

    for category, category_endpoints in endpoints.items():
        has_curl = False
        curl_rows = []

        for ep_name, ep in category_endpoints.items():
            if ep_name.startswith("_"):
                continue
            curl = ep.get("curl")
            if curl:
                has_curl = True
                curl_rows.append([ep_name, f"`{curl}`"])

        if has_curl:
            output.append(f"### {category}\n")
            output.append(table(["Endpoint", "Curl Command"], curl_rows))

    return "\n".join(output)


def api_schemas(data: dict) -> str:
    output = []
    output.append("## Schemas\n")

    schemas = data.get("schemas", {})

    for schema_name, schema in schemas.items():
        output.append(f"### {schema_name}\n")

        props = schema.get("properties", {})
        required = schema.get("required", [])

        rows = []
        for prop_name, prop in props.items():
            prop_type = prop.get("type", "any")
            if "enum" in prop:
                prop_type = f"enum: {', '.join(prop['enum'])}"
            elif "$ref" in prop:
                prop_type = f"ref: {prop['$ref']}"
            is_required = "Yes" if prop_name in required else "No"
            prop_desc = prop.get("description", "")
            rows.append([prop_name, prop_type, is_required, prop_desc])

        output.append(table(["Property", "Type", "Required", "Description"], rows))

    return "\n".join(output)


def api_errors(data: dict) -> str:
    output = []
    output.append("## Error Codes\n")

    errors = data.get("errors", {})
    rows = [[code, e.get("code", ""), e.get("message", "")] for code, e in errors.items()]
    output.append(table(["HTTP Code", "Error Code", "Message"], rows))

    output.append("### Rate Limits\n")
    limits = data.get("rateLimits", {})
    rows = [[name, str(l.get("requests", "")), l.get("window", "")] for name, l in limits.items()]
    output.append(table(["Category", "Requests", "Window"], rows))

    return "\n".join(output)


def api_data_sources(data: dict) -> str:
    output = []
    output.append("## Data Sources Mapping\n")

    index = data.get("_index", {})
    sources = index.get("dataSources", {})

    for source, endpoints in sources.items():
        output.append(f"### {source}\n")
        if isinstance(endpoints, list):
            for ep in endpoints:
                output.append(f"- `{ep}`\n")
        output.append("")

    return "\n".join(output)


# =============================================================================
# OPENAPI EXPORT
# =============================================================================

def convert_to_openapi(data: dict) -> dict:
    """Convert cloud_api.json to OpenAPI 3.0 format."""

    # Build servers
    servers = []
    for env, info in data.get("server", {}).items():
        servers.append({
            "url": info.get("baseUrl", ""),
            "description": info.get("description", "")
        })

    # Build security schemes
    auth = data.get("auth", {})
    security_schemes = {
        "bearerAuth": {
            "type": "http",
            "scheme": "bearer",
            "bearerFormat": "JWT",
            "description": f"Authelia OIDC token from {auth.get('tokenEndpoint', '')}"
        }
    }

    # Build paths from endpoints
    paths = {}
    tags = []

    endpoints = data.get("endpoints", {})
    for category, category_endpoints in endpoints.items():
        desc = category_endpoints.get("_description", "")
        tags.append({"name": category, "description": desc})

        for ep_name, ep in category_endpoints.items():
            if ep_name.startswith("_"):
                continue

            path = ep.get("path", "")
            method = ep.get("method", "GET").lower()
            auth_level = ep.get("auth", "read")

            # Build operation
            operation = {
                "tags": [category],
                "summary": ep.get("description", ""),
                "operationId": f"{category}_{ep_name}",
                "responses": {
                    "200": {
                        "description": "Successful response",
                        "content": {
                            "application/json": {
                                "schema": {"type": "object"}
                            }
                        }
                    }
                }
            }

            # Add security if not 'none'
            if auth_level != "none":
                operation["security"] = [{"bearerAuth": [auth_level]}]

            # Add parameters from path
            if "{" in path:
                operation["parameters"] = []
                import re
                params = re.findall(r'\{(\w+)\}', path)
                for param in params:
                    param_info = ep.get("params", {}).get(param, {})
                    operation["parameters"].append({
                        "name": param,
                        "in": "path",
                        "required": True,
                        "schema": {"type": param_info.get("type", "string")},
                        "description": param_info.get("description", "")
                    })

            # Add query parameters
            query = ep.get("query", {})
            if query:
                if "parameters" not in operation:
                    operation["parameters"] = []
                for q_name, q_info in query.items():
                    operation["parameters"].append({
                        "name": q_name,
                        "in": "query",
                        "required": False,
                        "schema": {"type": q_info.get("type", "string")},
                        "description": q_info.get("description", "")
                    })

            # Add to paths
            if path not in paths:
                paths[path] = {}
            paths[path][method] = operation

    # Build components/schemas
    schemas = {}
    for schema_name, schema in data.get("schemas", {}).items():
        schemas[schema_name] = schema

    # Build OpenAPI document
    openapi = {
        "openapi": "3.0.3",
        "info": {
            "title": data.get("title", "Cloud Infrastructure API"),
            "description": data.get("description", ""),
            "version": data.get("version", "1.0.0"),
            "contact": {
                "name": "Diego Nepomuceno Marcos",
                "url": "https://diegonmarcos.com"
            }
        },
        "servers": servers,
        "tags": tags,
        "paths": paths,
        "components": {
            "securitySchemes": security_schemes,
            "schemas": schemas
        }
    }

    return openapi


def _export_openapi_single(api_json: Path, openapi_json: Path, openapi_yaml: Path) -> int:
    """Export a single API JSON to OpenAPI 3.0 format."""
    print(f"Loading: {api_json}")
    data = load_json(api_json)

    openapi = convert_to_openapi(data)

    # Write JSON
    print(f"Writing: {openapi_json}")
    with open(openapi_json, "w") as f:
        json.dump(openapi, f, indent=2)

    # Write YAML
    try:
        import yaml
        print(f"Writing: {openapi_yaml}")
        with open(openapi_yaml, "w") as f:
            yaml.dump(openapi, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    except ImportError:
        print("  (skipping YAML - pyyaml not installed)")

    endpoint_count = len([p for paths in openapi["paths"].values() for p in paths])
    print(f"  -> {endpoint_count} endpoints in OpenAPI format")

    return len(json.dumps(openapi))


def export_openapi() -> int:
    """Export both API JSONs to OpenAPI 3.0 format."""
    total = 0

    # Architecture API
    print("=== Architecture API ===")
    total += _export_openapi_single(ARCH_API_JSON, OPENAPI_ARCH_JSON, OPENAPI_ARCH_YAML)
    print()

    # Control API
    print("=== Control API ===")
    total += _export_openapi_single(CTRL_API_JSON, OPENAPI_CTRL_JSON, OPENAPI_CTRL_YAML)

    return total


def _export_api_single(api_json: Path, api_md: Path, title: str) -> int:
    """Export a single API JSON to markdown."""
    print(f"Loading: {api_json}")
    data = load_json(api_json)

    version = data.get("version", "0.0.0")
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")

    header = f"""# {title}

> **Version**: {version}
> **Generated**: {timestamp}
> **Source**: `{api_json.name}`

This document is auto-generated from `{api_json.name}` using `cloud_json_md.py`.
Do not edit manually - changes will be overwritten.

---

"""

    sections = [header, api_overview(data), api_endpoints_summary(data),
                api_endpoints_detail(data), api_endpoints_curl(data),
                api_schemas(data), api_errors(data), api_data_sources(data)]
    markdown = "\n".join(sections)

    print(f"Writing: {api_md}")
    with open(api_md, "w") as f:
        f.write(markdown)

    endpoint_count = data.get("_index", {}).get("endpointCount", 0)
    print(f"  -> {len(markdown)} chars, {endpoint_count} endpoints documented")
    return len(markdown)


def export_api() -> int:
    """Export both API JSONs to markdown."""
    total = 0

    # Architecture API
    print("=== Architecture API ===")
    total += _export_api_single(ARCH_API_JSON, ARCH_API_MD, "Cloud Architecture API Reference")
    print()

    # Control API
    print("=== Control API ===")
    total += _export_api_single(CTRL_API_JSON, CTRL_API_MD, "Cloud Control API Reference")

    return total


# =============================================================================
# MAIN
# =============================================================================

def show_help():
    help_text = """
cloud_json_export.py - Export cloud JSON files to markdown and OpenAPI

USAGE:
    python cloud_json_export.py              Export all (architecture, monitor, api, openapi)
    python cloud_json_export.py arch         Export architecture data only
    python cloud_json_export.py monitor      Export monitor data only
    python cloud_json_export.py api          Export API reference (markdown) for both APIs
    python cloud_json_export.py openapi      Export OpenAPI 3.0 spec (JSON/YAML) for both APIs
    python cloud_json_export.py -h, --help   Show this help

FILES:
    Input (Data):
        cloud_architecture.json        Static infrastructure configuration
        cloud_control.json             Dynamic runtime monitoring data

    Input (API Specs):
        cloud_architecture_api.json    Architecture API endpoints (static data)
        cloud_control_api.json         Control API endpoints (runtime data)

    Output (Markdown):
        cloud_architecture.md          21 tables (Part I-VI)
        cloud_control.md               10 tables (Summary, VMs, Endpoints, Containers, Alerts)
        cloud_architecture_api.md      Architecture API reference
        cloud_control_api.md           Control API reference

    Output (OpenAPI):
        openapi_architecture.json/yaml OpenAPI 3.0 spec for Architecture API
        openapi_control.json/yaml      OpenAPI 3.0 spec for Control API

EXAMPLES:
    python cloud_json_export.py              # Export all
    python cloud_json_export.py arch         # Only architecture data
    python cloud_json_export.py monitor      # Only monitor data
    python cloud_json_export.py api          # Both API markdown files
    python cloud_json_export.py openapi      # Both OpenAPI specs
"""
    print(help_text)


def main():
    args = sys.argv[1:]

    # Ensure output directory exists
    OUTPUT_DIR.mkdir(exist_ok=True)
    print(f"Output: {OUTPUT_DIR}\n")

    if not args:
        # No args: export all
        print("Exporting all...\n")
        export_architecture()
        print()
        export_monitor()
        print()
        export_api()
        print()
        export_openapi()
        print("\nDone!")
        return

    cmd = args[0].lower()

    if cmd in ["-h", "--help", "help"]:
        show_help()
    elif cmd == "arch":
        export_architecture()
        print("\nDone!")
    elif cmd == "monitor":
        export_monitor()
        print("\nDone!")
    elif cmd == "api":
        export_api()
        print("\nDone!")
    elif cmd == "openapi":
        export_openapi()
        print("\nDone!")
    else:
        print(f"Unknown command: {cmd}")
        print("Use -h for help")
        sys.exit(1)


if __name__ == "__main__":
    main()
