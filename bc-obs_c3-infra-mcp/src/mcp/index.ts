#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── Pillars (exec-only) ─────────────────────────
import { registerDeliveryTools } from "./tools/delivery.js";
import { registerOperationsTools } from "./tools/operations.js";
import { registerObservabilityExecTools } from "./tools/observability.js";
import { registerSecurityExecTools } from "./tools/security.js";

// ── Extensions ───────────────────────────────────
import { registerFrontendExecTools } from "./tools/frontend.js";
import { registerHealthMailTools } from "./tools/health_mail.js";
import { registerHealthCloudTools } from "./tools/health_cloud.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "4.0.0",
});

// Register all exec tools (READ tools moved to cloud-cgc-mcp)

// ── Pillars ──────────────────────────────────────
registerDeliveryTools(server);           //  6: build, ship, docker build, secrets, backup
registerOperationsTools(server);         // 26: SSH, Docker ops, VM/container/service lifecycle
registerObservabilityExecTools(server);  //  8: notifications, alerts, DB mutations
registerSecurityExecTools(server);       //  4: scan, docker audit, SSH keys, tokens

// ── Extensions ───────────────────────────────────
registerFrontendExecTools(server);       //  3: front-end build/dev/deploy
registerHealthMailTools(server);         //  5: mail UP, profiling, inbound/outbound tests, full pipeline
registerHealthCloudTools(server);        //  2: cloud UP + cloud full 10-layer diagnostic

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v4.0.0 (exec-only, READ tools in cloud-cgc-mcp)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
