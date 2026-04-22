#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// ═══════════════════════════════════════════════════════════════════
// 1) obs.health.* — Health checks (cloud, mail, tier1/2/3, alive, declared, deployed, drift, endpoints, resources)
// ═══════════════════════════════════════════════════════════════════
import { registerHealthCloudTools } from "./tools/health_cloud.js";             // obs.health.cloud*, resources*    (5)
import { registerHealthMailTools } from "./tools/health_mail.js";               // obs.health.mail*                 (5)
import { registerObservabilityReadTools } from "./tools/observability-read.js"; // obs.health.* (10) + obs.debug.* (15)

// ═══════════════════════════════════════════════════════════════════
// 2) obs.debug.* — Log aggregator (VPS CLIs, VM diagnostics, docker logs, profiles, tests, DB)
// ═══════════════════════════════════════════════════════════════════
import { registerVpsOpsTools } from "./tools/vps-ops.js";                      // obs.debug.vps_*                  (7)
// NOTE: obs.debug.docker_logs* (3) are in operations.ts alongside devops.docker.*
// NOTE: obs.debug.metrics/profile/vm/test/report/db (15) are in observability-read.ts

// ═══════════════════════════════════════════════════════════════════
// 3) devops.build.* — Build/ship/deploy pipeline
// ═══════════════════════════════════════════════════════════════════
import { registerDeliveryTools } from "./tools/delivery.js";                   // devops.build.*                   (6)

// ═══════════════════════════════════════════════════════════════════
// 4) devops.docker/ssh/vm/container/service.* — Container & lifecycle ops
// ═══════════════════════════════════════════════════════════════════
import { registerOperationsTools } from "./tools/operations.js";               // devops.docker/ssh/vm/container/service.* (22)

// ═══════════════════════════════════════════════════════════════════
// 5) devops.workflows.* — GHA + Dagu
// ═══════════════════════════════════════════════════════════════════
import { registerWorkflowTools } from "./tools/workflows.js";                  // devops.workflows.*               (10)

// ═══════════════════════════════════════════════════════════════════
// 6) obs.finops.* — Cloud cost tracking & resource analysis
// ═══════════════════════════════════════════════════════════════════
import { registerFinOpsTools } from "./tools/finops.js";                       // obs.finops.all/vps/services/assets (4)
import { registerFinOpsCloudTools } from "./tools/finops-cloud.js";            // obs.finops.oci/gcp/aws/cloud_summary (10)

// ═══════════════════════════════════════════════════════════════════
// 7) obs.notify.* + obs.db.* — Alerting & alert DB
// ═══════════════════════════════════════════════════════════════════
import { registerObservabilityExecTools } from "./tools/observability.js";     // obs.notify/db.*                  (8)

// ═══════════════════════════════════════════════════════════════════
// 8) sec.* — Security scanning & auditing
// ═══════════════════════════════════════════════════════════════════
import { registerSecurityExecTools } from "./tools/security.js";               // sec.*                            (7)

// ═══════════════════════════════════════════════════════════════════
// 9) devops.front.* — Front-end monorepo ops
// ═══════════════════════════════════════════════════════════════════
import { registerFrontendExecTools } from "./tools/frontend.js";               // devops.front.*                   (3)

// ── Resources ────────────────────────────────────
import { registerResources } from "./resources/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "6.0.0",
});

// ═══════════════════════════════════════════════════════════════════
// 1) obs.health.* — Health checks
// ═══════════════════════════════════════════════════════════════════
registerHealthCloudTools(server);                                               // (5)  obs.health.cloud*, resources*
registerHealthMailTools(server);                                                // (5)  obs.health.mail*
registerObservabilityReadTools(server);                                         // (25) obs.health.* (10) + obs.debug.* (15)

// ═══════════════════════════════════════════════════════════════════
// 2) obs.debug.* — Log aggregator & diagnostics
// ═══════════════════════════════════════════════════════════════════
registerVpsOpsTools(server);                                                    // (7)  obs.debug.vps_*

// ═══════════════════════════════════════════════════════════════════
// 3) devops.build.* — Build pipeline
// ═══════════════════════════════════════════════════════════════════
registerDeliveryTools(server);                                                  // (6)  devops.build.*

// ═══════════════════════════════════════════════════════════════════
// 4) devops.docker/ssh/vm/container/service.* — Container & lifecycle
// ═══════════════════════════════════════════════════════════════════
registerOperationsTools(server);                                                // (25) devops.docker/ssh/* + obs.debug.docker_logs* (3)

// ═══════════════════════════════════════════════════════════════════
// 5) devops.workflows.* — GHA + Dagu
// ═══════════════════════════════════════════════════════════════════
registerWorkflowTools(server);                                                  // (10) devops.workflows.*

// ═══════════════════════════════════════════════════════════════════
// 6) obs.finops.* — Cost tracking
// ═══════════════════════════════════════════════════════════════════
registerFinOpsTools(server);                                                    // (4)  obs.finops.all/vps/services/assets
registerFinOpsCloudTools(server);                                               // (10) obs.finops.oci/gcp/aws/cloud_summary

// ═══════════════════════════════════════════════════════════════════
// 7) obs.notify.* + obs.db.* — Alerting
// ═══════════════════════════════════════════════════════════════════
registerObservabilityExecTools(server);                                         // (8)  obs.notify/db.*

// ═══════════════════════════════════════════════════════════════════
// 8) sec.* — Security
// ═══════════════════════════════════════════════════════════════════
registerSecurityExecTools(server);                                              // (7)  sec.*

// ═══════════════════════════════════════════════════════════════════
// 9) devops.front.* — Frontend
// ═══════════════════════════════════════════════════════════════════
registerFrontendExecTools(server);                                              // (3)  devops.front.*

// ── Resources (9) ────────────────────────────────
registerResources(server);                                                      //      cloud:// resources

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v6.0.0 (all 115 tools enabled, dot-separated categories)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
