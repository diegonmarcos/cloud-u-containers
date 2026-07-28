#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerMetaTool } from "./tools/meta.js";

const server = new McpServer({
  name: "diego-personal-data",
  version: "1.0.0",
});

registerMetaTool(server);

const log = (msg: string) => process.stderr.write(`[diego-personal-data] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting diego-personal-data MCP server v1.0.0 (stdio, READ-ONLY)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
