"""
Data models for Cloud Control Center
"""

from dataclasses import dataclass, asdict, field
from typing import Optional, Dict, Any
from datetime import datetime


@dataclass
class Host:
    """Represents a cloud VM host"""
    name: str
    provider: str  # gcp, oci
    display_name: str
    ip: str = ""
    instance_id: str = ""
    zone: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class Container:
    """Represents a Docker container"""
    name: str
    host: str
    display_name: str

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class RuntimeStatus:
    """Runtime status of a host or container"""
    online: bool = False
    ping: bool = False
    ssh: bool = False
    http: bool = False
    ram_percent: Optional[int] = None
    cpu_percent: Optional[float] = None
    last_check: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


@dataclass
class CloudData:
    """Complete cloud infrastructure data"""
    exported_at: str = ""
    hosts: Dict[str, Host] = field(default_factory=dict)
    containers: Dict[str, Container] = field(default_factory=dict)
    statuses: Dict[str, RuntimeStatus] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "exported_at": self.exported_at or datetime.now().isoformat(),
            "hosts": {k: v.to_dict() for k, v in self.hosts.items()},
            "containers": {k: v.to_dict() for k, v in self.containers.items()},
            "statuses": {k: v.to_dict() for k, v in self.statuses.items()},
        }
