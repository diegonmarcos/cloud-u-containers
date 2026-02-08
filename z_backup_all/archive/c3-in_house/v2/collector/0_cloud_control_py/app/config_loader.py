"""
Configuration loader for Cloud Control Center
"""

import json
import os
from typing import Dict, Any, Optional
from pathlib import Path

from .models import Host, Container, CloudData

# Paths
APP_DIR = Path(__file__).parent.resolve()
PROJECT_ROOT = APP_DIR.parent
CONFIG_FILE = PROJECT_ROOT / "config" / "config.json"
EXPORT_DIR = PROJECT_ROOT / "exports"

_config: Optional[Dict[str, Any]] = None


def load_config(force_reload: bool = False) -> Dict[str, Any]:
    """Load and cache JSON configuration."""
    global _config
    if _config is None or force_reload:
        if not CONFIG_FILE.exists():
            raise FileNotFoundError(f"Config not found: {CONFIG_FILE}")
        with open(CONFIG_FILE, 'r') as f:
            _config = json.load(f)
    return _config


def save_config(config: Dict[str, Any] = None) -> None:
    """Save configuration to JSON file."""
    global _config
    if config is not None:
        _config = config
    if _config is not None:
        with open(CONFIG_FILE, 'w') as f:
            json.dump(_config, f, indent=2)


def get_settings() -> Dict[str, Any]:
    return load_config().get("settings", {})


def get_ssh_key() -> str:
    return get_settings().get("ssh_key", "")


def get_oci_compartment() -> str:
    return get_settings().get("oci_compartment", "")


def get_oci_list_script() -> str:
    return get_settings().get("oci_list_script", "")


def get_export_dir() -> Path:
    path = get_settings().get("export_dir", str(EXPORT_DIR))
    return Path(path)


def get_cloudflare_config() -> Dict[str, str]:
    return load_config().get("cloudflare", {})


def get_api_config() -> Dict[str, str]:
    """Get Flask API configuration."""
    return load_config().get("api", {})


def get_mcp_config() -> Dict[str, str]:
    """Get MCP Server configuration."""
    return load_config().get("mcp", {})


def get_hosts() -> Dict[str, Host]:
    config = load_config()
    return {k: Host(**v) for k, v in config.get("hosts", {}).items()}


def get_host(host_id: str) -> Optional[Host]:
    return get_hosts().get(host_id)


def get_host_ids() -> list:
    return list(load_config().get("hosts", {}).keys())


def get_containers() -> Dict[str, Container]:
    config = load_config()
    return {k: Container(**v) for k, v in config.get("containers", {}).items()}


def get_container(container_id: str) -> Optional[Container]:
    return get_containers().get(container_id)


def get_container_ids() -> list:
    return list(load_config().get("containers", {}).keys())


def get_containers_by_host(host_id: str) -> Dict[str, Container]:
    containers = get_containers()
    return {k: v for k, v in containers.items() if v.host == host_id}


def get_cloud_data() -> CloudData:
    return CloudData(hosts=get_hosts(), containers=get_containers())


def expand_path(path: str) -> str:
    return os.path.expandvars(os.path.expanduser(path))
