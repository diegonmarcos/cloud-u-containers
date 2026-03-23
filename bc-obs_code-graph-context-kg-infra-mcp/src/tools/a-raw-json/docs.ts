/**
 * Docs tools — expose cloud-spec documentation + dynamic context summaries.
 * Reads the mdBook source files for service documentation.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { getRepoRoot } from "../../config.js";
import { buildContextSummary } from "../../context.js";

function getCloudSpecDir(): string {
  return join(getRepoRoot(), "a_solutions", "bc-obs_cloud-spec");
}

export function registerDocsTools(server: McpServer) {

  // ── Cloud Docs Overview ─────────────────────────────────────────────
  server.tool(
    "c3_docs_overview",
    "Get the cloud documentation portal overview — architecture, VMs, service categories, how the docs portal works.",
    {},
    async () => {
      const overviewPath = join(getCloudSpecDir(), "src", "docs", "overview.md");
      if (!existsSync(overviewPath)) {
        return { content: [{ type: "text" as const, text: "cloud-spec overview.md not found" }] };
      }

      const summaryPath = join(getCloudSpecDir(), "src", "docs", "SUMMARY.md");
      const overview = readFileSync(overviewPath, "utf-8");
      const summary = existsSync(summaryPath) ? readFileSync(summaryPath, "utf-8") : "";

      return {
        content: [{
          type: "text" as const,
          text: `${overview}\n\n---\n\n# Documentation Index\n\n${summary}`,
        }],
      };
    }
  );

  // ── Service Documentation ───────────────────────────────────────────
  server.tool(
    "c3_docs_service",
    "Get a specific service's generated documentation (spec page from mdBook build). Shows all configured values from flake.nix.",
    { service: z.string().describe("Service folder name (e.g. 'bb-sec_caddy', 'aa-sui_photoprism')") },
    async ({ service }) => {
      // Check for docs in the service's own dist/docs or the cloud-spec dist
      const specDistDir = join(getCloudSpecDir(), "dist", "services", service);
      const serviceDistDir = join(getRepoRoot(), "a_solutions", service, "dist", "docs");

      // Try cloud-spec aggregated docs first
      if (existsSync(specDistDir)) {
        const indexPath = join(specDistDir, "index.html");
        if (existsSync(indexPath)) {
          return {
            content: [{
              type: "text" as const,
              text: `Service docs available at cloud-spec dist: ${specDistDir}\nUse read_file to inspect specific files, or check the live docs at cloud.diegonmarcos.com/docs`,
            }],
          };
        }
      }

      // Fall back to reading the service's flake.nix config block + any docs/ folder
      const solDir = join(getRepoRoot(), "a_solutions", service);
      if (!existsSync(solDir)) {
        return { content: [{ type: "text" as const, text: `Service folder "${service}" not found.` }] };
      }

      const parts: string[] = [`# ${service} Documentation\n`];

      // build.json
      const bjPath = join(solDir, "build.json");
      if (existsSync(bjPath)) {
        parts.push(`## build.json\n\`\`\`json\n${readFileSync(bjPath, "utf-8")}\`\`\`\n`);
      }

      // Narrative docs (src/docs/*.md)
      const docsDir = join(solDir, "src", "docs");
      if (existsSync(docsDir)) {
        try {
          const mdFiles = readdirSync(docsDir).filter(f => f.endsWith(".md"));
          for (const f of mdFiles) {
            const content = readFileSync(join(docsDir, f), "utf-8");
            parts.push(`## ${f}\n${content}\n`);
          }
        } catch { /* no-op */ }
      }

      // flake.nix config block (first 40 lines)
      const flakePath = join(solDir, "src", "flake.nix");
      if (existsSync(flakePath)) {
        const lines = readFileSync(flakePath, "utf-8").split("\n").slice(0, 40);
        parts.push(`## flake.nix (config)\n\`\`\`nix\n${lines.join("\n")}\n\`\`\`\n`);
      }

      return { content: [{ type: "text" as const, text: parts.join("\n") }] };
    }
  );

  // ── Cloud README ────────────────────────────────────────────────────
  server.tool(
    "c3_readme",
    "Get the cloud repo README.md — full infrastructure documentation, build system spec, service structure, deployment guide.",
    {},
    async () => {
      const readmePath = join(getRepoRoot(), "README.md");
      if (!existsSync(readmePath)) {
        return { content: [{ type: "text" as const, text: "README.md not found" }] };
      }
      return { content: [{ type: "text" as const, text: readFileSync(readmePath, "utf-8") }] };
    }
  );

  // ── Cloud Context ─────────────────────────────────────────────────
  server.tool(
    "cloud_context",
    "Get a dynamic infrastructure context summary. 'compact' (~10k tokens): VM table, services, architecture, tool index. 'full' (~50k tokens): everything + topology.md, configs.md, README, deps.",
    { size: z.enum(["compact", "full"]).describe("Summary size: 'compact' or 'full'") },
    async ({ size }) => ({
      content: [{ type: "text" as const, text: buildContextSummary(size) }],
    })
  );
}
