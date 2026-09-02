#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";

const server = new McpServer({ name: "cloud-superapp-mcp", version: "1.0.0" });
registerTools(server);

const log = (msg: string) => process.stderr.write(`[cloud-superapp-mcp] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log(`Starting cloud-superapp-mcp v1.0.0 (stdio, hosts=${process.env.SUPERAPP_HOSTS ?? "phone,phone-v6,phone-pub"})`);
  if (!process.env.SUPERAPP_FLEET_TOKEN) {
    log("SUPERAPP_FLEET_TOKEN unset — discovery works, data routes will answer 401 (SuperApp → Configs → About)");
  }
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
