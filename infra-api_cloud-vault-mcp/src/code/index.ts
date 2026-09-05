#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerMetaTool } from "./tools/meta.js";

const log = (msg: string) => process.stderr.write(`[cloud-vault-mcp] ${msg}\n`);

async function main(): Promise<void> {
  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || process.env.PORT || "3111", 10);
    await startMcpHttpServer(port);
    return;
  }

  const server = new McpServer({ name: "cloud-vault-mcp", version: "1.0.0" });
  registerMetaTool(server);
  await server.connect(new StdioServerTransport());
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
