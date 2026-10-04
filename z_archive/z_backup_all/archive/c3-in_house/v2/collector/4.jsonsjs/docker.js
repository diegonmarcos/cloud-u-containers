const DOCKER = {
  "date": "2025-12-15",
  "timestamp": "2025-12-15T23:17:57.088547",
  "vms": {
    "gcp-f-micro_1": {
      "containers": [
        {
          "name": "flask-api",
          "cpu": "25.88%",
          "memory": "83.34MiB / 945.6MiB",
          "mem_percent": "8.81%",
          "net_io": "1.19MB / 950kB",
          "block_io": "104MB / 46.2MB"
        },
        {
          "name": "c3-collector",
          "cpu": "0.00%",
          "memory": "2.059MiB / 945.6MiB",
          "mem_percent": "0.22%",
          "net_io": "2.17kB / 264B",
          "block_io": "19.4MB / 5.27MB"
        },
        {
          "name": "portainer",
          "cpu": "0.04%",
          "memory": "11.02MiB / 945.6MiB",
          "mem_percent": "1.17%",
          "net_io": "366kB / 16.7MB",
          "block_io": "744MB / 20.7MB"
        },
        {
          "name": "dozzle",
          "cpu": "0.00%",
          "memory": "10.64MiB / 945.6MiB",
          "mem_percent": "1.13%",
          "net_io": "243kB / 1.41MB",
          "block_io": "1.01GB / 38.9MB"
        },
        {
          "name": "oauth2-proxy",
          "cpu": "0.00%",
          "memory": "5.121MiB / 945.6MiB",
          "mem_percent": "0.54%",
          "net_io": "3.35MB / 26MB",
          "block_io": "1.74GB / 67.3MB"
        },
        {
          "name": "authelia-redis",
          "cpu": "0.33%",
          "memory": "2.418MiB / 945.6MiB",
          "mem_percent": "0.26%",
          "net_io": "10.2MB / 12.2MB",
          "block_io": "708MB / 370MB"
        },
        {
          "name": "npm-expose-test",
          "cpu": "0.00%",
          "memory": "292KiB / 945.6MiB",
          "mem_percent": "0.03%",
          "net_io": "141kB / 126B",
          "block_io": "1.4MB / 90.1kB"
        },
        {
          "name": "authelia",
          "cpu": "0.01%",
          "memory": "24.25MiB / 945.6MiB",
          "mem_percent": "2.56%",
          "net_io": "20.4MB / 31.6MB",
          "block_io": "3.45GB / 312MB"
        },
        {
          "name": "npm",
          "cpu": "0.02%",
          "memory": "21.7MiB / 945.6MiB",
          "mem_percent": "2.29%",
          "net_io": "180MB / 244MB",
          "block_io": "4.55GB / 1.07GB"
        }
      ],
      "errors": [
        "[2025-12-15 22:09:44 +0000] [1] [ERROR] Worker (pid:743) was sent SIGKILL! Perhaps out of memory?",
        "[2025-12-15 22:11:14 +0000] [783] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:11:14 +0000] [782] [ERROR] Error handling request (no URI read)",
        "[2025-12-15 22:12:44 +0000] [830] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:13:45 +0000] [831] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:14:44 +0000] [869] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:15:44 +0000] [947] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:16:44 +0000] [985] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:17:44 +0000] [1024] [ERROR] Error handling request /api/cloud_control/monitor",
        "[2025-12-15 22:18:44 +0000] [908] [ERROR] Error handling request /api/cloud_control/monitor"
      ]
    }
  },
  "alerts": [],
  "summary": {
    "total_containers": 9,
    "running": 9,
    "stopped": 0,
    "unhealthy": 0
  }
};
