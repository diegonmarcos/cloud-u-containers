# Profiling Endpoint: `/rust/profiling/{container}`

## Overview

Given a container name (e.g., `authelia`, `mailu-front-1`, `photoprism_app`), this endpoint runs 8 independent diagnostic checks against the container's host VM and returns a detailed JSON report with per-check success/failure, data, and timing.

The endpoint automates the full network diagnostic path: WireGuard ping, SSH connectivity, Docker container status, network inspection, port reachability (host + WireGuard), iptables DNAT rules, and Authelia bearer auth flow.

## Route

```
GET /rust/profiling/{container}
Tag: Get-Profiling
```

## Parameters

| Parameter | Type | Location | Description |
|-----------|------|----------|-------------|
| `container` | String | Path | Docker container name to profile |

## Container Resolution

The endpoint resolves which VM hosts the container by iterating `all_vm_services` config. Supported containers and their domain mappings:

| Container | VM | Domain |
|-----------|-----|--------|
| `authelia` | gcp-proxy | auth.diegonmarcos.com |
| `vaultwarden` | gcp-proxy | vault.diegonmarcos.com |
| `ntfy` | gcp-proxy | rss.diegonmarcos.com |
| `flask-api` | gcp-proxy | api.diegonmarcos.com |
| `photoprism_app` | oci-flex-1 | photos.diegonmarcos.com |
| `nocodb_app` | oci-flex-1 | db.diegonmarcos.com |
| `code-server` | oci-flex-1 | ide.diegonmarcos.com |
| `affine` | oci-flex-1 | drive-notes-affine.diegonmarcos.com |
| `syncthing` | oci-mail | sync.diegonmarcos.com |
| `radicale` | oci-mail | cal.diegonmarcos.com |
| `mailu-front-1` | oci-mail | mail.diegonmarcos.com |
| `matomo-hybrid` | oci-analytics | analytics.diegonmarcos.com |

Containers without a domain mapping (e.g., `authelia-redis`, `photoprism_mariadb`) are still profiled but the Authelia bearer auth check is skipped.

## Response Structure

```json
{
  "container": "authelia",
  "vm_id": "gcp-f-micro_1",
  "vm_label": "gcp-proxy",
  "service": "auth",
  "domain": "auth.diegonmarcos.com",
  "total_time_ms": 4823,
  "checks": [
    { "name": "wireguard_ping", "success": true, "time_ms": 42, "data": {...} },
    { "name": "ssh_connectivity", "success": true, "time_ms": 312, "data": {...} },
    { "name": "container_status", "success": true, "time_ms": 523, "data": {...} },
    { "name": "docker_network", "success": true, "time_ms": 401, "data": {...} },
    { "name": "port_reachability_host", "success": true, "time_ms": 105, "data": {...} },
    { "name": "port_reachability_wireguard", "success": true, "time_ms": 198, "data": {...} },
    { "name": "iptables_dnat", "success": true, "time_ms": 287, "data": {...} },
    { "name": "authelia_bearer_auth", "success": true, "time_ms": 1205, "data": {...} }
  ],
  "summary": {
    "checks_passed": 8,
    "checks_failed": 0,
    "checks_total": 8,
    "overall_status": "healthy"
  }
}
```

### Summary `overall_status` Values

| Status | Meaning |
|--------|---------|
| `healthy` | All checks passed |
| `degraded` | Some checks passed, some failed |
| `down` | All checks failed |

## 8 Diagnostic Checks

### 1. `wireguard_ping` — ICMP ping with latency

Pings the VM's WireGuard IP (`ping -c 3 -W 2`) and parses average latency from the rtt summary line.

**Data:**
```json
{ "host": "10.0.0.1", "latency_avg_ms": 1.234, "packets_sent": 3 }
```

### 2. `ssh_connectivity` — SSH reachability

Tests SSH connection to the VM using the configured key and user.

**Data:**
```json
{ "host": "10.0.0.1", "user": "diego" }
```

### 3. `container_status` — Docker inspect

Runs `docker inspect` to get container state, health, image, start time, and restart count. Also gets human-readable uptime from `docker ps`.

**Data:**
```json
{
  "state": "running",
  "health": "healthy",
  "image": "authelia/authelia:latest",
  "started_at": "2026-02-10T12:00:00Z",
  "restart_count": "0",
  "uptime": "Up 4 days"
}
```

**Success condition:** `state == "running"`

### 4. `docker_network` — Network config

Extracts network settings from `docker inspect` JSON: network names, container IPs, gateways, and published port mappings.

