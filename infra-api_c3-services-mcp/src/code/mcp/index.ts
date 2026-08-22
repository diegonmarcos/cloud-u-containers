#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── Meta-tools (8 grouped tools, collapsed from 108 individual) ──────────────
import { registerMetaTools } from "./tools/meta.js";

// ── Ollama (not in meta groups) ──────────────────────────────────────────────
import { registerOllamaTools } from "./tools/ollama.js";

// ── Proxied child MCPs ──────────────────────────────────────────────────────
import { registerProxiedInfraTools, registerProxiedUserTools, startProxyRetryLoop } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[c3-services] ${msg}\n`);

async function main() {
  const server = new McpServer({
    name: "c3-services",
    version: "2.2.0",
  });

  registerMetaTools(server);           //  8 meta-tools (collapsed from 108)
  registerOllamaTools(server);         //  3: models, generate, chat
  await registerProxiedInfraTools(server); // cloud-cgc-pub-mcp (code graph, cloud knowledge)
  await registerProxiedUserTools(server); // mattermost-mcp, mail-mcp, google-workspace-mcp

  const transport = new StdioServerTransport();
  log("Starting c3-services MCP server v2.2.0 (8 meta-tools + ollama + proxied)...");
  await server.connect(transport);
  log("Connected via stdio transport");

  // Background retry for child MCPs that failed initial connect
  startProxyRetryLoop(server);
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
