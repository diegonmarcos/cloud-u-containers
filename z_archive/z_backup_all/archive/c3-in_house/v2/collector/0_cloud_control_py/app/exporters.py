"""
Data exporters for Cloud Control Center
"""

import json
import os
from datetime import datetime
from typing import Dict, Any

from .config_loader import get_export_dir, get_hosts, get_containers
from .models import CloudData


def _get_timestamp() -> str:
    return datetime.now().strftime('%Y%m%d_%H%M%S')


def _get_export_data() -> Dict[str, Any]:
    """Get all data for export."""
    return CloudData(
        exported_at=datetime.now().isoformat(),
        hosts=get_hosts(),
        containers=get_containers()
    ).to_dict()


def export_json(filename: str = None) -> str:
    """Export data as JSON file."""
    export_dir = get_export_dir()
    os.makedirs(export_dir, exist_ok=True)

    if not filename:
        filename = f"cloud_data_{_get_timestamp()}.json"

    filepath = os.path.join(export_dir, filename)
    data = _get_export_data()

    with open(filepath, 'w') as f:
        json.dump(data, f, indent=2)

    return filepath


def export_json_js(filename: str = None) -> str:
    """Export data as JS file (JSON wrapped in variable)."""
    export_dir = get_export_dir()
    os.makedirs(export_dir, exist_ok=True)

    if not filename:
        filename = f"cloud_data_{_get_timestamp()}.js"

    filepath = os.path.join(export_dir, filename)
    data = _get_export_data()

    with open(filepath, 'w') as f:
        f.write("const cloudData = ")
        json.dump(data, f, indent=2)
        f.write(";\n")

    return filepath


def export_markdown(filename: str = None) -> str:
    """Export data as Markdown file."""
    export_dir = get_export_dir()
    os.makedirs(export_dir, exist_ok=True)

    if not filename:
        filename = f"cloud_data_{_get_timestamp()}.md"

    filepath = os.path.join(export_dir, filename)
    data = _get_export_data()

    lines = [
        f"# Cloud Infrastructure Export",
        f"*Exported: {data['exported_at']}*\n",
        "## Hosts\n",
        "| Name | Provider | Display Name | IP | Instance ID |",
        "|------|----------|--------------|----|-----------  |"
    ]

    for k, h in data['hosts'].items():
        inst_id = h['instance_id'][:20] + "..." if h['instance_id'] and len(h['instance_id']) > 20 else h['instance_id']
        lines.append(f"| {h['name']} | {h['provider']} | {h['display_name']} | {h['ip']} | {inst_id} |")

    lines.extend([
        "\n## Containers\n",
        "| Name | Host | Display Name |",
        "|------|------|--------------|"
    ])

    for k, c in data['containers'].items():
        lines.append(f"| {c['name']} | {c['host']} | {c['display_name']} |")

    with open(filepath, 'w') as f:
        f.write("\n".join(lines))

    return filepath


def export_csv() -> Dict[str, str]:
    """Export data as CSV files (hosts.csv and containers.csv)."""
    export_dir = get_export_dir()
    os.makedirs(export_dir, exist_ok=True)
    timestamp = _get_timestamp()
    data = _get_export_data()

    # Export hosts
    hosts_file = os.path.join(export_dir, f"hosts_{timestamp}.csv")
    with open(hosts_file, 'w') as f:
        f.write("name,provider,display_name,ip,instance_id,zone\n")
        for k, h in data['hosts'].items():
            f.write(f"{h['name']},{h['provider']},{h['display_name']},{h['ip']},{h['instance_id']},{h['zone']}\n")

    # Export containers
    containers_file = os.path.join(export_dir, f"containers_{timestamp}.csv")
    with open(containers_file, 'w') as f:
        f.write("name,host,display_name\n")
        for k, c in data['containers'].items():
            f.write(f"{c['name']},{c['host']},{c['display_name']}\n")

    return {"hosts": hosts_file, "containers": containers_file}


def export_all() -> Dict[str, str]:
    """Export all formats."""
    return {
        "json": export_json(),
        "js": export_json_js(),
        "md": export_markdown(),
        "csv": export_csv()
    }
