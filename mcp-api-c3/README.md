# cloud-infra MCP Server

MCP server for managing a personal cloud infrastructure (4 VMs, 48 services) and a 32-project front-end monorepo. Provides 45 tools, 7 resources, and 1 prompt via the Model Context Protocol stdio transport.

## Architecture

### Hybrid Model (Chef + Waiter)

The server operates as a **local Node.js process** that routes to multiple backends:

```
Claude Code ←stdio→ MCP Server (local)
                       ├── Filesystem    → read/search/list repos (cloud, unix, vault, front, tools)
                       ├── SSH           → docker, exec, VM checks
                       ├── Shell (exec)  → build.sh pipelines, nix builds
                       └── Rust API      → health, discovery, VM/container control, service proxy
                           (api.diegonmarcos.com:8080)
```

| Layer | Role | Backend | Tools |
|-------|------|---------|-------|
| **Chef (Native)** | Thinking & Building | Filesystem, SSH, shell exec | 18 tools |
| **Waiter Read** | Observing | Rust API (GET) | 11 tools |
| **Waiter Write** | Acting | Rust API (POST) | 8 tools |
| **Waiter Proxy** | Service API calls | Rust API → service domain | 1 tool |
| **Front-End** | Web project management | Filesystem, shell exec | 5 tools |
| **Legacy** | Deprecated | Flask API, gcloud CLI | 2 tools |

## Quick Start

### Prerequisites

- Node.js 22+
- SSH access to all 4 VMs (configured in `~/.ssh/config`)
- `sops` + age key for secrets decryption
- `nix` for flake builds
- Rust API running on gcp-proxy (`api.diegonmarcos.com:8080`)

### Install & Register

```bash
# Build (nix flake + npm install + type check + optional Docker image)
./build.sh build

# Decrypt secrets (if any)
./build.sh secrets

# Deploy SKILL.md to Claude Code skills directory
./build.sh deploy

# Register MCP server with Claude Code
./build.sh compose

# Or all at once:
./build.sh ship
```

### Runtime Modes

| Mode | When | Command registered |
|------|------|--------------------|
| **npx tsx** (default) | No container runtime or build failed | `npx tsx src/index.ts` |
| **Podman** | Termux / rootless | `podman run -i --rm cloud-infra-mcp:latest` |
| **Docker** | Desktop with Docker | `docker run -i --rm cloud-infra-mcp:latest` |

Container mounts `~/git` (read-only) and `~/.ssh` (read-only) from the host.

## Infrastructure

### VMs (4)

| VM ID | SSH Alias | IP | User | Tier | Description |
|-------|-----------|-----|------|------|-------------|
| `gcp-E2-f_0` | `gcp-proxy` | 35.226.147.64 | diego | Free (24/7) | Central Proxy + Control |
| `oci-E2-f_0` | `oci-mail` | 130.110.251.193 | ubuntu | Free (24/7) | Mail Server |
| `oci-E2-f_1` | `oci-analytics` | 129.151.228.66 | ubuntu | Free (24/7) | Analytics + Workflows |
| `oci-A1-f_0` | `oci-apps` | 82.70.229.129 | ubuntu | Free A1.Flex (wake-on-demand) | No services yet |
| `oci-A1-f_1` | `oci-apps-1` | 144.24.196.72 | ubuntu | Free A1.Flex (wake-on-demand) | Heavy Services |

### Services (48)

| Category | Prefix | Count | Examples |
|----------|--------|-------|----------|
| **App** (suite) | `aa-sui_` | 11 | photoprism, mailu, radicale, affine, code-server |
| **Misc** | `ab-mic_` | 2 | syncthing, vaultwarden |
| **Cloud** | `ba-clo_` | 3 | cloudflare, gcloud, oci (Terraform, local) |
| **Security** | `bb-sec_` | 7 | authelia, caddy, rust-api, sauron, wireguard |
| **Observability** | `bc-obs_` | 15 | matomo, nocodb, ntfy, lgtm, dozzle, windmill |
| **Data** | `ca-dat_` | 10 | redis, postlite, backup-borg, db-agent |

### Networking

