const MONITOR = {
  "timestamp": "2025-12-15T23:27:49.413802",
  "date": "2025-12-15",
  "status": {
    "security": "warning",
    "performance": "ok",
    "availability": "warning",
    "web": "warning",
    "docker": "ok"
  },
  "alerts": [
    {
      "level": "critical",
      "vm": "oci-f-micro_1",
      "message": "VM unreachable"
    },
    {
      "level": "critical",
      "vm": "oci-f-micro_2",
      "message": "VM unreachable"
    },
    {
      "level": "critical",
      "vm": "oci-p-flex_1",
      "message": "VM unreachable"
    },
    {
      "level": "critical",
      "message": "VM oci-f-micro_1 unreachable"
    },
    {
      "level": "critical",
      "message": "VM oci-f-micro_2 unreachable"
    },
    {
      "level": "critical",
      "message": "VM oci-p-flex_1 unreachable"
    },
    {
      "level": "critical",
      "message": "Endpoint down: https://photos.app.diegonmarcos.com"
    },
    {
      "level": "critical",
      "message": "Endpoint down: https://auth.diegonmarcos.com"
    },
    {
      "level": "warning",
      "vm": "gcp-f-micro_1",
      "message": "100 suspicious requests detected"
    }
  ],
  "summary": {
    "security": {
      "total_failed_ssh": 194,
      "unique_attackers": 14,
      "vms_with_issues": 0
    },
    "performance": {},
    "availability": {
      "vms_reachable": 1,
      "vms_unreachable": 3,
      "endpoints_up": 5,
      "endpoints_down": 2,
      "ssl_ok": 4,
      "ssl_warning": 0,
      "ssl_critical": 0
    },
    "web": {
      "total_requests": 0,
      "total_errors": 0,
      "suspicious_count": 100
    },
    "docker": {
      "total_containers": 9,
      "running": 9,
      "stopped": 0,
      "unhealthy": 0
    },
    "costs": {
      "estimated_monthly_cost": 0,
      "cloud_cost": "Free tier"
    }
  }
};
