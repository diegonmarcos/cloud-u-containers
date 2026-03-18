#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerVaultTools } from "./tools/vault.js";
import { registerIdentityTools } from "./tools/identity.js";
import { registerCommsTools } from "./tools/comms.js";
import { registerMediaTools } from "./tools/media.js";
import { registerFinanceTools } from "./tools/finance.js";
import { registerHealthTools } from "./tools/health.js";

const server = new McpServer({
  name: "diego-personal-data",
  version: "1.0.0",
});

// Vault — passwords metadata, 2FA status, keys, providers (READ-ONLY, redacted)
registerVaultTools(server);

// Identity — CV, ID docs, family history
registerIdentityTools(server);

// Comms — email proxy, WhatsApp (TBD), notes (TBD)
registerCommsTools(server);

// Media — photos metadata, git repos index
registerMediaTools(server);

// Finance — payment cards metadata, financial data
registerFinanceTools(server);

// Health — health tracking data (TBD)
registerHealthTools(server);

const log = (msg: string) => process.stderr.write(`[diego-personal-data] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting diego-personal-data MCP server v1.0.0 (stdio, READ-ONLY)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