```
Internet → Cloudflare → Caddy (gcp-proxy:443) → WireGuard (10.0.0.0/24) → target VM
                                 ↓
                           Authelia 2FA
```

## Tools Reference (45)

### Infrastructure (3) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `list_vms` | List all VMs with IP, user, SSH alias | — |
| `list_services` | List services | `vm?`, `category?` |
| `get_service_detail` | Full service info: flake, secrets, dist | `service` |

### Repository Access (3) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `read_file` | Read file from repo | `repo`, `path`, `maxLines?` |
| `search_repos` | Grep across repos | `pattern`, `repo?`, `fileGlob?`, `maxResults?` |
| `list_directory` | List directory contents | `repo`, `path?` |

Repos: `cloud`, `unix`, `vault`, `front`, `tools`. Path traversal is blocked. Access to `dist/.env` files is denied (plaintext secrets).

### Build System (2) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `build_service` | Run build.sh for a service | `service`, `step?` (build/secrets/ship/docker/deploy/compose/clean/all) |
| `build_all` | Run root build.sh orchestrator | `dryRun?` |

### SSH (2) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `ssh_exec` | Execute command on VM | `vm`, `command`, `timeout?` |
| `check_vm` | Test VM reachability + system info | `vm`, `detailed?` |

### Docker (4) — Native (via SSH)

| Tool | Description | Parameters |
|------|-------------|------------|
| `docker_ps` | List containers on a VM | `vm`, `all?` |
| `docker_control` | Start/stop/restart container | `vm`, `container`, `action` |
| `docker_logs` | Get container logs | `vm`, `container`, `lines?`, `since?` |
| `docker_compose_up` | Rebuild + restart service on VM | `service` |

### Native Ops (4) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `build_ship` | Full pipeline: build + secrets + deploy + compose | `service` |
| `build_docker` | Build and push Docker image | `service` |
| `secrets_status` | Show secrets encryption status | `service?` |
| `backup_trigger` | Trigger borg/bup/db backup job | `vm`, `service`, `type?` |

### Health (5) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `health_alive` | Heartbeat check | — |
| `health_declared` | Config-declared services (instant) | — |
| `health_deployed` | Live containers on VMs (probes SSH) | `vm?` |
| `health_drift` | Drift: declared vs deployed | — |
| `health_status` | Full dashboard (declared + deployed + drift) | `vm?` |

### Profiling (2) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `profile_container` | 8-check diagnostic on a container | `container` |
| `profile_vm` | Batch profile all containers on a VM | `vm` |

### Discovery (4) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `service_list_apis` | List services with domain + spec availability | — |
| `service_get_info` | Single service metadata + spec URL | `service` |
| `service_get_spec` | Fetch full OpenAPI/Swagger spec | `service` |
| `service_discover_all` | Parallel-fetch all specs (cached 5min) | — |

### VM Control (3) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `vm_start` | Start VM (OCI/GCP abstraction) | `vm` |
| `vm_stop` | Stop VM gracefully | `vm` |
| `vm_reset` | Force-restart VM | `vm` |

### Container Control (3) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `container_start` | Start container (auto-wakes VM) | `vm`, `name` |
| `container_stop` | Stop container | `vm`, `name` |
| `container_restart` | Restart container | `vm`, `name` |

### Service Control (2) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `service_start` | Start all containers for a service | `vm`, `service` |
| `service_stop` | Stop all containers for a service | `vm`, `service` |

### Service Proxy (1) — Rust API

| Tool | Description | Parameters |
|------|-------------|------------|
| `service_api_call` | Call any discovered service endpoint | `service`, `path`, `method?`, `body?`, `headers?` |

Workflow: `service_get_spec` (read spec) then `service_api_call` (execute).

### Front-End (5) — Native

| Tool | Description | Parameters |
|------|-------------|------------|
| `front_list_projects` | List all web projects | `category?` |
| `front_get_project` | Full project detail: build.json, deps, dist | `project` |
| `front_build` | Build project via build.sh | `project`, `command?` (build/clean/deps/status) |
| `front_dev_server` | Start/stop/status dev server | `project`, `action` |
| `front_deploy` | Run deploy.sh (CI-like) | `phase?` (deps/build/all) |

