#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerInfraTools } from "./tools/infra.js";
import { registerRepoTools } from "./tools/repo.js";
import { registerBuildTools } from "./tools/build.js";
import { registerSshTools } from "./tools/ssh-tools.js";
import { registerDockerTools } from "./tools/docker.js";
import { registerNativeOpsTools } from "./tools/native-ops.js";
import { registerHealthTools } from "./tools/health.js";
import { registerControlTools } from "./tools/control.js";
import { registerCloudTools } from "./tools/cloud.js";
import { registerDiscoveryTools } from "./tools/discovery.js";
import { registerFrontTools } from "./tools/front.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerC3Tools } from "./tools/c3.js";
import { registerSecurityTools } from "./tools/security.js";
import { registerNotifyTools } from "./tools/notify.js";
import { registerDatabaseTools } from "./tools/database.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "3.0.0",
});

// Register all tools (115+ total — comprehensive C3 Cloud Control Center)
registerInfraTools(server);            //  4: list_vms, list_services, get_service_detail, reload_config
registerRepoTools(server);             //  3: read_file, search_repos, list_directory
registerBuildTools(server);            //  2: build_service (extended), build_all
registerSshTools(server);              //  2: ssh_exec, check_vm
registerDockerTools(server);           // 14: docker_ps, control, logs, compose, top, diff, inspect, events, pause/unpause, exec, logs_search, logs_multi, system_df
registerNativeOpsTools(server);        //  4: build_ship, build_docker, secrets_status, backup_trigger
registerHealthTools(server);           // 23: health_*, health_endpoints, metrics_snapshot, tier1/2/3, profile_*, vm_network/top/disk/journal, service_list/get/spec/discover/version
registerControlTools(server);          // 10: vm_*, vm_drain, container_*, service_start/stop/restart
registerDiscoveryTools(server);        //  1: service_api_call
registerFrontTools(server);            //  5: front_list_projects, front_get_project, front_build, front_dev_server, front_deploy
registerCloudTools(server);            //  7: cloud_oci/gcp_instances/resources/costs, cloud_summary
registerCrawleeTools(server);          //  7: crawlee_list_actors, run_actor, list_runs, get_run, get_results, get_logs, abort_run
registerC3Tools(server);               // 16: c3_topology* (base+network/volumes/images/deps), c3_test (14 suites), c3_file, c3_vm_status, c3_report (5 types), c3_secrets_status, health_tier1/2/3
registerSecurityTools(server);         //  4: security_scan, security_docker, security_ssh_keys, security_tokens
registerNotifyTools(server);           //  5: notify_send, notify_health_down/recovered, notify_cert_expiring, notify_disk_full
registerDatabaseTools(server);         //  7: db_health_history, db_uptime_report, db_audit_log, db_deploy_history, db_alert_state, db_alert_update, db_prune

// Register resources (7 static + 2 templates = 9 total)
registerResources(server);             // cloud://config, ssh-config, services-overview, readme, front-projects, c3-api-endpoints, service-apis + templates: services/{name}, vms/{vm_id}

// Register prompts (4 total)
registerPrompts(server);               // cloud-architect, frontend-developer, debug-ops, crawlee-scraping

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v3.0.0 (115+ tools, 9 resources, 4 prompts)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
