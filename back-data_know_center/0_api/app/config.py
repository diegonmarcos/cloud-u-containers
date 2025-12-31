"""
Configuration management for Cloud Dashboard Flask Server
"""
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional

# Paths
SCRIPT_DIR = Path(__file__).parent.parent.resolve()
AUDIT_DATA_DIR = Path("/app/audit-data")  # Docker mount
DEFAULT_CONFIG_PATH = AUDIT_DATA_DIR / 'cloud_dash.json'

# Timeouts
SSH_TIMEOUT = 5
PING_TIMEOUT = 2
CURL_TIMEOUT = 5

# Cache
_config: Optional[Dict[str, Any]] = None


def get_config_path() -> Path:
    """Get configuration file path from env or default."""
    env_path = os.environ.get('CLOUD_CONFIG_PATH')
    if env_path:
        return Path(env_path)
    return DEFAULT_CONFIG_PATH


def load_config(force_reload: bool = False) -> Dict[str, Any]:
    """Load and cache the JSON configuration."""
    global _config
    if _config is None or force_reload:
        config_path = get_config_path()
        if not config_path.exists():
            raise FileNotFoundError(f"Config not found: {config_path}")
        with open(config_path, 'r') as f:
            _config = json.load(f)
    return _config


def get_vm_ids() -> List[str]:
    """Get all VM IDs."""
    return list(load_config().get('virtualMachines', {}).keys())


def get_vm_ids_by_category(category: str) -> List[str]:
    """Get VM IDs filtered by category."""
    vms = load_config().get('virtualMachines', {})
    return [k for k, v in vms.items() if v.get('category') == category]


def get_vm_categories() -> List[str]:
    """Get all VM category IDs."""
    return list(load_config().get('vmCategories', {}).keys())


def get_vm_category_name(category: str) -> str:
    """Get VM category display name."""
    return load_config().get('vmCategories', {}).get(category, {}).get('name', category)


def get_vm(vm_id: str, prop: Optional[str] = None) -> Any:
    """Get VM data or specific property."""
    vm = load_config().get('virtualMachines', {}).get(vm_id, {})
    if prop is None:
        return vm

    props = prop.strip('.').split('.')
    result = vm
    for p in props:
        if isinstance(result, dict):
            result = result.get(p)
        else:
            return None
    return result


def get_service_ids() -> List[str]:
    """Get all service IDs."""
    return list(load_config().get('services', {}).keys())


def get_service_ids_by_category(category: str) -> List[str]:
    """Get service IDs filtered by category."""
    svcs = load_config().get('services', {})
    return [k for k, v in svcs.items() if v.get('category') == category]


def get_service_categories() -> List[str]:
    """Get all service category IDs."""
    return list(load_config().get('serviceCategories', {}).keys())


def get_service_category_name(category: str) -> str:
    """Get service category display name."""
    return load_config().get('serviceCategories', {}).get(category, {}).get('name', category)


def get_svc(svc_id: str, prop: Optional[str] = None) -> Any:
    """Get service data or specific property."""
    svc = load_config().get('services', {}).get(svc_id, {})
    if prop is None:
        return svc

    props = prop.strip('.').split('.')
    result = svc
    for p in props:
        if isinstance(result, dict):
            result = result.get(p)
        else:
            return None
    return result


def expand_path(path: str) -> str:
    """Expand ~ in paths."""
    if path and path.startswith('~'):
        return os.path.expanduser(path)
    return path or ''
