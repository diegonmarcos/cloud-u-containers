#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerInfraTools } from "./tools/infra.js";
import { registerRepoTools } from "./tools/repo.js";
import { registerBuildTools } from "./tools/build.js";
import { registerSshTools } from "./tools/ssh-tools.js";
import { registerDockerTools } from "./tools/docker.js";
import { registerNativeOpsTools } from "./tools/native-ops.js";
import { registerRustApiHealthTools } from "./tools/rust-api-health.js";
import { registerRustApiControlTools } from "./tools/rust-api-control.js";
import { registerRustApiProxyTools } from "./tools/rust-api-proxy.js";
import { registerFrontTools } from "./tools/front.js";
import { registerRustApiCloudTools } from "./tools/rust-api-cloud.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "2.3.1",
});

// Register all tools (58 total — api_call + api_vm_control removed in v2.1, cloud in v2.2, crawlee in v2.3)
registerInfraTools(server);            //  4: list_vms, list_services, get_service_detail, reload_config
registerRepoTools(server);             //  3: read_file, search_repos, list_directory
registerBuildTools(server);            //  2: build_service (extended), build_all
registerSshTools(server);              //  2: ssh_exec, check_vm
registerDockerTools(server);           //  4: docker_ps, docker_control, docker_logs, docker_compose_up
registerNativeOpsTools(server);        //  4: build_ship, build_docker, secrets_status, backup_trigger
registerRustApiHealthTools(server);    // 11: health_*, profile_*, service_list/get/spec/discover
registerRustApiControlTools(server);   //  8: vm_*, container_*, service_start/stop
registerRustApiProxyTools(server);     //  1: service_api_call
registerFrontTools(server);            //  5: front_list_projects, front_get_project, front_build, front_dev_server, front_deploy
registerRustApiCloudTools(server);     //  7: cloud_oci/gcp_instances/resources/costs, cloud_summary
registerCrawleeTools(server);          //  7: crawlee_list_actors, run_actor, list_runs, get_run, get_results, get_logs, abort_run

// Register resources (7 static + 2 templates = 9 total)
registerResources(server);             // cloud://config, ssh-config, services-overview, readme, front-projects, rust-api-endpoints, service-apis + templates: services/{name}, vms/{vm_id}

// Register prompts (4 total)
registerPrompts(server);               // cloud-architect, frontend-developer, debug-ops, crawlee-scraping

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v2.3.1 (58 tools, 9 resources, 4 prompts)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
