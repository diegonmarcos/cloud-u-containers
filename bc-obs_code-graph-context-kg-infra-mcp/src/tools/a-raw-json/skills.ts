/**
 * Skill tools — inject domain knowledge into Claude's context on-demand.
 * These are the "persona" tools: Claude calls them to understand HOW to work.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { getConfig, getVmSshAlias } from "../../config.js";

export function registerSkillTools(server: McpServer) {

  // ── 1. cloud-architect ──────────────────────────────────────────────
  server.tool(
    "skill_cloud_architect",
    "Load cloud infrastructure context — VMs, services, architecture, tool decision matrix. Call this before infrastructure tasks.",
    {},
    async () => {
      const config = getConfig();

      const vmTable = Object.entries(config.vms)
        .map(([id, vm]) => `| ${id} | ${getVmSshAlias(id)} | ${vm.ip} | ${vm.wg_ip ?? ""} | ${vm.user} | ${vm.description ?? ""} |`)
        .join("\n");

      const categories = new Map<string, string[]>();
      for (const [name, svc] of Object.entries(config.services)) {
        const cat = svc.category;
        if (!categories.has(cat)) categories.set(cat, []);
        categories.get(cat)!.push(`${name} → ${svc.vm}`);
      }
      const serviceList = [...categories.entries()]
        .map(([cat, svcs]) => `| ${cat} | ${svcs.join(", ")} |`)
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# Cloud Infrastructure Context

## VMs (${Object.keys(config.vms).length})

| VM ID | Alias | IP | WG IP | User | Description |
|-------|-------|----|-------|------|-------------|
${vmTable}

## Services (${Object.keys(config.services).length})

| Category | Services |
|----------|----------|
${serviceList}

## Architecture
- Nix flakes → Docker Compose stacks, cloud-data-topology.json is source of truth
- Per-service build.sh: build → secrets (sops) → deploy (rsync) → compose
- WireGuard mesh 10.0.0.0/24 connects all VMs
- GCP proxy (gcp-E2-f_0): Caddy + Authelia entry point
- C3 API (api.diegonmarcos.com/c3-api): health, discovery, control, topology, tests, files

## Chef + Waiter Tool Model

**Chef (Native)** — THINKING & BUILDING
- Config: list_vms, list_services, get_service_detail
- Files: read_file, search_repos, list_directory
- Build: build_service, build_all, build_ship, build_docker
- Ops: secrets_status, backup_trigger
- Debug: docker_logs, ssh_exec, check_vm, docker_ps, docker_control, docker_compose_up

**Waiter Read (C3 API)** — OBSERVING
- Health: health_alive, health_declared, health_deployed, health_drift, health_status
- Profile: profile_container, profile_vm
- Discovery: service_list_apis, service_get_info, service_get_spec, service_discover_all

**Waiter Write (C3 API)** — ACTING
- VM: vm_start, vm_stop, vm_reset
- Container: container_start, container_stop, container_restart
- Service: service_start, service_stop

## Decision Matrix
| Situation | Tool | Layer |
|-----------|------|-------|
| "What services exist?" | list_services | Chef |
| "Is everything healthy?" | health_status | Waiter Read |
| "Why is X broken?" | profile_container | Waiter Read |
| "Start photos service" | vm_start → service_start | Waiter Write |
| "Deploy updated caddy" | build_ship | Chef |
| "Show mailu logs" | docker_logs | Chef |

## Key Rules
1. OBSERVE (health_status) before ACTING
2. Prefer C3 API writes over SSH
3. service_get_spec before service_api_call
4. build_ship for deployment, API tools for runtime control
5. Never expose secrets`,
        }],
      };
    }
  );

  // ── 2. frontend-developer ───────────────────────────────────────────
  server.tool(
    "skill_frontend_developer",
    "Load front-end development context — code standards (TS/Svelte5/Vue3/SCSS), build system, project archetypes. Call this before front-end work.",
    {},
    async () => ({
      content: [{
        type: "text" as const,
        text: `# Front-End Development Context

## Build System
- Universal build.sh engine + build.json config per project
- Shared root node_modules, GitHub Actions CI/CD → GitHub Pages
- Commands: front_build (build), front_dev_server (dev), front_deploy (CI)
- Archetypes: Vite (Vue/React), SvelteKit, Sass+esbuild, Sass+tsc, copy-only, Nuxt

## Code Standards

### TypeScript (Strict Mode)
- No \`any\`, handle \`null\`/\`undefined\` explicitly
- DOM: cast elements, check null
- ES Modules: \`import\`/\`export\`, no CommonJS

### Svelte 5 (Runes Mode) — CRITICAL
\`\`\`typescript
let { propName }: { propName: Type } = $props();
let count = $state(0);
let doubled = $derived(count * 2);
// Events: standard HTML (onclick, not on:click)
\`\`\`

### Vue 3 (Composition API)
\`\`\`typescript
// Always <script setup lang="ts">
defineProps<{ id: number; name: string }>();
const user = ref<User | null>(null);
\`\`\`

### SCSS (ITCSS)
\`\`\`scss
@include mq(sm|md|lg|xl)
@include flex-center;
@include flex-row(justify, align, gap);
@include grid-auto-fit(min-size, gap);
\`\`\`

### CRITICAL Rules
- **NEVER** use \`style=""\` inline CSS — ALL styling via SCSS classes
- Semantic HTML: header, nav, main, section, article, footer
- <a> for navigation, <button> for actions
- All <img> need alt, inputs need <label>

### Matomo (required in every HTML <head>)
Include the container_odwLIyPV.js tag manager snippet from analytics.diegonmarcos.com.`,
      }],
    })
  );

  // ── 3. debug-ops ────────────────────────────────────────────────────
  server.tool(
    "skill_debug_ops",
    "Load debugging/ops context — debug workflow, common issues, WireGuard/SMTP/memory gotchas. Call this before debugging infrastructure.",
    {},
    async () => {
      const config = getConfig();
      const vmAliases = Object.entries(config.vms)
        .map(([id, vm]) => `${getVmSshAlias(id)} (${vm.ip})`)
        .join(", ");

      return {
        content: [{
          type: "text" as const,
          text: `# Debug & Ops Context

## VMs: ${vmAliases}

## Debug Workflow
1. **Observe**: health_status → full dashboard
2. **Identify**: profile_container → CPU/mem/net/disk/ports
3. **Investigate**: docker_logs (since='1h'), ssh_exec, read_file
4. **Act**: container_restart, service_start/stop, docker_compose_up
5. **Deploy Fix**: build_ship → build → secrets → deploy → compose

## Common Issues

### Container not starting
docker_logs → docker_ps all=true → profile_container

### Service unreachable
health_status → check_vm → ssh_exec: nft list ruleset → wg show

### WireGuard
- /etc/wireguard/ is 700 root:root — need sudo
- Docker nftables DNAT handles wg0 (Docker 29+)
- nft list ruleset > iptables -S

### Mailu/SMTP
- Port 587 disabled, use 465 (implicit TLS)
- Authelia: submissions:// for 465
- TLS server_name must match cert SAN

### Memory (1GB VMs)
- Nix eval needs 2-3GB swap
- nix-store --verify --repair for corruption
- Docker build: --jobs 1, lto = false`,
        }],
      };
    }
  );

  // ── 4. crawlee-scraping ─────────────────────────────────────────────
  server.tool(
    "skill_crawlee_scraping",
    "Load web scraping context — Crawlee Cloud workflow, actors, runs, results. Call this before scraping tasks.",
    {},
    async () => ({
      content: [{
        type: "text" as const,
        text: `# Crawlee Cloud Scraping Context

## Workflow
1. crawlee_list_actors → get actor IDs
2. crawlee_run_actor (actorId, input JSON) → runId
3. crawlee_get_run (runId) → poll status
4. crawlee_get_results (runId) → scraped items
5. crawlee_abort_run (runId) → stop if needed

## Input Schema
\`\`\`json
{ "startUrls": [{ "url": "..." }], "maxCrawlPages": 100, "maxConcurrency": 5 }
\`\`\`

## Tips
- Always list actors first — don't guess IDs
- Start with low maxCrawlPages
- Check logs on failure`,
      }],
    })
  );
}
