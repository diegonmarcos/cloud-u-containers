"""
Flask API client for Cloud Control Center

Communicates with external Flask API server to fetch/push data.
"""

import json
import subprocess
from typing import Dict, Any, Optional

from .config_loader import get_api_config


class APIClient:
    """Client for Flask API communication."""

    def __init__(self, base_url: str = None):
        config = get_api_config()
        self.base_url = base_url or config.get("url", "http://localhost:5000")
        self.token = config.get("token", "")
        self.timeout = config.get("timeout", 30)

    def _request(self, endpoint: str, method: str = "GET", data: dict = None) -> Dict[str, Any]:
        """Make HTTP request to API."""
        url = f"{self.base_url}/{endpoint.lstrip('/')}"

        headers = ["-H 'Content-Type: application/json'"]
        if self.token:
            headers.append(f"-H 'Authorization: Bearer {self.token}'")

        cmd = f"curl -s -X {method} {' '.join(headers)} --max-time {self.timeout} '{url}'"

        if data:
            cmd += f" -d '{json.dumps(data)}'"

        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=self.timeout + 5)
            if result.stdout:
                return {"success": True, "data": json.loads(result.stdout)}
            return {"success": False, "error": result.stderr or "Empty response"}
        except json.JSONDecodeError as e:
            return {"success": False, "error": f"JSON decode error: {e}", "raw": result.stdout}
        except Exception as e:
            return {"success": False, "error": str(e)}

    # =========================================================================
    # INFRASTRUCTURE
    # =========================================================================

    def get_infrastructure(self) -> Dict[str, Any]:
        """Get infrastructure data."""
        return self._request("/cloud_control/infrastructure")

    def get_monitor_data(self) -> Dict[str, Any]:
        """Get monitoring data."""
        return self._request("/cloud_control/monitor")

    def get_config(self) -> Dict[str, Any]:
        """Get API config."""
        return self._request("/api/config")

    def reload_config(self) -> Dict[str, Any]:
        """Reload API config."""
        return self._request("/api/config/reload", method="POST")

    # =========================================================================
    # VMS
    # =========================================================================

    def list_vms(self) -> Dict[str, Any]:
        """List all VMs."""
        return self._request("/api/vms")

    def get_vm(self, vm_id: str) -> Dict[str, Any]:
        """Get VM details."""
        return self._request(f"/api/vms/{vm_id}")

    def get_vm_status(self, vm_id: str) -> Dict[str, Any]:
        """Get VM status."""
        return self._request(f"/api/vms/{vm_id}/status")

    def vm_reboot(self, vm_id: str) -> Dict[str, Any]:
        """Reboot VM."""
        return self._request(f"/api/vm/{vm_id}/reboot", method="POST")

    def vm_stop(self, vm_id: str) -> Dict[str, Any]:
        """Stop VM."""
        return self._request(f"/api/vm/{vm_id}/stop", method="POST")

    def vm_start(self, vm_id: str) -> Dict[str, Any]:
        """Start VM."""
        return self._request(f"/api/vm/{vm_id}/start", method="POST")

    # =========================================================================
    # SERVICES
    # =========================================================================

    def list_services(self) -> Dict[str, Any]:
        """List all services."""
        return self._request("/api/services")

    def get_service(self, svc_id: str) -> Dict[str, Any]:
        """Get service details."""
        return self._request(f"/api/services/{svc_id}")

    def get_service_status(self, svc_id: str) -> Dict[str, Any]:
        """Get service status."""
        return self._request(f"/api/services/{svc_id}/status")

    def service_kill(self, svc_id: str) -> Dict[str, Any]:
        """Kill service."""
        return self._request(f"/api/service/{svc_id}/kill", method="POST")

    # =========================================================================
    # DASHBOARD
    # =========================================================================

    def get_dashboard_summary(self) -> Dict[str, Any]:
        """Get dashboard summary."""
        return self._request("/api/dashboard/summary")

    def get_quick_status(self) -> Dict[str, Any]:
        """Get quick status."""
        return self._request("/api/dashboard/quick-status")

    # =========================================================================
    # COSTS
    # =========================================================================

    def get_costs_ai_daily(self) -> Dict[str, Any]:
        """Get daily AI costs."""
        return self._request("/api/costs/ai/daily")

    def get_costs_ai_monthly(self) -> Dict[str, Any]:
        """Get monthly AI costs."""
        return self._request("/api/costs/ai/monthly")

    # =========================================================================
    # WAKE
    # =========================================================================

    def get_wake_status(self) -> Dict[str, Any]:
        """Get wake status."""
        return self._request("/api/wake/status")

    def trigger_wake(self) -> Dict[str, Any]:
        """Trigger wake."""
        return self._request("/api/wake/trigger", method="POST")


# Default client instance
_client: Optional[APIClient] = None


def get_client() -> APIClient:
    """Get or create API client."""
    global _client
    if _client is None:
        _client = APIClient()
    return _client
