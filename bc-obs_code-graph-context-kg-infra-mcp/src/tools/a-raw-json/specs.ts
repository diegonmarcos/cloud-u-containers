/**
 * Specs tools — infrastructure data (topology, configs, deps) + knowledge retrieval (service spec, VM info, categories).
 * Merged from data.ts (6 tools) + knowledge.ts (3 tools) = 9 tools.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { getConfig, getVmSshAlias, getRepoRoot } from "../../config.js";

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_", mic: "ab-mic_", fin: "ac-fin_", agi: "ad-agi_",
  cloud: "ba-clo_", sec: "bb-sec_", tools: "bc-obs_", data: "ca-dat_",
};

function readJsonSafe(path: string): unknown {
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, "utf-8"));
}

function getSolutionsDir(): string {
  return join(getRepoRoot(), "a_solutions");
}

export function registerSpecTools(server: McpServer) {

  // ── Cloud Topology ──────────────────────────────────────────────────
  server.tool(
    "cloud-spec-topology",
    "Get cloud-data-topology.json — VMs, services, networking, full infrastructure map. The source of truth for all cloud config.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-data-topology.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-data-topology.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Configs ───────────────────────────────────────────────────
  server.tool(
    "cloud-spec-configs",
    "Get cloud-data-configs.json — generated configuration for all services (domains, ports, images, routes, Caddy/Authelia/DNS config).",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-data-configs.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-data-configs.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Deps ──────────────────────────────────────────────────────
  server.tool(
    "cloud-spec-deps",
    "Get cloud-data-deps.json — npm dependencies for all cloud services (per-service + merged). Shows what packages each service uses.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-data-deps.json");
      const data = readJsonSafe(path);
      if (!data) return { content: [{ type: "text" as const, text: "cloud-data-deps.json not found" }] };
      return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
    }
  );

  // ── Cloud Topology Markdown ─────────────────────────────────────────
  server.tool(
    "cloud-spec-topology_md",
    "Get cloud-data-topology.md — human-readable topology overview with service tables, VM assignments, and networking.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-data-topology.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: "cloud-data-topology.md not found" }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  // ── Cloud Configs Markdown ──────────────────────────────────────────
  server.tool(
    "cloud-spec-configs_md",
    "Get cloud-data-configs.md — human-readable config overview with Caddy routes, Authelia clients, DNS zones.",
    {},
    async () => {
      const path = join(getRepoRoot(), "cloud-data", "cloud-data-configs.md");
      if (!existsSync(path)) return { content: [{ type: "text" as const, text: "cloud-data-configs.md not found" }] };
      return { content: [{ type: "text" as const, text: readFileSync(path, "utf-8") }] };
    }
  );

  // ── Front Deps ──────────────────────────────────────────────────────
  server.tool(
    "front-spec-deps",
    "Get front-deps.json — npm dependencies for all front-end projects (per-project + merged).",
    {},
    async () => {
      const candidates = [
        join(getRepoRoot(), "front-data", "front-deps.json"),
        process.env.FRONT_DATA_PATH ? join(process.env.FRONT_DATA_PATH, "front-deps.json") : "",
      ].filter(Boolean);

      for (const path of candidates) {
        if (existsSync(path)) {
          const content = readFileSync(path, "utf-8").trim();
          if (content) return { content: [{ type: "text" as const, text: content }] };
        }
      }
      return { content: [{ type: "text" as const, text: "front-deps.json not found or empty" }] };
    }
  );

  // ── Service spec lookup ─────────────────────────────────────────────
  server.tool(
    "cloud-spec-service",
    "Get a service's build.json + flake.nix config + topology entry. Use before modifying or debugging a specific service.",
    { name: z.string().describe("Service name (e.g. 'caddy', 'mailu', 'c3-infra-mcp-api')") },
    async ({ name }) => {
      const config = getConfig();
      const svc = config.services[name];
      const solDir = getSolutionsDir();

      let folder = "";
      if (svc?.folder) {
        folder = svc.folder;
      } else {
        const prefix = svc ? (CATEGORY_PREFIX[svc.category] ?? "") : "";
        const candidate = `${prefix}${svc?.flake ?? name}`;
        if (existsSync(join(solDir, candidate))) {
          folder = candidate;
        } else {
          try {
            for (const d of readdirSync(solDir, { withFileTypes: true })) {
              if (!d.isDirectory()) continue;
              const bjPath = join(solDir, d.name, "build.json");
              if (!existsSync(bjPath)) continue;
              try {
                const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
                if (bj.name === name) { folder = d.name; break; }
              } catch { continue; }
            }
          } catch { /* no-op */ }
        }
      }

      if (!folder) {
        return { content: [{ type: "text" as const, text: `Service "${name}" not found.` }] };
      }

      const parts: string[] = [`# Service: ${name}\n`];

      const bjPath = join(solDir, folder, "build.json");
      if (existsSync(bjPath)) {
        parts.push(`## build.json\n\`\`\`json\n${readFileSync(bjPath, "utf-8")}\`\`\`\n`);
      }

      if (svc) {
        parts.push(`## Topology\n- **VM**: ${svc.vm} (${getVmSshAlias(svc.vm)})\n- **Category**: ${svc.category}\n- **Domain**: ${svc.domain ?? "none"}\n- **Containers**: ${svc.containers?.join(", ") ?? "auto"}\n`);
      }

      const flakePath = join(solDir, folder, "src", "flake.nix");
      if (existsSync(flakePath)) {
        const lines = readFileSync(flakePath, "utf-8").split("\n").slice(0, 30);
        parts.push(`## flake.nix (config)\n\`\`\`nix\n${lines.join("\n")}\n\`\`\`\n`);
      }

      return { content: [{ type: "text" as const, text: parts.join("\n") }] };
    }
  );

  // ── VM info lookup ──────────────────────────────────────────────────
  server.tool(
    "cloud-spec-vm",
    "Get VM details — IP, WG IP, services, SSH alias. Use before VM-specific operations.",
    { vm: z.string().describe("VM ID (e.g. 'oci-A1-f_0') or SSH alias (e.g. 'oci-apps')") },
    async ({ vm }) => {
      const config = getConfig();

      let vmId = vm;
      if (!config.vms[vm]) {
        for (const [id, v] of Object.entries(config.vms)) {
          if (v.ssh_alias === vm || getVmSshAlias(id) === vm) {
            vmId = id; break;
          }
        }
      }

      const vmConfig = config.vms[vmId];
      if (!vmConfig) {
        return { content: [{ type: "text" as const, text: `VM "${vm}" not found.` }] };
      }

      const services = Object.entries(config.services)
        .filter(([, s]) => s.vm === vmId)
        .map(([name, s]) => `- **${name}** (${s.category}) — ${s.domain ?? "no domain"}`)
        .join("\n");

      return {
        content: [{
          type: "text" as const,
          text: `# VM: ${vmId} (${getVmSshAlias(vmId)})
- **IP**: ${vmConfig.ip}
- **WireGuard**: ${vmConfig.wg_ip ?? "n/a"}
- **User**: ${vmConfig.user}
- **Description**: ${vmConfig.description ?? ""}
- **SSH**: \`ssh ${getVmSshAlias(vmId)}\`

## Services
${services || "No services declared."}`,
        }],
      };
    }
  );

  // ── Services by category ────────────────────────────────────────────
  server.tool(
    "cloud-spec-services_by_category",
    "List all services grouped by category with VM and domain. Quick infrastructure overview.",
    {},
    async () => {
      const config = getConfig();
      const categories = new Map<string, string[]>();

      for (const [name, svc] of Object.entries(config.services)) {
        const cat = svc.category;
        if (!categories.has(cat)) categories.set(cat, []);
        const domain = svc.domain ? ` → ${svc.domain}` : "";
        categories.get(cat)!.push(`${name} (${getVmSshAlias(svc.vm)})${domain}`);
      }

      const text = [...categories.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([cat, svcs]) => `## ${cat}\n${svcs.map(s => `- ${s}`).join("\n")}`)
        .join("\n\n");

      return { content: [{ type: "text" as const, text: `# Services (${Object.keys(config.services).length})\n\n${text}` }] };
    }
  );
}
