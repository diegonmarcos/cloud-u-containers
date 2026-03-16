#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";
import { registerMatomoTools } from "./tools/matomo.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerMailuTools } from "./tools/mailu.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerRadicaleTools } from "./tools/radicale.js";

const server = new McpServer({
  name: "c3-services",
  version: "1.0.0",
});

// Register all tools (~24 total)
registerRegistryTools(server);    // 3: list, info, spec
registerProxyTools(server);       // 1: generic proxy
registerMatomoTools(server);      // 5: visits, sites, actions, referrers, live
registerSyncthingTools(server);   // 4: status, config, folders, devices
registerMailuTools(server);       // 3: domains, users, aliases
registerNtfyTools(server);       // 2: publish, health
registerOllamaTools(server);     // 3: models, generate, chat
registerRadicaleTools(server);   // 3: calendars, contacts, events

const log = (msg: string) => process.stderr.write(`[c3-services] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting c3-services MCP server v1.0.0 (24 tools)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
