#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerSkillTools } from "./tools/skills.js";
import { registerKnowledgeTools } from "./tools/knowledge.js";

const server = new McpServer({
  name: "cloud-skills",
  version: "2.0.0",
});

registerSkillTools(server);
registerKnowledgeTools(server);

const log = (msg: string) => process.stderr.write(`[cloud-skills] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-skills MCP server v2.0.0 (skill tools + knowledge retrieval)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
