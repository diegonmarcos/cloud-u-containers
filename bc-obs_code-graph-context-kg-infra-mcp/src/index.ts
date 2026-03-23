#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerSpecTools } from "./tools/specs.js";
import { registerDocsTools } from "./tools/docs.js";
import { registerSkillTools } from "./tools/skills.js";
import { buildContextSummary } from "./context.js";

const server = new McpServer({
  name: "cloud-specs-docs",
  version: "4.0.0",
});

// ── Resources ─────────────────────────────────────────────────────────
server.resource(
  "context-compact",
  "cloud://context/compact",
  { description: "Compact infrastructure context (~10k tokens) — VM table, service table, architecture, tool index" },
  async () => ({
    contents: [{
      uri: "cloud://context/compact",
      mimeType: "text/markdown",
      text: buildContextSummary("compact"),
    }],
  })
);

server.resource(
  "context-full",
  "cloud://context/full",
  { description: "Full infrastructure context (~50k tokens) — everything from compact + topology.md, configs.md, README, deps" },
  async () => ({
    contents: [{
      uri: "cloud://context/full",
      mimeType: "text/markdown",
      text: buildContextSummary("full"),
    }],
  })
);

// ── Tools ─────────────────────────────────────────────────────────────
// A: Specs — 9 tools (topology, configs, deps, service spec, VM info, categories)
registerSpecTools(server);

// B: Docs — 4 tools (overview, service docs, README, cloud_context)
registerDocsTools(server);

// C: Skills — 4 tools (architect, frontend, debug, scraping)
registerSkillTools(server);

const log = (msg: string) => process.stderr.write(`[cloud-specs-docs] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-specs-docs MCP server v4.0.0 (17 tools, 2 resources: 9 specs, 4 docs, 4 skills)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