### Legacy (2) — Deprecated

| Tool | Description | Replacement |
|------|-------------|-------------|
| `api_call` | Call Flask API | `service_api_call` or `health_*` |
| `api_vm_control` | Start/stop/reset VM via Flask | `vm_start`, `vm_stop`, `vm_reset` |

## Resources (7)

| URI | Description | Format |
|-----|-------------|--------|
| `cloud://config` | Full `config.json` (VMs + services) | JSON |
| `cloud://ssh-config` | SSH client config (`~/.ssh/config`) | text |
| `cloud://services-overview` | Markdown table of all services + VMs | Markdown |
| `cloud://readme` | Cloud repo README.md | Markdown |
| `cloud://front-projects` | Front-end projects overview table | Markdown |
| `cloud://rust-api-endpoints` | Rust API endpoint → MCP tool mapping | Markdown |
| `cloud://service-apis` | Live service API catalog from Rust API | Markdown |

## Prompts (1)

| Name | Description |
|------|-------------|
| `cloud-architect` | Full cloud architect persona with hybrid tool guidance, VM/service inventory, and decision matrix |

## Skills

The MCP server ships skill definitions for Claude Code:

| Level | Skill | File |
|-------|-------|------|
| Senior | Cloud Architect | `skills/senior/cloud-architect.md` |
| Senior | Software Engineer | `skills/senior/software-engineer.md` |
| Senior | Software Architecture | `skills/senior/software-architecture.md` |
| Senior | Front-End Developer | `skills/senior/frontend-developer.md` |
| Senior | Designer | `skills/senior/designer.md` |
| Junior | Ops | `skills/junior/ops.md` |
| Junior | Software Engineer | `skills/junior/software-engineer.md` |

Plus 16 official and 24 community skill templates in `skills/official/` and `skills/community/`.

## Project Structure

```
bb-sec_mcp-server-skills/
├── build.sh                    # Universal build engine
├── build.json                  # Service config (local deploy)
├── package.json                # Node.js deps (@modelcontextprotocol/sdk, zod)
├── tsconfig.json               # TypeScript config (ES2022, strict)
└── src/
    ├── index.ts                # Entry point — registers 45 tools, 7 resources, 1 prompt
    ├── config.ts               # Config loader + VM/service resolution
    ├── types.ts                # InfraConfig, VmConfig, ServiceConfig interfaces
    ├── Dockerfile              # node:22-bookworm-slim + ssh + curl + git
    ├── flake.nix               # Nix flake: copies src + skills → dist/
    ├── tools/
    │   ├── infra.ts            #  3 tools: list_vms, list_services, get_service_detail
    │   ├── repo.ts             #  3 tools: read_file, search_repos, list_directory
    │   ├── build.ts            #  2 tools: build_service, build_all
    │   ├── ssh-tools.ts        #  2 tools: ssh_exec, check_vm
    │   ├── docker.ts           #  4 tools: docker_ps, docker_control, docker_logs, docker_compose_up
    │   ├── native-ops.ts       #  4 tools: build_ship, build_docker, secrets_status, backup_trigger
    │   ├── api.ts              #  2 tools: api_call, api_vm_control (DEPRECATED)
    │   ├── rust-api-health.ts  # 11 tools: health_*, profile_*, service_list/get/spec/discover
    │   ├── rust-api-control.ts #  8 tools: vm_*, container_*, service_start/stop
    │   ├── rust-api-proxy.ts   #  1 tool:  service_api_call
    │   └── front.ts            #  5 tools: front_list_projects, front_get_project, front_build, front_dev_server, front_deploy
    ├── resources/
    │   └── index.ts            # 7 resources: config, ssh-config, services-overview, readme, front-projects, rust-api-endpoints, service-apis
    ├── prompts/
    │   └── index.ts            # 1 prompt: cloud-architect (Chef + Waiter model)
    ├── skills/                 # Skill markdown files (deployed to ~/.claude/skills/)
    │   ├── SKILL.md            # Primary skill definition (personal-cloud-manager)
    │   ├── skills.md           # Skills index
    │   ├── senior/             # 5 senior skill personas
    │   ├── junior/             # 2 junior skill personas
    │   ├── official/           # 16 official skill templates
    │   └── community/          # 24 community skill templates
    └── utils/
        ├── exec.ts             # spawnSync wrapper with SOPS_AGE_KEY_FILE env
        ├── ssh.ts              # SSH exec + reachability check (via SSH alias)
        ├── http.ts             # curl-based HTTP client (Rust API + raw requests)
        └── paths.ts            # All path constants (HOME, GIT_BASE, REPOS, RUST_API_BASE)
```

