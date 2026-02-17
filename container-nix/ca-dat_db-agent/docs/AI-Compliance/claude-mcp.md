# Claude MCP — Model Context Protocol Integration

> How the cloud-infra MCP server connects to Claude Code and what it provides.

---

## What is MCP?

Model Context Protocol (MCP) allows Claude Code to call external tools beyond its built-in set (Read, Write, Edit, Bash, Glob, Grep). MCP servers expose domain-specific capabilities.

---

## Configuration

### Source locations

| Environment | Source (EDIT THIS) | Deployed to |
|-------------|-------------------|-------------|
| **Desktop** | `~/git/unix/ba_flakes_desktop/src/modules/dotfiles/claude/mcp.json` | `~/.mcp.json` |
| **Termux** | `~/git/unix/bb_flakes_termux/src/modules/dotfiles/claude/mcp.json` | `~/.mcp.json` |

### Current config (Termux)

```json
{
  "mcpServers": {
    "cloud-infra": {
      "type": "stdio",
      "command": "npx",
      "args": ["tsx", "/data/data/com.termux.nix/files/home/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/src/index.ts"]
    }
  }
}
```

### Desktop config

Same structure but with desktop paths (`/home/diego/Mounts/Git/cloud/...`).

---

## cloud-infra MCP Server

**Source**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/`
**SDK**: `@modelcontextprotocol/sdk ^1.12.0`
**Runtime**: `npx tsx` (primary) or Podman/Docker container (fallback)

### Architecture — Hybrid "Chef + Waiter" Model

| Layer | Role | Tools | When to use |
|-------|------|-------|-------------|
| **Chef (Native)** | Direct SSH/Docker | `ssh_exec`, `check_vm`, `docker_ps`, `docker_control`, `docker_logs`, `docker_compose_up` | Always works, even if Rust API is down |
| **Chef (Build)** | Nix build pipeline | `build_service`, `build_all`, `build_ship`, `build_docker`, `secrets_status`, `backup_trigger` | Building and deploying services |
| **Chef (Repo)** | Cross-repo file access | `read_file`, `search_repos`, `list_directory`, `reload_config` | Reading files across cloud, unix, vault, front, tools repos |
| **Waiter (Read)** | Rust API proxy | `health_alive`, `health_declared`, `health_deployed`, `health_drift`, `health_status`, `profile_container`, `profile_vm`, `service_list_apis`, `service_get_info`, `service_get_spec`, `service_discover_all` | Health monitoring, profiling, API discovery |
| **Waiter (Write)** | Rust API proxy | `vm_start`, `vm_stop`, `vm_reset`, `container_start`, `container_stop`, `container_restart`, `service_start`, `service_stop`, `service_api_call` | VM/container lifecycle management |
| **Front-End** | Monorepo ops | `front_list_projects`, `front_get_project`, `front_build`, `front_dev_server`, `front_deploy` | Building and managing 32 web projects |
| **Infra** | Config introspection | `list_vms`, `list_services`, `get_service_detail`, `reload_config` | Querying infrastructure config |

### Tool count: 44 tools

### Resources (9)

| URI | Description |
|-----|-------------|
| `cloud://config` | Full config.json |
| `cloud://ssh-config` | SSH configuration |
| `cloud://services-overview` | All services summary |
| `cloud://readme` | Cloud repo README |
| `cloud://front-projects` | Front-end project list |
| `cloud://rust-api-endpoints` | Rust API endpoint list |
| `cloud://service-apis` | Service API specifications |
| `cloud://services/{name}` | Individual service detail |
| `cloud://vms/{vm_id}` | Individual VM detail |

### Prompts (1)

| Name | Description |
|------|-------------|
| `cloud-architect` | Full cloud architecture context for planning |

---

## Tool Modules (source layout)

```
bb-sec_mcp-server-skills/src/tools/
├── infra.ts              # 4 tools — VM/service config introspection
├── repo.ts               # 3 tools — cross-repo file read/search
├── build.ts              # 2 tools — nix build pipeline
├── ssh-tools.ts          # 2 tools — SSH exec, VM health check
├── docker.ts             # 4 tools — container ops via SSH
├── native-ops.ts         # 4 tools — build_ship, docker build, secrets, backup
├── rust-api-health.ts    # 11 tools — health dashboard, profiling, API discovery
├── rust-api-control.ts   # 8 tools — VM/container/service lifecycle
├── rust-api-proxy.ts     # 1 tool  — generic service API proxy
└── front.ts              # 5 tools — front-end monorepo ops
```

---

## Safety Features

- **Input validation**: Regex patterns (`SAFE_NAME_RE`, `SAFE_SINCE_RE`) prevent injection
- **Audit logging**: Destructive operations (docker_control, build_ship, backup_trigger) are logged
- **Timeouts**: Calibrated per operation type:
  - 15s for logs
  - 60s for compose
  - 120s for builds
  - 300s for full ship pipeline
  - 600s for Docker builds (Rust on micro VMs)
- **Config caching**: 5-minute TTL, `reload_config` forces refresh

---

## MCP vs claude-guard.sh

| Aspect | MCP Server | claude-guard.sh Hooks |
|--------|-----------|----------------------|
| **Role** | Provides additional tools | Validates built-in tool usage |
| **Can block?** | No (tools are additive) | Yes (hooks can exit 1) |
| **Scope** | Cloud infrastructure operations | Code quality + build system rules |
| **Enforcement** | Helper — AI chooses to use it | Guardrail — AI cannot bypass it |

MCP gives the AI **more capabilities**. Hooks take capabilities **away** (when misused).

---

## Skills

Skills are Claude Code's prompt-injection system — predefined prompts that load domain knowledge.

**Source**: `~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills/src/skills/`
**Deployed to**: `~/.claude/skills/personal-cloud-manager/`

| Skill Level | Role | Scope |
|-------------|------|-------|
| Senior Cloud Architect | 5-VM infra, WireGuard, Caddy, Authelia, 44+ services | Full infrastructure |
| Senior Software Engineer | Rust API, Flask, MCP server, Nix, Python | Backend systems |
| Senior Software Architecture | System design, Nix flake composition, build.sh engine | Architecture |
| Senior Front-End Developer | 32-project monorepo, TS strict, Svelte 5, Vue 3, SCSS | Web projects |
| Senior Designer | ITCSS, responsive, WCAG, semantic HTML, no-inline-CSS | UI/UX |
| Junior Software Engineer | Bug fixes, small features, follows existing patterns | Scoped changes |
| Junior Ops | Docker management, logs, restarts, health checks | Operations |

**Deploy command**: `cd ~/git/cloud/a_solutions/container-nix/bb-sec_mcp-server-skills && ./build.sh deploy`

---

## APIs Accessible via MCP

| API | URL | Access method |
|-----|-----|---------------|
| **Rust API** (PRIMARY) | `https://api.diegonmarcos.com:8080` | `service_api_call` or `health_*` tools |
| **Flask API** (STALE) | `https://api.diegonmarcos.com` | `service_api_call` |
| **Service APIs** | Per-service (PhotoPrism, NocoDB, Matomo, etc.) | `service_get_spec` then `service_api_call` |

All API access through Caddy requires either Authelia 2FA (browser) or Bearer token via introspect-proxy (CLI/API).
