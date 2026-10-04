# Hybrid MCP Architecture — Full Plan

## Context

The `cloud-infra` MCP server has 21 tools covering a subset of 42 cloud services. Two gaps:
1. **MCP Native** only covers basic build/deploy/docker — missing: `ship` (full pipeline), secrets management, backups, image builds, service lifecycle
2. **MCP API** only has a generic `api_call` hitting the legacy Flask API — the active Rust API (`:8080`) with 47+ endpoints including the **new discovery system** (`/api/services/*/spec`) is not integrated

The Rust API's discovery endpoints auto-probe all services for OpenAPI/Swagger specs, enabling **dynamic API tool generation** — no need to hardcode service-specific tools.

---

## Architecture: Chef + Waiter

| Role | Tools | Access | Purpose |
|------|-------|--------|---------|
| **Chef (Native)** | 25 tools | Local fs, SSH, shell | Read, analyze, build, debug — ALL 42 services |
| **Waiter Read (API GET)** | 11 tools | Rust API health + discovery | Observe live status, discover service APIs |
| **Waiter Write (API POST)** | 8 tools | Rust API control | Safe state mutations through business logic |
| **Waiter Proxy (API dynamic)** | 1 meta-tool | Rust API → service APIs | Call any discovered service endpoint |
| Legacy (deprecated) | 2 tools | Flask API | Backward compat only |

**Total: 47 tools** (up from 21)

---

## New Files (5)

### 1. `src/utils/http.ts` — Shared HTTP helper
- `rustApiGet(endpoint, timeout?)` → `HttpResult { ok, status, data, raw, error? }`
- `rustApiPost(endpoint, body?, timeout?)` → `HttpResult`
- Uses `curl` via existing `exec()` — no new deps, stays synchronous
- Parses HTTP status via `curl -w "\n%{http_code}"`

### 2. `src/tools/rust-api-health.ts` — 11 READ tools (Waiter observing + discovering)

**Health (7 tools):**
| Tool | Endpoint | Purpose |
|------|----------|---------|
| `health_alive` | `GET /api/health` | API heartbeat |
| `health_declared` | `GET /api/health/declared` | Config-declared services (instant) |
| `health_deployed` | `GET /api/health/deployed[/{vm}]` | Live container states |
| `health_drift` | `GET /api/health/drift` | Declared vs deployed diff |
| `health_status` | `GET /api/health/status[/{vm}]` | Full health dashboard |
| `profile_container` | `GET /api/profiling/{container}` | 8-check container diagnostic |
| `profile_vm` | `GET /api/profiling/vm/{vm_id}` | Batch profile all on VM |

**Discovery (4 tools):**
| Tool | Endpoint | Purpose |
|------|----------|---------|
| `service_list_apis` | `GET /api/services` | List all services with domain, VM, spec availability |
| `service_get_info` | `GET /api/services/{service}` | Single service metadata + spec URL |
| `service_get_spec` | `GET /api/services/{service}/spec` | Fetch full OpenAPI/Swagger spec for a service |
| `service_discover_all` | `GET /api/services/all/specs` | Parallel-fetch all service specs (cached 5min) |

### 3. `src/tools/rust-api-control.ts` — 8 WRITE tools (Waiter acting)
| Tool | Endpoint | Purpose |
|------|----------|---------|
| `vm_start` | `POST /api/vms/{vm_id}/start` | Start VM (OCI/GCP abstraction) |
| `vm_stop` | `POST /api/vms/{vm_id}/stop` | Stop VM (graceful) |
| `vm_reset` | `POST /api/vms/{vm_id}/reset` | Reset/start VM |
| `container_start` | `POST /api/vms/{vm_id}/containers/{name}/start` | Start container (auto-wakes VM) |
| `container_stop` | `POST /api/vms/{vm_id}/containers/{name}/stop` | Stop container |
| `container_restart` | `POST /api/vms/{vm_id}/containers/{name}/restart` | Restart container |
| `service_start` | `POST /api/vms/{vm_id}/services/{service}/start` | Start all containers for service |
| `service_stop` | `POST /api/vms/{vm_id}/services/{service}/stop` | Stop all containers for service |

