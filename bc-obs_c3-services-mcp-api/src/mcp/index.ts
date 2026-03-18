#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";
import { registerMatomoTools } from "./tools/matomo.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerRadicaleTools } from "./tools/radicale.js";
import { registerProxiedTools } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[c3-services] ${msg}\n`);

async function main() {
  const server = new McpServer({
    name: "c3-services",
    version: "1.1.0",
  });

  registerRegistryTools(server);    // 3: list, info, spec
  registerProxyTools(server);       // 1: generic proxy
  registerMatomoTools(server);      // 5: visits, sites, actions, referrers, live
  registerSyncthingTools(server);   // 4: status, config, folders, devices
  registerNtfyTools(server);       // 2: publish, health
  registerOllamaTools(server);     // 3: models, generate, chat
  registerRadicaleTools(server);   // 3: calendars, contacts, events

  // Proxy tools from child MCPs (mattermost-mcp, mailu-mcp)
  await registerProxiedTools(server);

  const transport = new StdioServerTransport();
  log("Starting c3-services MCP server v1.1.0...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
