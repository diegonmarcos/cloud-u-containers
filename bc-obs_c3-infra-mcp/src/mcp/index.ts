#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ═══════════════════════════════════════════════════════════════════
// A) OBSERVABILITY — health, finops, resources, notify/alerts
// ═══════════════════════════════════════════════════════════════════
import { registerHealthCloudTools } from "./tools/health_cloud.js";       // A.1 Health (cloud)
import { registerHealthMailTools } from "./tools/health_mail.js";         // A.1 Health (mail)
import { registerObservabilityReadTools } from "./tools/observability-read.js"; // A.2 Cloud Data
import { registerFinOpsTools } from "./tools/finops.js";                  // A.4 FinOps
import { registerFinOpsCloudTools } from "./tools/finops-cloud.js";       // A.4 FinOps Cloud
import { registerObservabilityExecTools } from "./tools/observability.js"; // A.5 Notify/Alerts

// ═══════════════════════════════════════════════════════════════════
// B) DEVOPS — workflows, vps, build/ship, containers, db, frontend
// ═══════════════════════════════════════════════════════════════════
import { registerWorkflowTools } from "./tools/workflows.js";            // B.1 Workflows
import { registerVpsOpsTools } from "./tools/vps-ops.js";                // B.2 VPS Ops
import { registerDeliveryTools } from "./tools/delivery.js";             // B.3 Build Ship System
import { registerOperationsTools } from "./tools/operations.js";         // B.4 Container Management
import { registerFrontendExecTools } from "./tools/frontend.js";         // B.6 Front-End

// ═══════════════════════════════════════════════════════════════════
// C) SECURITY
// ═══════════════════════════════════════════════════════════════════
import { registerSecurityExecTools } from "./tools/security.js";         // C.1 Security

// ── Resources ────────────────────────────────────
import { registerResources } from "./resources/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "5.0.0",
});

// ═══════════════════════════════════════════════════════════════════
// A) OBSERVABILITY (53 tools)
// ═══════════════════════════════════════════════════════════════════
registerHealthCloudTools(server);        //  A.1  health_cloud*, cloud_resources*     (5)
registerHealthMailTools(server);         //  A.1  health_mail*                        (5)
registerObservabilityReadTools(server);  //  A.2  cloud-data-health/profile/vm/db*   (24)
registerFinOpsTools(server);             //  A.4  fin_ops*                            (4)
registerFinOpsCloudTools(server);        //  A.4  cloud-data-oci/gcp/aws*            (10)
registerObservabilityExecTools(server);  //  A.5  devops-notify_*, devops-db_*        (8)

// ═══════════════════════════════════════════════════════════════════
// B) DEVOPS (55 tools)
// ═══════════════════════════════════════════════════════════════════
registerWorkflowTools(server);           //  B.1  workflows*                          (9)
registerVpsOpsTools(server);             //  B.2  vps_*                               (7)
registerDeliveryTools(server);           //  B.3  devops-build/secrets/backup*        (7)
registerOperationsTools(server);         //  B.4  devops-ssh/docker/container/vm*    (27)
registerFrontendExecTools(server);       //  B.6  front-*                             (3)

// ═══════════════════════════════════════════════════════════════════
// C) SECURITY (7 tools)
// ═══════════════════════════════════════════════════════════════════
registerSecurityExecTools(server);       //  C.1  security*, cloud-data-security*     (7)

// ── Resources (9) ────────────────────────────────
registerResources(server);               //       cloud:// resources

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
