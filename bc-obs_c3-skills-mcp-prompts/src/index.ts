#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerPrompts } from "./prompts/index.js";

const server = new McpServer({
  name: "cloud-skills",
  version: "1.0.0",
});

registerPrompts(server);

const log = (msg: string) => process.stderr.write(`[cloud-skills] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-skills MCP server v1.0.0 (4 prompts)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
