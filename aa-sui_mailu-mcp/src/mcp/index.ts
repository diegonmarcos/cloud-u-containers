#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerInboxTools } from "./tools/inbox.js";
import { registerComposeTools } from "./tools/compose.js";
import { registerAdminTools } from "./tools/admin.js";

const server = new McpServer({
  name: "mailu-mcp",
  version: "1.0.0",
});

registerInboxTools(server);
registerComposeTools(server);
registerAdminTools(server);

const log = (msg: string) => process.stderr.write(`[mailu-mcp] ${msg}\n`);

async function main() {
  if (!process.env.MAIL_USER || !process.env.MAIL_PASSWORD) {
    log("ERROR: MAIL_USER and MAIL_PASSWORD environment variables are required");
    process.exit(1);
  }

  const transport = new StdioServerTransport();
  log("Starting mailu-mcp v1.0.0 (15 tools: 10 inbox, 3 compose, 2 admin)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
