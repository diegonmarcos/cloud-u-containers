# Cloud Dashboard API Endpoints

> **Base URL**: `https://cloud.diegonmarcos.com/api`
> **Version**: 1.0.0
> **Last Updated**: 2025-12-28

---

## Blueprint Structure

| Blueprint | URL Prefix | Purpose |
|-----------|------------|---------|
| `api_bp` | `/api` | Core infrastructure API |
| `auth_bp` | `/api/auth` | GitHub OAuth authentication |
| `admin_bp` | `/api/admin` | Protected admin operations |
| `c3_bp` | `/api/c3` | Cloud Control Center data |
| `web_bp` | `/` | Web dashboard (HTML) |

---

## 1. Core API (`/api`)

### Health & Configuration

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/health` | API health check | No |
| GET | `/api/config` | Get full infrastructure config | No |
| POST | `/api/config/reload` | Force reload config from disk | No |

### Virtual Machines

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/vms` | List all VMs (optional `?category=`) | No |
| GET | `/api/vms/categories` | List VM categories | No |
| GET | `/api/vms/<vm_id>` | Get VM details | No |
| GET | `/api/vms/<vm_id>/status` | Get VM health (ping, SSH, RAM) | No |
| GET | `/api/vms/<vm_id>/details` | Get system info via SSH | No |
| GET | `/api/vms/<vm_id>/containers` | Get Docker containers on VM | No |
| POST | `/api/vms/<vm_id>/start` | Start VM (OCI/GCP) | No |
| POST | `/api/vms/<vm_id>/stop` | Stop VM (OCI/GCP) | No |
| POST | `/api/vms/<vm_id>/reset` | Reset/reboot VM | No |

### Container Control

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| POST | `/api/vms/<vm_id>/containers/<name>/start` | Start container | No |
| POST | `/api/vms/<vm_id>/containers/<name>/stop` | Stop container | No |
| POST | `/api/vms/<vm_id>/containers/<name>/restart` | Restart container | No |

### Services

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/services` | List all services (optional `?category=`) | No |
| GET | `/api/services/categories` | List service categories | No |
| GET | `/api/services/<svc_id>` | Get service details | No |
| GET | `/api/services/<svc_id>/status` | Get service health (HTTP check) | No |

### Dashboard

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/dashboard/summary` | Full summary with health checks | No |
| GET | `/api/dashboard/quick-status` | Config-only status (no health) | No |

### Cloud Control (Legacy)

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/cloud_control/monitor` | VMs + services status | No |
| GET | `/api/cloud_control/costs_infra` | Infrastructure costs | No |
| GET | `/api/cloud_control/costs_ai` | AI/Claude costs | No |
| GET | `/api/cloud_control/infrastructure` | Full infra details | No |

### Providers & Domains

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/providers` | List cloud providers | No |
| GET | `/api/domains` | List domains/subdomains | No |

### Wake-on-Demand

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| POST | `/api/wake/trigger` | Wake oci-p-flex_1 VM | No |
| GET | `/api/wake/status` | Get wake/instance status | No |

---

## 2. Authentication (`/api/auth`)

### GitHub OAuth

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/auth/github` | Get GitHub OAuth URL | No |
| GET | `/api/auth/github/redirect` | Redirect to GitHub login | No |
| GET | `/api/auth/callback` | OAuth callback handler | No |
| GET | `/api/auth/me` | Get current user info | JWT |
| POST | `/api/auth/logout` | Logout (discard token) | JWT |
| POST | `/api/auth/verify` | Verify JWT token validity | No |

---

## 3. Admin API (`/api/admin`)

> All endpoints require JWT authentication via `Authorization: Bearer <token>`

### VM Management

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| POST | `/api/admin/vms/<vm_id>/reboot` | Reboot VM via SSH | JWT |
| GET | `/api/admin/vms/<vm_id>/containers` | List containers (detailed) | JWT |

### Container Management

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| POST | `/api/admin/vms/<vm_id>/containers/<name>/restart` | Restart container | JWT |
| POST | `/api/admin/vms/<vm_id>/containers/<name>/stop` | Stop container | JWT |
| POST | `/api/admin/vms/<vm_id>/containers/<name>/start` | Start container | JWT |
| GET | `/api/admin/vms/<vm_id>/containers/<name>/logs` | Get container logs (`?lines=100`) | JWT |

### Service Management

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| POST | `/api/admin/services/<svc_id>/restart` | Restart service container | JWT |

### Audit

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/admin/audit-log` | Get admin actions log (`?limit=50`) | JWT |