**Data:**
```json
{
  "networks": [
    { "name": "proxy_net", "ip": "172.18.0.5", "gateway": "172.18.0.1", "subnet": 16 }
  ],
  "published_ports": [
    { "host_port": 9091, "container_port": "9091/tcp" }
  ]
}
```

Published ports discovered here are used by checks 5-7.

### 5. `port_reachability_host` — Ports open on host

Tests each published port on localhost via SSH (`echo >/dev/tcp/localhost/{port}`).

**Data:**
```json
{
  "ports_checked": [
    { "host_port": 9091, "container_port": 9091, "reachable": true }
  ]
}
```

### 6. `port_reachability_wireguard` — Ports open via WireGuard

Tests each published port via direct TCP connect from the API process (no SSH needed, since the API runs on gcp-proxy with WireGuard access to all VMs).

**Data:**
```json
{
  "from": "10.0.0.1",
  "to": "10.0.0.3",
  "ports_checked": [
    { "host_port": 8444, "container_port": 443, "reachable": true, "time_ms": 15 }
  ]
}
```

### 7. `iptables_dnat` — NAT rules for the ports

Checks iptables NAT rules for the container's published ports. Falls back to `docker port` if sudo is unavailable.

**Data:**
```json
{
  "rules": [
    {
      "chain": "DOCKER",
      "protocol": "tcp",
      "dport": "9091",
      "to_destination": "172.18.0.5:9091",
      "raw": "-A DOCKER -p tcp --dport 9091 -j DNAT --to-destination 172.18.0.5:9091"
    }
  ]
}
```

### 8. `authelia_bearer_auth` — Auth flow test

Only runs if the container has a domain mapping. Tests:
1. **Unauthenticated** HTTP GET (no-redirect client) — checks for auth redirect
2. **Authenticated** GET with `Authorization: Bearer {token}` (from `AUTHELIA_BEARER_TOKEN` env) — checks for 2xx response

**Data:**
```json
{
  "domain": "auth.diegonmarcos.com",
  "unauthenticated_status": 302,
  "auth_redirect_detected": true,
  "authenticated_status": 200,
  "token_valid": true,
  "token_available": true
}
```

## Error Isolation

Each check runs independently:
- If **WireGuard ping** fails, all other checks still run
- If **SSH** fails, checks 3-7 are skipped (marked `"skipped: SSH unavailable"`) but check 8 (HTTP) still runs
- Published ports for checks 5-7 are extracted from check 4's output
- Container not found returns **404**

## SSH Optimization

SSH calls are batched to reduce connection overhead:
- **Batch 1**: Checks 3+4 (container status + docker network) — single SSH call with delimiter-separated output
- **Batch 2**: Checks 5+7 (host port reachability + iptables DNAT) — single SSH call
- Check 6 (WireGuard TCP connect) uses local `tokio::net::TcpStream`, no SSH needed

This reduces 5 SSH calls down to 2.

## Files

| File | Purpose |
|------|---------|
| `src/src/src/services/diagnostics.rs` | Reusable timed diagnostic utilities |
| `src/src/src/models/profiling.rs` | Response structs with utoipa ToSchema |
| `src/src/src/routes/profiling.rs` | Endpoint handler + check functions |
| `src/src/src/config.rs` | `container_domain_map` HashMap added to AppConfig |

## Testing

```bash
# Profile a local container (gcp-proxy)
curl http://localhost:8080/rust/profiling/authelia | jq .

# Profile a remote container (oci-mail)
curl http://localhost:8080/rust/profiling/mailu-front-1 | jq .

# Profile wake-on-demand (oci-flex-1)
curl http://localhost:8080/rust/profiling/photoprism_app | jq .

# With bearer token (through Caddy)
TOKEN=$(jq -r .access_token ~/git/vault/A0_keys/providers/authelia/oauth/authelia_tokens.json)
curl -H "Authorization: Bearer $TOKEN" https://api.diegonmarcos.com:8080/rust/profiling/authelia | jq .

# Swagger UI
# https://api.diegonmarcos.com:8080/rust/api-docs
```

## Reusable Utilities (`services/diagnostics.rs`)

These are generic and reusable for future endpoints:

| Function | Description |
|----------|-------------|
| `CheckResult::ok(name, time_ms, data)` | Successful check result |
| `CheckResult::fail(name, time_ms, error)` | Failed check result |
| `CheckResult::fail_with_data(name, time_ms, data)` | Failed with structured data |
| `ping_with_latency(host)` | Ping with parsed latency |
| `timed_ssh_check(ssh_cfg)` | SSH test with timing |
| `timed_ssh_command(name, ssh_cfg, cmd, parse_fn)` | Generic SSH+parse wrapper |
| `tcp_connect_check(host, port, timeout)` | Async TCP connect test |