### 4. `src/tools/rust-api-proxy.ts` — 1 META tool (Waiter proxy to any service)
| Tool | Method | Purpose |
|------|--------|---------|
| `service_api_call` | Dynamic | Call any discovered service API endpoint |

**How it works:**
```
Input: { service: "authelia", method: "GET", path: "/api/verify", body?: "..." }
```
1. Calls `GET /api/services/{service}` to resolve domain
2. Constructs URL: `https://{domain}{path}`
3. Executes HTTP request via curl
4. Returns response

This is the **key to Phase 2 being done in Phase 1** — instead of hardcoding 11 service-specific tool files, the AI uses `service_get_spec` to read the OpenAPI spec, then `service_api_call` to hit any endpoint. The AI reasons about the spec, the tool proxies the call.

### 5. `src/tools/native-ops.ts` — 4 NEW Native tools (Chef expanded)

These fill the gaps in current native tool coverage:

| Tool | Purpose | Implementation |
|------|---------|----------------|
| `build_ship` | Full pipeline: build → secrets → deploy → compose | `exec("sh", ["build.sh", "ship"])` in service dir, timeout 5min |
| `build_docker` | Build + push Docker image for a service | `exec("sh", ["build.sh", "docker"])` in service dir, timeout 10min |
| `secrets_status` | Show secrets encryption status for all or one service | Read `src/secrets.yaml`, check sops markers, check `.secrets` in dist |
| `backup_trigger` | Trigger backup job (borg, bup, db-agent) | `sshExec(vm, "cd /path && docker compose run --rm backup")` |

---

## Modified Files (6)

### 6. `src/utils/paths.ts` — Add constant
```typescript
export const RUST_API_BASE = "https://api.diegonmarcos.com:8080";
```

### 7. `src/tools/api.ts` — Deprecation notices (descriptions only)
- `api_call`: `"[DEPRECATED: use service_api_call or health_* tools] ..."`
- `api_vm_control`: `"[DEPRECATED: use vm_start, vm_stop, vm_reset] ..."`

### 8. `src/tools/build.ts` — Extend `build_service` step enum
Current: `step: z.enum(["build", "secrets", "ship", "clean", "all"])`
Add: `"docker"` and `"deploy"` and `"compose"` to the enum — these already exist in build.sh but aren't exposed.

### 9. `src/index.ts` — Register new groups
```typescript
import { registerRustApiHealthTools } from "./tools/rust-api-health.js";
import { registerRustApiControlTools } from "./tools/rust-api-control.js";
import { registerRustApiProxyTools } from "./tools/rust-api-proxy.js";
import { registerNativeOpsTools } from "./tools/native-ops.js";

// Register all tools (47 total)
registerInfraTools(server);            //  3: list_vms, list_services, get_service_detail
registerRepoTools(server);             //  3: read_file, search_repos, list_directory
registerBuildTools(server);            //  2: build_service (extended), build_all
registerSshTools(server);              //  2: ssh_exec, check_vm
registerDockerTools(server);           //  4: docker_ps, docker_control, docker_logs, docker_compose_up
registerNativeOpsTools(server);        //  4: build_ship, build_docker, secrets_status, backup_trigger
registerApiTools(server);              //  2: api_call, api_vm_control (DEPRECATED)
registerRustApiHealthTools(server);    // 11: health_*, profile_*, service_list/get/spec/discover
registerRustApiControlTools(server);   //  8: vm_*, container_*, service_start/stop
registerRustApiProxyTools(server);     //  1: service_api_call
registerFrontTools(server);            //  5: front_*
```

### 10. `src/resources/index.ts` — Add 2 resources
- `cloud://rust-api-endpoints` — Static markdown table of Rust API endpoints → MCP tool mapping
- `cloud://service-apis` — Dynamic: calls `service_list_apis` at resource-read time to show discovered service API catalog

### 11. `src/prompts/index.ts` — Rewrite with hybrid decision guide

The prompt teaches the AI the full restaurant model:

**The Chef (Native, 18 tools)** — for THINKING:
- Config: `list_vms`, `list_services`, `get_service_detail`
- Files: `read_file`, `search_repos`, `list_directory`
- Build: `build_service`, `build_all`, `build_ship`, `build_docker`
- Ops: `secrets_status`, `backup_trigger`
- Debug: `docker_logs`, `ssh_exec`, `check_vm`
- Docker: `docker_ps`, `docker_control`, `docker_compose_up`

