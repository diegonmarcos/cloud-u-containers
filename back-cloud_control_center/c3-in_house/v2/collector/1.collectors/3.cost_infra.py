#!/usr/bin/env python3
"""
Infrastructure Cost Collector - Cloud billing & resource usage
Collects: GCP billing, OCI billing, VM resource allocation
"""
import subprocess
import json
from datetime import datetime
from pathlib import Path

try:
    from config import load_architecture, RAW_DIR, get_vms
except ImportError:
    from pathlib import Path
    RAW_DIR = Path(__file__).parent.parent / "2.raw"
    def load_architecture(): return {}
    def get_vms(): return {}

DATE = datetime.now().strftime("%Y-%m-%d")
MONTH = datetime.now().strftime("%Y-%m")


def get_gcp_billing() -> dict:
    """Get GCP billing info via gcloud."""
    try:
        # List billing accounts
        result = subprocess.run(
            ["gcloud", "billing", "accounts", "list", "--format=json"],
            capture_output=True, text=True, timeout=30
        )
        accounts = json.loads(result.stdout) if result.returncode == 0 else []

        # Get project billing info
        result = subprocess.run(
            ["gcloud", "billing", "projects", "describe", "cloud-dashboard-api", "--format=json"],
            capture_output=True, text=True, timeout=30
        )
        project = json.loads(result.stdout) if result.returncode == 0 else {}

        return {
            "status": "ok",
            "accounts": accounts,
            "project": project,
            "tier": "free",
            "note": "GCP Free Tier - check console.cloud.google.com/billing"
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def get_oci_billing() -> dict:
    """Get OCI billing info via oci cli."""
    try:
        result = subprocess.run(
            ["oci", "iam", "tenancy", "get", "--tenancy-id",
             "ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq",
             "--output", "json"],
            capture_output=True, text=True, timeout=30,
            env={"SUPPRESS_LABEL_WARNING": "True", **subprocess.os.environ}
        )

        tenancy = json.loads(result.stdout) if result.returncode == 0 else {}

        return {
            "status": "ok",
            "tenancy": tenancy.get("data", {}),
            "tier": "always-free",
            "note": "OCI Always Free Tier - check console.oracle.com"
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def get_resource_usage() -> dict:
    """Get VM resource allocation from architecture.json."""
    try:
        vms = get_vms()
        resources = {}

        for vm_id, vm in vms.items():
            specs = vm.get("specs", {})
            resources[vm_id] = {
                "provider": vm.get("provider", "unknown"),
                "type": vm.get("instanceType", "unknown"),
                "vcpu": specs.get("cpu", 0),
                "ram_gb": specs.get("ram", 0),
                "disk_gb": specs.get("disk", 0),
                "cost": vm.get("cost", "unknown"),
            }

        totals = {
            "vcpu": sum(v.get("vcpu", 0) for v in resources.values()),
            "ram_gb": sum(v.get("ram_gb", 0) for v in resources.values()),
            "disk_gb": sum(v.get("disk_gb", 0) for v in resources.values()),
        }

        return {
            "status": "ok",
            "vms": resources,
            "totals": totals
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}


def collect_all() -> dict:
    """Collect infrastructure cost data."""
    return {
        "timestamp": datetime.now().isoformat(),
        "date": DATE,
        "month": MONTH,
        "gcp": get_gcp_billing(),
        "oci": get_oci_billing(),
        "resources": get_resource_usage(),
    }


def save_raw(data: dict):
    """Save raw data to file."""
    output_dir = RAW_DIR / "costs" / MONTH
    output_dir.mkdir(parents=True, exist_ok=True)
    output_file = output_dir / f"cost_infra_{DATE}.json"

    with open(output_file, 'w') as f:
        json.dump(data, f, indent=2, default=str)

    print(f"Saved: {output_file}")
    return output_file


if __name__ == "__main__":
    data = collect_all()
    save_raw(data)
