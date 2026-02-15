#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerInfraTools } from "./tools/infra.js";
import { registerRepoTools } from "./tools/repo.js";
import { registerBuildTools } from "./tools/build.js";
import { registerSshTools } from "./tools/ssh-tools.js";
import { registerDockerTools } from "./tools/docker.js";
import { registerNativeOpsTools } from "./tools/native-ops.js";
import { registerApiTools } from "./tools/api.js";
import { registerRustApiHealthTools } from "./tools/rust-api-health.js";
import { registerRustApiControlTools } from "./tools/rust-api-control.js";
import { registerRustApiProxyTools } from "./tools/rust-api-proxy.js";
import { registerFrontTools } from "./tools/front.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "2.0.0",
});

// Register all tools (45 total)
registerInfraTools(server);            //  3: list_vms, list_services, get_service_detail
registerRepoTools(server);             //  3: read_file, search_repos, list_directory
registerBuildTools(server);            //  2: build_service (extended), build_all
registerSshTools(server);              //  2: ssh_exec, check_vm
registerDockerTools(server);           //  4: docker_ps, docker_control, docker_logs, docker_compose_up
registerNativeOpsTools(server);        //  4: build_ship, build_docker, secrets_status, backup_trigger
registerApiTools(server);              //  2: api_call, api_vm_control (DEPRECATED)
registerRustApiHealthTools(server);    // 11: health_*, profile_*, service_list/get/spec/discover
registerRustApiControlTools(server);   //  8: vm_*, container_*, service_start/stop
registerRustApiProxyTools(server);     //  1: service_api_call
registerFrontTools(server);            //  5: front_list_projects, front_get_project, front_build, front_dev_server, front_deploy

// Register resources (7 total)
registerResources(server);             // cloud://config, ssh-config, services-overview, readme, front-projects, rust-api-endpoints, service-apis

// Register prompts (1 total)
registerPrompts(server);               // cloud-architect (hybrid Chef+Waiter model)

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server v2.0.0 (45 tools, 7 resources)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
