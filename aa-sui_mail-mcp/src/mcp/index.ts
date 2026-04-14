#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerInboxTools } from "./tools/inbox.js";
import { registerComposeTools } from "./tools/compose.js";
import { registerAdminTools } from "./tools/admin.js";
import { registerResendTools } from "./tools/resend.js";
import { registerDebugTools } from "./tools/debug.js";

const log = (msg: string) => process.stderr.write(`[mail-mcp] ${msg}\n`);

async function main() {
  if (!process.env.MAIL_USER || !process.env.MAIL_PASSWORD) {
    log("ERROR: MAIL_USER and MAIL_PASSWORD environment variables are required");
    process.exit(1);
  }

  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || "3103", 10);
    await startMcpHttpServer(port);
  } else {
    const server = new McpServer({
      name: "mail-mcp",
      version: "1.3.0",
    });
    registerInboxTools(server);
    registerComposeTools(server);
    registerAdminTools(server);
    registerResendTools(server);
    registerDebugTools(server);
    const transport = new StdioServerTransport();
    log("Starting mail-mcp v1.3.0 (25 tools: 10 inbox, 3 compose, 2 admin, 7 resend, 3 debug)...");
    await server.connect(transport);
    log("Connected via stdio transport");
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
