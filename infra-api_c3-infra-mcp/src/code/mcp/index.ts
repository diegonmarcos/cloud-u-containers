#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ── 4 grouped meta-tools (replaces 105 individual tools) ──
import { registerMetaDevops, registerMetaObs, registerMetaFinops, registerMetaSec } from "./tools/meta.js";

// ── Resources ────────────────────────────────────
import { registerResources } from "./resources/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "7.0.0",
});

registerMetaDevops(server);  // infra.devops  — build/docker/vm/container/service/front/workflows
registerMetaObs(server);     // infra.obs     — debug/docker-logs/vps-cli/profiles/vm-diag/db
registerMetaFinops(server);  // infra.finops  — finops/health/notify
registerMetaSec(server);     // infra.sec     — security scanning & auditing

// ── Resources (9) ────────────────────────────────
registerResources(server);   //      cloud:// resources

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v7.0.0 (4 grouped meta-tools: infra.devops/obs/finops/sec)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
