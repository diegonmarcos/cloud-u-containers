#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

import { registerInfraTools } from "./tools/infra.js";
import { registerRepoTools } from "./tools/repo.js";
import { registerBuildTools } from "./tools/build.js";
import { registerSshTools } from "./tools/ssh-tools.js";
import { registerDockerTools } from "./tools/docker.js";
import { registerApiTools } from "./tools/api.js";
import { registerFrontTools } from "./tools/front.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";

const server = new McpServer({
  name: "cloud-infra",
  version: "1.0.0",
});

// Register all tools (21 total)
registerInfraTools(server);     // list_vms, list_services, get_service_detail
registerRepoTools(server);      // read_file, search_repos, list_directory
registerBuildTools(server);     // build_service, build_all
registerSshTools(server);       // ssh_exec, check_vm
registerDockerTools(server);    // docker_ps, docker_control, docker_logs, docker_compose_up
registerApiTools(server);       // api_call, api_vm_control
registerFrontTools(server);     // front_list_projects, front_get_project, front_build, front_dev_server, front_deploy

// Register resources (5 total)
registerResources(server);      // cloud://config, cloud://ssh-config, cloud://services-overview, cloud://readme, cloud://front-projects

// Register prompts (1 total)
registerPrompts(server);        // cloud-architect

// All logging must go to stderr (stdout is JSON-RPC)
const log = (msg: string) => process.stderr.write(`[cloud-infra] ${msg}\n`);

async function main() {
  const transport = new StdioServerTransport();
  log("Starting cloud-infra MCP server...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
