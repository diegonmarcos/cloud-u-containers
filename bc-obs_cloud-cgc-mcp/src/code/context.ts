/**
 * Shared context builder — generates infrastructure summaries for MCP resources and tools.
 * Used by cloud_context tool (docs.ts) and MCP resources (index.ts).
 */
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getConfig, getVmSshAlias, getRepoRoot, getCloudDataPath } from "./config.js";

function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

function buildVmTable(): string {
  const config = getConfig();
  const header = `| VM ID | Alias | IP | WG IP | User | Description |\n|-------|-------|----|-------|------|-------------|`;
  const rows = Object.entries(config.vms)
    .map(([id, vm]) => `| ${id} | ${getVmSshAlias(id)} | ${vm.ip} | ${vm.wg_ip ?? "" } | ${vm.user} | ${vm.description ?? ""} |`)
    .join("\n");
  return `## VMs (${Object.keys(config.vms).length})\n\n${header}\n${rows}`;
}

function buildServiceTable(): string {
  const config = getConfig();
  const categories = new Map<string, string[]>();
  for (const [name, svc] of Object.entries(config.services)) {
    const cat = svc.category;
    if (!categories.has(cat)) categories.set(cat, []);
    const domain = svc.domain ? ` → ${svc.domain}` : "";
    categories.get(cat)!.push(`${name} (${getVmSshAlias(svc.vm)})${domain}`);
  }
  const rows = [...categories.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([cat, svcs]) => `### ${cat}\n${svcs.map(s => `- ${s}`).join("\n")}`)
    .join("\n\n");
  return `## Services (${Object.keys(config.services).length})\n\n${rows}`;
}

function buildArchitectureSummary(): string {
  return `## Architecture
- Nix flakes → Docker Compose stacks, _cloud-data-consolidated.json is source of truth
- Per-service build.sh: build → secrets (sops) → deploy (rsync) → compose
- WireGuard mesh 10.0.0.0/24 connects all VMs
- GCP proxy (gcp-E2-f_0): Caddy + Authelia entry point
- C3 API (api.diegonmarcos.com/c3-api): health, discovery, control, topology, tests, files`;
}

function buildToolIndex(): string {
  return `## Tool Index

### A: Specs (9 tools)
| Tool | Description |
|------|-------------|
| c3_topology | _cloud-data-consolidated.json (top-level) — VMs, services, networking |
| c3_configs | _cloud-data-consolidated.json[.configs] — domains, ports, images, routes |
| c3_deps | _cloud-data-consolidated.json[.deps] — npm dependencies per cloud service |
| c3_topology_md | cloud-topology.md — human-readable topology |
| c3_configs_md | cloud-configs.md — Caddy routes, Authelia clients, DNS |
| c3_deps_front | front-deps.json — front-end project dependencies |
| knowledge_service_spec | Service build.json + flake.nix + topology |
| knowledge_vm_info | VM details — IP, WG IP, services, SSH alias |
| knowledge_services_by_category | All services grouped by category |

### B: Docs (4 tools)
| Tool | Description |
|------|-------------|
| c3_docs_overview | Cloud docs portal overview + index |
| c3_docs_service | Service-specific generated documentation |
| c3_readme | Cloud repo README.md |
| cloud_context | Dynamic infrastructure summary (compact/full) |

### C: Skills (4 tools)
| Tool | Description |
|------|-------------|
| skill_cloud_architect | Cloud infrastructure persona context |
| skill_frontend_developer | Front-end development persona context |
| skill_debug_ops | Debugging/ops persona context |
| skill_crawlee_scraping | Web scraping persona context |`;
}

function readFileSafe(path: string): string | null {
  if (!existsSync(path)) return null;
  return readFileSync(path, "utf-8");
}

export function buildContextSummary(size: "compact" | "full"): string {
  const parts: string[] = ["# Cloud Infrastructure Context\n"];

  // Both sizes get these
  parts.push(buildVmTable());
  parts.push(buildServiceTable());
  parts.push(buildArchitectureSummary());
  parts.push(buildToolIndex());

  if (size === "full") {
    const repoRoot = getRepoRoot();

    // Add topology markdown (uses getCloudDataPath for in-image / dist / clone fallback chain)
    const topoMd = readFileSafe(getCloudDataPath("cloud-data-topology.md"));
    if (topoMd) parts.push(`## Full Topology\n\n${topoMd}`);

    // Add configs markdown
    const configsMd = readFileSafe(getCloudDataPath("cloud-data-configs.md"));
    if (configsMd) parts.push(`## Full Configs\n\n${configsMd}`);

    // Add README
    const readme = readFileSafe(join(repoRoot, "README.md"));
    if (readme) parts.push(`## README\n\n${readme}`);

    // Add deps summary
    // 2026-04-27 migrated: cloud-data-deps.json -> _cloud-data-consolidated.json.deps
    const consolidated = readFileSafe(getCloudDataPath("_cloud-data-consolidated.json"));
    if (consolidated) {
      try {
        const parsed = JSON.parse(consolidated);
        const depsRoot = parsed.deps ?? {};
        const serviceCount = Object.keys(depsRoot.services ?? depsRoot).length;
        parts.push(`## Dependencies\n\n${serviceCount} services with npm dependencies tracked.`);
      } catch { /* skip malformed */ }
    }
  }

  const content = parts.join("\n\n");
  const tokens = estimateTokens(content);
  const sizeLabel = size === "compact" ? "compact" : "full";

  return `${content}\n\n---\n_Context size: ${sizeLabel} | ${content.length} chars | ~${tokens} tokens_`;
}
