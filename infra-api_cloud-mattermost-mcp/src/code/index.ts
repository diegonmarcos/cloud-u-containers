#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerMetaTool } from "./meta.js";

const log = (msg: string) => process.stderr.write(`[mattermost] ${msg}\n`);

async function main() {
  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || "3102", 10);
    await startMcpHttpServer(port);
  } else {
    const server = new McpServer({
      name: "mattermost",
      version: "1.0.0",
    });
    registerMetaTool(server);
    const transport = new StdioServerTransport();
    log("Starting mattermost MCP server v1.0.0 (1 meta-tool, 10 methods)...");
    await server.connect(transport);
    log("Connected via stdio transport");
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
