# Docker Report

> **Generated**: 2025-12-15T23:17:57.088547

---

## Summary

| Metric | Value |
|--------|-------|
| Total | 9 |
| Running | 9 |
| Stopped | 0 |
| Unhealthy | 0 |

## gcp-f-micro_1 (9 containers)

| Name | CPU | Memory | Mem% | Net I/O |
|------|-----|--------|------|---------|
| flask-api | 25.88% | 83.34MiB / 945.6MiB | 8.81% | 1.19MB / 950kB |
| c3-collector | 0.00% | 2.059MiB / 945.6MiB | 0.22% | 2.17kB / 264B |
| portainer | 0.04% | 11.02MiB / 945.6MiB | 1.17% | 366kB / 16.7MB |
| dozzle | 0.00% | 10.64MiB / 945.6MiB | 1.13% | 243kB / 1.41MB |
| oauth2-proxy | 0.00% | 5.121MiB / 945.6MiB | 0.54% | 3.35MB / 26MB |
| authelia-redis | 0.33% | 2.418MiB / 945.6MiB | 0.26% | 10.2MB / 12.2MB |
| npm-expose-test | 0.00% | 292KiB / 945.6MiB | 0.03% | 141kB / 126B |
| authelia | 0.01% | 24.25MiB / 945.6MiB | 2.56% | 20.4MB / 31.6MB |
| npm | 0.02% | 21.7MiB / 945.6MiB | 2.29% | 180MB / 244MB |

**Recent Errors**

```
[2025-12-15 22:09:44 +0000] [1] [ERROR] Worker (pid:743) was sent SIGKILL! Perhaps out of memory?
[2025-12-15 22:11:14 +0000] [783] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:11:14 +0000] [782] [ERROR] Error handling request (no URI read)
[2025-12-15 22:12:44 +0000] [830] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:13:45 +0000] [831] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:14:44 +0000] [869] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:15:44 +0000] [947] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:16:44 +0000] [985] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:17:44 +0000] [1024] [ERROR] Error handling request /api/cloud_control/monitor
[2025-12-15 22:18:44 +0000] [908] [ERROR] Error handling request /api/cloud_control/monitor
```
