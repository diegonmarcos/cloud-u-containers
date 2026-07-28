#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerMetaTool } from "./tools/meta.js";
import { registerProxiedMcpTools, startProxyRetryLoop } from "./shared/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[mail-mcp] ${msg}\n`);

async function main() {
  const hasMaddyCreds = process.env.MADDY_ME_USER && process.env.MADDY_ME_PASSWORD;
  const hasLegacyCreds = process.env.MAIL_USER && process.env.MAIL_PASSWORD;
  if (!hasMaddyCreds && !hasLegacyCreds) {
    log("ERROR: Set MADDY_ME_USER/MADDY_ME_PASSWORD or MAIL_USER/MAIL_PASSWORD");
    process.exit(1);
  }

  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || "3103", 10);
    await startMcpHttpServer(port);
  } else {
    const server = new McpServer({
      name: "mail-mcp",
      version: "1.5.0",
    });
    registerMetaTool(server);
    await registerProxiedMcpTools(server);   // google-personal-mcp + future MCPs from build.json
    const transport = new StdioServerTransport();
    log("Starting mail-mcp v1.5.0 (1 meta-tool + proxied MCPs)...");
    await server.connect(transport);
    log("Connected via stdio transport");
    startProxyRetryLoop(server);
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