---

## 4. C3 API (`/api/c3`)

> Cloud Control Center - Serves pre-computed JSON data from collectors

### Dashboard

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/dashboard` | Combined dashboard data | No |
| GET | `/api/c3/alerts` | All alerts from all categories | No |

### Security

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/security` | Full security data | No |
| GET | `/api/c3/security/summary` | Security summary + alerts | No |
| GET | `/api/c3/security/vms/<vm_name>` | Security data for VM | No |
| GET | `/api/c3/security/failed-ssh` | Failed SSH attempts | No |

### Performance

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/performance` | Full performance data | No |
| GET | `/api/c3/performance/summary` | Performance summary | No |
| GET | `/api/c3/performance/vms/<vm_name>` | Performance for VM | No |
| GET | `/api/c3/performance/docker` | Docker stats all VMs | No |

### Docker

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/docker` | Full docker data | No |
| GET | `/api/c3/docker/vms/<vm_name>` | Docker data for VM | No |

### Web/HTTP

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/web` | Full web/HTTP data | No |
| GET | `/api/c3/web/summary` | Web summary | No |
| GET | `/api/c3/web/threats` | Suspicious requests, scanners | No |
| GET | `/api/c3/web/top-ips` | Top requesting IPs | No |

### Availability

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/availability` | Full availability data | No |
| GET | `/api/c3/availability/status` | Current availability status | No |
| GET | `/api/c3/availability/endpoints` | Endpoint health | No |
| GET | `/api/c3/availability/ssl` | SSL certificate status | No |
| GET | `/api/c3/availability/vms` | VM connectivity status | No |

### Costs

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/costs` | Full costs data | No |
| GET | `/api/c3/costs/infra` | Infrastructure costs | No |
| GET | `/api/c3/costs/ai` | AI/Claude costs | No |

### Architecture

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/api/c3/architecture` | Full architecture data | No |

---

## 5. Web Routes (`/`)

| Method | Endpoint | Description | Auth |
|--------|----------|-------------|------|
| GET | `/` | Redirect to API docs | No |
| GET | `/docs` | Redirect to API docs | No |
| GET | `/dashboard` | HTML dashboard page | No |

---

## Endpoint Summary

| Category | Count |
|----------|-------|
| Core API | 28 |
| Auth | 6 |
| Admin | 8 |
| C3 | 22 |
| Web | 3 |
| **Total** | **67** |

---

## Authentication

### JWT Token

Protected endpoints require the `Authorization` header:

```
Authorization: Bearer <jwt_token>
```

Tokens are obtained via GitHub OAuth flow:
1. GET `/api/auth/github/redirect` - Redirects to GitHub
2. GitHub redirects back to `/api/auth/callback`
3. Callback returns JWT token in URL params

### Allowed Users

Configured via `ALLOWED_GITHUB_USERS` environment variable.

---

## Response Formats

### Success Response

```json
{
  "status": "ok",
  "data": { ... }
}
```

### Error Response

```json
{
  "error": "Error message"
}
```

HTTP Status Codes:
- `200` - Success
- `400` - Bad Request
- `401` - Unauthorized (missing/invalid token)
- `403` - Forbidden (user not allowed)
- `404` - Not Found
- `500` - Server Error
- `503` - Service Unavailable (VM/service unreachable)
