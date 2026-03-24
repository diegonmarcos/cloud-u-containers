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
import { registerFinOpsTools } from "./tools/finops.js";
import { registerWorkflowTools } from "./tools/workflows.js";
import { registerVpsOpsTools } from "./tools/vps-ops.js";
import { registerHealthMailTools } from "./tools/health_mail.js";
import { registerHealthCloudTools } from "./tools/health_cloud.js";

// ── READ tools (moved from cloud-cgc-mcp) ────────
import { registerObservabilityReadTools } from "./tools/observability-read.js";
import { registerFinOpsCloudTools } from "./tools/finops-cloud.js";
import { registerResources } from "./resources/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "5.0.0",
});

// Register all exec tools (READ tools moved to cloud-cgc-mcp)

// ── DevOps ───────────────────────────────────────
registerDeliveryTools(server);           //  6: devops-build_*, devops-secrets_*, devops-backup_*
registerOperationsTools(server);         // 28: devops-ssh_*, devops-docker_*, devops-vm_*, devops-container_*, devops-service_*
registerObservabilityExecTools(server);  //  8: devops-notify_*, devops-db_*
registerSecurityExecTools(server);       //  7: security*, cloud-data-security_*

// ── Extensions ───────────────────────────────────
registerFrontendExecTools(server);       //  3: front-*
registerFinOpsTools(server);             //  4: fin_ops*
registerWorkflowTools(server);           //  9: workflows*
registerVpsOpsTools(server);             //  7: vps_*
registerHealthMailTools(server);         //  5: health_mail*
registerHealthCloudTools(server);        //  5: health_cloud*, cloud_resources*

// ── READ tools (moved from cloud-cgc-mcp) ────────
registerObservabilityReadTools(server);  // 24: health, profiling, tests, reports, DB reads
registerFinOpsCloudTools(server);        // 10: OCI/GCP/AWS instances, resources, costs
registerResources(server);               // 11: cloud:// resources + templates

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v5.0.0 (exec + READ tools consolidated)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
