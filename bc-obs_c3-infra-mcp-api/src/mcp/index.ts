#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── 6 Pillars ────────────────────────────────────
import { registerInventoryTools } from "./tools/inventory.js";
import { registerDeliveryTools } from "./tools/delivery.js";
import { registerOperationsTools } from "./tools/operations.js";
import { registerObservabilityTools } from "./tools/observability.js";
import { registerSecurityTools } from "./tools/security.js";
import { registerFinOpsTools } from "./tools/finops.js";

// ── Extensions ───────────────────────────────────
import { registerFrontendTools } from "./tools/frontend.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerMattermostTools } from "./tools/health_mattermost.js";
import { registerHealthMailuTools } from "./tools/health_mailu.js";

import { registerResources } from "./resources/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "3.2.0",
});

// Register all tools (120+ total — comprehensive C3 Cloud Control Center)

// ── 6 Pillars ────────────────────────────────────
registerInventoryTools(server);      // 21: config, topology, discovery, repos, files
registerDeliveryTools(server);       //  6: build, ship, docker build, secrets, backup
registerOperationsTools(server);     // 26: SSH, Docker ops, VM/container/service lifecycle
registerObservabilityTools(server);  // 33: health, profiling, diagnostics, tests, alerts, DB
registerSecurityTools(server);       //  6: scan, docker audit, SSH keys, tokens, topology
registerFinOpsTools(server);         //  7: OCI + GCP instances, resources, costs

// ── Extensions ───────────────────────────────────
registerFrontendTools(server);       //  5: front-end monorepo build/dev/deploy
registerCrawleeTools(server);        //  7: web scraping actors/runs/results
registerMattermostTools(server);     //  8: chat read/write/react for agentic bot
registerHealthMailuTools(server);    //  5: mail UP, profiling, inbound/outbound tests, full pipeline

// Register resources (7 static + 2 templates = 9 total)
registerResources(server);             // cloud://config, ssh-config, services-overview, readme, front-projects, c3-api-endpoints, service-apis + templates: services/{name}, vms/{vm_id}

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v3.2.0 (120+ tools, 9 resources)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