**The Waiter Read (Rust API, 11 tools)** — for OBSERVING:
- Health: `health_alive`, `health_declared`, `health_deployed`, `health_drift`, `health_status`
- Profile: `profile_container`, `profile_vm`
- Discovery: `service_list_apis`, `service_get_info`, `service_get_spec`, `service_discover_all`

**The Waiter Write (Rust API, 8 tools)** — for ACTING:
- VM: `vm_start`, `vm_stop`, `vm_reset`
- Container: `container_start`, `container_stop`, `container_restart`
- Service: `service_start`, `service_stop`

**The Waiter Proxy (1 meta-tool)** — for SERVICE API CALLS:
- `service_api_call` → call any endpoint on any discovered service
- Workflow: `service_get_spec` → read spec → `service_api_call` → execute

**Decision Matrix:**
| Situation | Tool | Layer |
|-----------|------|-------|
| "What services exist?" | `list_services` | Native |
| "Is everything healthy?" | `health_status` | API Read |
| "Why is auth broken?" | `profile_container` | API Read |
| "Start photos service" | `vm_start` → `service_start` | API Write |
| "What APIs does Matomo expose?" | `service_get_spec` | API Read |
| "Get Matomo site list" | `service_api_call` | API Proxy |
| "Deploy updated caddy" | `build_ship` | Native |
| "Show mailu logs" | `docker_logs` | Native |
| "Trigger borg backup" | `backup_trigger` | Native |
| "What's in the caddy config?" | `read_file` | Native |

**Key Rules:**
1. Always observe (`health_status`) before acting
2. Prefer API writes over native SSH — API handles wake-on-demand, validation
3. Use `service_get_spec` before `service_api_call` — understand what's available
4. Use native SSH for debugging (logs, arbitrary commands, file inspection)
5. `build_ship` for deployment, API tools for runtime control

---

## Implementation Order

1. `src/utils/paths.ts` — add `RUST_API_BASE`
2. `src/utils/http.ts` — create HTTP helper
3. `src/tools/rust-api-health.ts` — 11 read tools (health + discovery)
4. `src/tools/rust-api-control.ts` — 8 write tools
5. `src/tools/rust-api-proxy.ts` — 1 meta proxy tool
6. `src/tools/native-ops.ts` — 4 new native tools
7. `src/tools/build.ts` — extend step enum
8. `src/tools/api.ts` — deprecation descriptions
9. `src/resources/index.ts` — add 2 resources
10. `src/prompts/index.ts` — rewrite prompt
11. `src/index.ts` — wire everything together

---

## Verification

1. `npx tsx src/index.ts` — server starts, all 47 tools register
2. Send `tools/list` JSON-RPC → verify 47 tools in response
3. `health_alive` → Rust API heartbeat
4. `health_status` → full dashboard JSON
5. `service_list_apis` → list of services with spec availability
6. `service_get_spec` with "authelia" → full OpenAPI spec returned
7. `service_api_call` with authelia + `GET /api/verify` → actual response
8. `vm_start` with oci-flex → Rust API POST succeeds
9. `build_ship` with a service → full pipeline runs
10. `secrets_status` → encryption status for all services
11. Deprecated `api_call` still works (backward compat)

---

## Critical Files

| File | Role |
|------|------|
| `src/tools/api.ts` | Pattern reference (curl via exec) |
| `src/utils/exec.ts` | Synchronous shell execution |
| `src/utils/ssh.ts` | SSH command execution |
| `src/config.ts` | `resolveVmId()`, `getServiceDir()`, `getServiceFolder()` |
| `src/utils/paths.ts` | All path/URL constants |
| `bb-sec_rust-api/src/src/src/routes/docs.rs` | Discovery endpoint signatures |
| `bb-sec_rust-api/src/src/src/routes/ondemand.rs` | Control endpoint signatures |
| `bb-sec_rust-api/src/src/src/routes/health.rs` | Health endpoint signatures |
| `config.json` | Service→VM mapping, all 42 services |
| `build.sh` | Root orchestrator commands |