## Configuration

### config.json

The server reads `config.json` from the cloud repo root. This is the single source of truth for all VMs and services:

```json
{
  "ssh_key": "/path/to/ssh/key",
  "remote_base": "/opt/containers",
  "vms": {
    "vm-id": { "ip": "...", "user": "...", "method": "key|gcloud", "description": "..." }
  },
  "services": {
    "service-name": { "category": "app|mic|sec|tools|cloud|data", "vm": "vm-id", "description": "..." }
  }
}
```

### build.json

```json
{
  "name": "mcp-server-skills",
  "description": "Cloud-infra MCP server for Claude Code",
  "deploy": {
    "host": "local",
    "docker_image": "cloud-infra-mcp:latest",
    "skill_dest": "~/.claude/skills/personal-cloud-manager",
    "mcp_name": "cloud-infra"
  }
}
```

### Build Pipeline

| Step | Command | What it does |
|------|---------|-------------|
| `build` | `./build.sh build` | Nix flake → `dist/`, npm install, tsc type-check, Docker image build |
| `secrets` | `./build.sh secrets` | sops decrypt `secrets.yaml` → `dist/.secrets` |
| `deploy` | `./build.sh deploy` | Copy `SKILL.md` → `~/.claude/skills/personal-cloud-manager/` |
| `compose` | `./build.sh compose` | Register MCP server with `claude mcp add` |
| `all` | `./build.sh all` | build + secrets (default) |
| `ship` | `./build.sh ship` | build + secrets + deploy + compose (full pipeline) |
| `clean` | `./build.sh clean` | Remove `dist/`, `.result`, Docker image |

## Security

- **Path traversal protection**: `read_file` and `list_directory` validate resolved paths stay within repo boundaries
- **Secret file blocking**: Access to `dist/.env` files is denied (plaintext secrets)
- **Container name validation**: Docker tools validate container names against `/^[a-zA-Z0-9_.-]+$/`
- **Secrets encryption**: `sops` + age key for `secrets.yaml` files; `secrets_status` tool audits encryption state
- **Read-only mounts**: Container mode mounts `~/git` and `~/.ssh` as read-only
- **No credential exposure**: Vault repo access is available but dist/.env and plaintext secret files are blocked

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `@modelcontextprotocol/sdk` | ^1.12.0 | MCP server framework (stdio transport) |
| `zod` | ^3.25.0 | Schema validation for tool parameters |
| `typescript` | ^5.7.0 | Type checking (dev) |
| `tsx` | ^4.19.0 | TypeScript execution without compilation (dev) |
| `@types/node` | ^22.0.0 | Node.js type definitions (dev) |

## Decision Matrix

| Situation | Tool | Layer |
|-----------|------|-------|
| "What services exist?" | `list_services` | Chef (Native) |
| "Is everything healthy?" | `health_status` | Waiter Read |
| "Why is auth broken?" | `profile_container` | Waiter Read |
| "Start photos service" | `vm_start` → `service_start` | Waiter Write |
| "What APIs does Matomo expose?" | `service_get_spec` | Waiter Read |
| "Get Matomo site list" | `service_api_call` | Waiter Proxy |
| "Deploy updated caddy" | `build_ship` | Chef (Native) |
| "Show mailu logs" | `docker_logs` | Chef (Native) |
| "Trigger borg backup" | `backup_trigger` | Chef (Native) |
| "What's in the caddy config?" | `read_file` | Chef (Native) |
| "Check secrets encryption" | `secrets_status` | Chef (Native) |
| "Build the landing page" | `front_build` | Front-End |
| "Start dev server for myfeed" | `front_dev_server` | Front-End |
