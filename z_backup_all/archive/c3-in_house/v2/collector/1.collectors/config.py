#!/usr/bin/env python3
"""
Shared configuration - Loads from architecture.json (SOURCE OF TRUTH)
All collectors import this to get VM IPs, SSH commands, endpoints.
"""
import json
from pathlib import Path
from typing import Optional

# =============================================================================
# Paths
# =============================================================================

SCRIPT_DIR = Path(__file__).parent
BASE_DIR = SCRIPT_DIR.parent
RAW_DIR = BASE_DIR / "2.raw"
JSON_DIR = BASE_DIR / "4.jsons"

# SOURCE OF TRUTH
ARCHITECTURE_JSON = Path("/home/diego/Documents/Git/back-System/cloud/0.spec/architecture.json")

# Claude logs for cost tracking
CLAUDE_LOGS = Path.home() / ".claude/projects"

# =============================================================================
# Load Architecture
# =============================================================================

_arch_cache: Optional[dict] = None

def load_architecture() -> dict:
    """Load architecture.json (cached)."""
    global _arch_cache
    if _arch_cache is None:
        if not ARCHITECTURE_JSON.exists():
            raise FileNotFoundError(f"Architecture file not found: {ARCHITECTURE_JSON}")
        with open(ARCHITECTURE_JSON, 'r') as f:
            _arch_cache = json.load(f)
    return _arch_cache


def get_vms() -> dict:
    """Get all VMs from architecture."""
    arch = load_architecture()
    return arch.get("virtualMachines", {})


def get_vm(vm_id: str) -> dict:
    """Get single VM config."""
    return get_vms().get(vm_id, {})


def get_active_vms() -> dict:
    """Get only active VMs."""
    return {k: v for k, v in get_vms().items() if v.get("status") == "active"}


def get_services() -> dict:
    """Get all services from architecture."""
    arch = load_architecture()
    return arch.get("services", {})


def get_endpoints() -> list:
    """Get all endpoints to monitor (from domains.subdomains)."""
    arch = load_architecture()
    subdomains = arch.get("domains", {}).get("subdomains", {})

    endpoints = []
    for domain, config in subdomains.items():
        if config.get("status") == "on":
            endpoints.append({
                "url": f"https://{domain}",
                "domain": domain,
                "service": config.get("service"),
                "ssl": config.get("ssl", True),
            })
    return endpoints


def get_ssl_domains() -> list:
    """Get domains that need SSL monitoring."""
    return [ep["domain"] for ep in get_endpoints() if ep.get("ssl")]


# =============================================================================
# SSH Helpers
# =============================================================================

def get_ssh_command(vm_id: str, command: str) -> list:
    """Get SSH command for a VM."""
    vm = get_vm(vm_id)
    if not vm:
        raise ValueError(f"Unknown VM: {vm_id}")

    ssh_config = vm.get("ssh", {})

    # GCP uses gcloud compute ssh
    if vm.get("provider") == "gcloud":
        return [
            "gcloud", "compute", "ssh",
            "arch-1",  # instance name
            "--zone", "us-central1-a",
            f"--command={command}"
        ]

    # Oracle/others use direct SSH
    key_path = ssh_config.get("keyPath", "")
    user = ssh_config.get("user", "ubuntu")
    ip = vm.get("network", {}).get("publicIp", "")

    return [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=10",
        "-i", key_path,
        f"{user}@{ip}",
        command
    ]


def get_vm_ip(vm_id: str) -> str:
    """Get public IP for a VM."""
    vm = get_vm(vm_id)
    return vm.get("network", {}).get("publicIp", "")


def get_all_ips() -> dict:
    """Get {vm_id: ip} mapping for all active VMs."""
    return {vm_id: get_vm_ip(vm_id) for vm_id in get_active_vms()}


# =============================================================================
# Quick Reference
# =============================================================================

def get_quick_ssh_commands() -> dict:
    """Get pre-built SSH commands from architecture."""
    arch = load_architecture()
    return arch.get("quickCommands", {}).get("ssh", {})


def get_costs() -> dict:
    """Get cost configuration."""
    arch = load_architecture()
    return arch.get("costs", {})


# =============================================================================
# Print helpers (for debugging)
# =============================================================================

if __name__ == "__main__":
    print("=== Active VMs ===")
    for vm_id, vm in get_active_vms().items():
        ip = vm.get("network", {}).get("publicIp", "N/A")
        print(f"  {vm_id}: {ip}")

    print("\n=== Endpoints ===")
    for ep in get_endpoints():
        print(f"  {ep['url']}")

    print("\n=== SSH Commands ===")
    for vm_id, cmd in get_quick_ssh_commands().items():
        print(f"  {vm_id}: {cmd}")
