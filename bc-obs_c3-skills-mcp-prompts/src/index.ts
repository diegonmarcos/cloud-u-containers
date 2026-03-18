#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerSkillTools } from "./tools/skills.js";
import { registerKnowledgeTools } from "./tools/knowledge.js";
import { registerDataTools } from "./tools/data.js";
import { registerDocsTools } from "./tools/docs.js";

const server = new McpServer({
  name: "cloud-skills",
  version: "3.0.0",
});

// 4 skill tools — domain personas (architect, frontend, debug, scraping)
registerSkillTools(server);

// 3 knowledge tools — service spec, VM info, category overview
registerKnowledgeTools(server);

// 6 data tools — cloud-topology, cloud-configs, cloud-deps (JSON + MD), front-deps
registerDataTools(server);

// 3 docs tools — cloud-spec overview, service docs, README
registerDocsTools(server);

const log = (msg: string) => process.stderr.write(`[cloud-skills] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-skills MCP server v3.0.0 (16 tools: 4 skills, 3 knowledge, 6 data, 3 docs)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
