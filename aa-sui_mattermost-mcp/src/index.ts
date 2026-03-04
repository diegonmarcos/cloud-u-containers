#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";

const server = new McpServer({
  name: "mattermost",
  version: "1.0.0",
});

registerTools(server);

const log = (msg: string) => process.stderr.write(`[mattermost] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting mattermost MCP server v1.0.0 (5 tools)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
