const AVAILABILITY = {
  "date": "2025-12-15",
  "timestamp": "2025-12-15T23:19:48.681400",
  "current_status": {
    "vms": [
      {
        "name": "oci-f-micro_1",
        "ip": "130.110.251.193",
        "ping": "down",
        "ssh": "ok",
        "latency_ms": null
      },
      {
        "name": "oci-f-micro_2",
        "ip": "129.151.228.66",
        "ping": "down",
        "ssh": "ok",
        "latency_ms": null
      },
      {
        "name": "gcp-f-micro_1",
        "ip": "34.55.55.234",
        "ping": "up",
        "ssh": "error",
        "latency_ms": 248.303
      },
      {
        "name": "oci-p-flex_1",
        "ip": "84.235.234.87",
        "ping": "down",
        "ssh": "error",
        "latency_ms": null
      }
    ],
    "endpoints": [
      {
        "url": "https://diegonmarcos.com",
        "status": "up",
        "code": 200,
        "latency_ms": 1086.77
      },
      {
        "url": "https://photos.app.diegonmarcos.com",
        "status": "down",
        "code": null,
        "latency_ms": null
      },
      {
        "url": "https://analytics.diegonmarcos.com",
        "status": "up",
        "code": 200,
        "latency_ms": 1457.67
      },
      {
        "url": "https://sync.diegonmarcos.com",
        "status": "up",
        "code": 200,
        "latency_ms": 1202.96
      },
      {
        "url": "https://n8n.diegonmarcos.com",
        "status": "up",
        "code": 200,
        "latency_ms": 1193.18
      },
      {
        "url": "https://proxy.diegonmarcos.com",
        "status": "up",
        "code": 200,
        "latency_ms": 1108.87
      },
      {
        "url": "https://auth.diegonmarcos.com",
        "status": "down",
        "code": null,
        "latency_ms": null
      }
    ],
    "ssl": [
      {
        "domain": "diegonmarcos.com",
        "status": "ok",
        "days_left": 81,
        "expires": "2026-03-07T12:33:09"
      },
      {
        "domain": "photos.app.diegonmarcos.com",
        "status": "error",
        "days_left": null,
        "expires": null
      },
      {
        "domain": "analytics.diegonmarcos.com",
        "status": "ok",
        "days_left": 83,
        "expires": "2026-03-09T00:09:37"
      },
      {
        "domain": "sync.diegonmarcos.com",
        "status": "ok",
        "days_left": 83,
        "expires": "2026-03-09T13:36:12"
      },
      {
        "domain": "n8n.diegonmarcos.com",
        "status": "ok",
        "days_left": 83,
        "expires": "2026-03-09T00:11:12"
      }
    ]
  },
  "alerts": [
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
    }
  ],
  "summary": {
    "vms_reachable": 1,
    "vms_unreachable": 3,
    "endpoints_up": 5,
    "endpoints_down": 2,
    "ssl_ok": 4,
    "ssl_warning": 0,
    "ssl_critical": 0
  }
};
