/**
 * Specs tools — interpreted infrastructure knowledge.
 * These compute views from config rather than serving raw files.
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

function getSolutionsDir(): string {
  return join(getRepoRoot(), "a_solutions");
}

export function registerSpecTools(server: McpServer) {

  server.tool(
    "knowledge.spec.service",
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

  server.tool(
    "knowledge.spec.vm",
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

  server.tool(
    "knowledge.spec.services_by_category",
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
