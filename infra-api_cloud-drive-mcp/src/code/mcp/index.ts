#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerDriveTool } from "./tools/drive.js";

const log = (msg: string) => process.stderr.write(`[cloud-drive-mcp] ${msg}\n`);

async function main(): Promise<void> {
  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || process.env.PORT || "3109", 10);
    await startMcpHttpServer(port);
    return;
  }

  const server = new McpServer({ name: "cloud-drive-mcp", version: "1.0.0" });
  registerDriveTool(server);
  await server.connect(new StdioServerTransport());
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
