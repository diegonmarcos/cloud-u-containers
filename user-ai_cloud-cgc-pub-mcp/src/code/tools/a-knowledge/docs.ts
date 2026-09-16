/**
 * Docs tools — expose cloud-spec documentation + dynamic context summaries.
 * Reads the mdBook source files for service documentation.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { getConfig } from "../../config.js";
import { getContainersRoot, getRepoDir } from "../../shared/libs/paths.js";
import { buildContextSummary } from "../../context.js";

function getCloudSpecDir(): string {
  // "bc-obs_cloud-spec" was a literal here and is pre-rename — that directory
  // does not exist. cloud-spec is declared at infra-obs_cloud-spec, so every
  // docs lookup was reading from a path that resolves to nothing.
  const declared = getConfig().services["cloud-spec"]?.folder;
  if (!declared) {
    throw new Error("cloud-spec has no declared folder in the infrastructure declaration; refusing to guess a directory name");
  }
  // Previously joined the service folder onto the config module's repo-root
  // helper, which resolves to /data — the empty ./data deploy bind in the
  // image — so docs landed nowhere. a_solutions IS the cloud-u-containers
  // checkout: resolve on the container source tree under $GIT_ROOT instead
  // (Ticket #402).
  return join(getContainersRoot(), declared);
}

export function registerDocsTools(server: McpServer) {

  server.tool(
    "knowledge.docs",
    "Get cloud documentation. Methods: overview (docs portal overview), readme (cloud repo README), service (service spec page, requires name param), context (infra context summary, requires size param)",
    {
      method: z.enum(["overview", "readme", "service", "context"]),
      name: z.string().optional().describe("Service name (for service method)"),
      size: z.enum(["compact", "full"]).optional().describe("Context size (for context method)"),
    },
    async ({ method, name, size }) => {
      switch (method) {

        case "overview": {
          const overviewPath = join(getCloudSpecDir(), "src", "docs", "overview.md");
          if (!existsSync(overviewPath)) {
            return { content: [{ type: "text" as const, text: "cloud-spec overview.md not found" }], isError: true };
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

        case "readme": {
          // The cloud (infrastructure) repo README. Previously anchored on the config
          // module's repo-root helper (/data), which carries no repository in the
          // image. Resolve the cloud-infra checkout under $GIT_ROOT (Ticket #402).
          const readmePath = join(getRepoDir("cloud-infra"), "README.md");
          if (!existsSync(readmePath)) {
            return { content: [{ type: "text" as const, text: "README.md not found" }], isError: true };
          }
          return { content: [{ type: "text" as const, text: readFileSync(readmePath, "utf-8") }] };
        }

        case "service": {
          const service = name;
          if (!service) {
            return { content: [{ type: "text" as const, text: "name param required for service method" }] };
          }

          // Check for docs in the service's own dist/docs or the cloud-spec dist
          const specDistDir = join(getCloudSpecDir(), "dist", "services", service);
          const serviceDistDir = join(getContainersRoot(), service, "dist", "docs");

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
          const solDir = join(getContainersRoot(), service);
          if (!existsSync(solDir)) {
            return { content: [{ type: "text" as const, text: `Service folder "${service}" not found.` }], isError: true };
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

        case "context": {
          if (!size) {
            return { content: [{ type: "text" as const, text: "size param required for context method" }] };
          }
          return {
            content: [{ type: "text" as const, text: buildContextSummary(size) }],
          };
        }
      }
    }
  );
}
