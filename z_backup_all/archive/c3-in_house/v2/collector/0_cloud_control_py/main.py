#!/home/diego/.venv/bin/python
"""
Cloud Control Center - Main Entry Point

Modes:
  - tui      : Interactive terminal UI (default)
  - export   : Export data to files
  - status   : Quick CLI status
  - api      : API client commands
  - help     : Show help

Usage:
  python main.py                    # Run TUI
  python main.py tui                # Run TUI
  python main.py export [format]    # Export (json, js, md, csv, all)
  python main.py status             # Quick status
  python main.py api <endpoint>     # API client
  python main.py help               # Show help

Version: 2.0.0
"""

import sys
from pathlib import Path

# Add app to path
APP_DIR = Path(__file__).parent / "app"
sys.path.insert(0, str(APP_DIR.parent))


def cmd_tui():
    """Run the TUI."""
    from app.tui import run_tui
    run_tui()


def cmd_export(format: str = "all"):
    """Export data to files."""
    from app import exporters

    print(f"Exporting data ({format})...")

    if format == "json":
        path = exporters.export_json()
        print(f"  JSON: {path}")
    elif format == "js":
        path = exporters.export_json_js()
        print(f"  JS: {path}")
    elif format == "md":
        path = exporters.export_markdown()
        print(f"  MD: {path}")
    elif format == "csv":
        files = exporters.export_csv()
        print(f"  CSV: {files['hosts']}")
        print(f"  CSV: {files['containers']}")
    elif format == "all":
        result = exporters.export_all()
        print(f"  JSON: {result['json']}")
        print(f"  JS: {result['js']}")
        print(f"  MD: {result['md']}")
        print(f"  CSV: {result['csv']['hosts']}")
        print(f"  CSV: {result['csv']['containers']}")
    else:
        print(f"Unknown format: {format}")
        print("Available: json, js, md, csv, all")


def cmd_status():
    """Quick CLI status."""
    from app.config_loader import get_hosts, get_containers
    from app.monitors import check_ping, check_ssh, get_ssh_key

    hosts = get_hosts()
    containers = get_containers()

    print("=" * 60)
    print("CLOUD CONTROL CENTER - STATUS")
    print("=" * 60)

    print(f"\nHosts ({len(hosts)}):")
    for host_id, host in hosts.items():
        ping_ok = check_ping(host.ip) if host.ip else False
        status = "✓ ONLINE" if ping_ok else "✗ OFFLINE"
        print(f"  {host.display_name:30} [{host.ip:15}] {status}")

    print(f"\nContainers ({len(containers)}):")
    by_host = {}
    for cont_id, cont in containers.items():
        if cont.host not in by_host:
            by_host[cont.host] = []
        by_host[cont.host].append(cont.name)

    for host_id, cont_names in by_host.items():
        host = hosts.get(host_id)
        print(f"  {host.display_name if host else host_id}:")
        for name in cont_names:
            print(f"    - {name}")

    print("\n" + "=" * 60)


def cmd_api(endpoint: str = None, *args):
    """API client commands."""
    from app.api_client import get_client

    client = get_client()

    if not endpoint:
        print("API Client - Available commands:")
        print("  api infrastructure  - Get infrastructure data")
        print("  api monitor         - Get monitoring data")
        print("  api vms             - List VMs")
        print("  api services        - List services")
        print("  api summary         - Dashboard summary")
        return

    result = None
    if endpoint == "infrastructure":
        result = client.get_infrastructure()
    elif endpoint == "monitor":
        result = client.get_monitor_data()
    elif endpoint == "vms":
        result = client.list_vms()
    elif endpoint == "services":
        result = client.list_services()
    elif endpoint == "summary":
        result = client.get_dashboard_summary()
    else:
        print(f"Unknown endpoint: {endpoint}")
        return

    import json
    print(json.dumps(result, indent=2))


def cmd_help():
    """Show help."""
    print(__doc__)
    print("\nCommands:")
    print("  tui              Run interactive TUI (default)")
    print("  export [format]  Export data (json, js, md, csv, all)")
    print("  status           Quick CLI status")
    print("  api <endpoint>   API client commands")
    print("  help             Show this help")
    print("\nExamples:")
    print("  python main.py")
    print("  python main.py tui")
    print("  python main.py export json")
    print("  python main.py export all")
    print("  python main.py status")
    print("  python main.py api vms")


def main():
    """Main entry point."""
    args = sys.argv[1:]

    if not args or args[0] == "tui":
        cmd_tui()
    elif args[0] == "export":
        format = args[1] if len(args) > 1 else "all"
        cmd_export(format)
    elif args[0] == "status":
        cmd_status()
    elif args[0] == "api":
        endpoint = args[1] if len(args) > 1 else None
        cmd_api(endpoint, *args[2:])
    elif args[0] in ("help", "-h", "--help"):
        cmd_help()
    else:
        print(f"Unknown command: {args[0]}")
        cmd_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
