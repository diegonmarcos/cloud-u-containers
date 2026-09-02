#!/usr/bin/env node
/**
 * The one server.
 *
 * Every app under mcps-apps/ is loaded into THIS process. There is no
 * per-app server and no per-app stdio entry in .mcp.json: an MCP tool is
 * {name, schema, call}, which needs no process of its own, and twenty
 * processes would be twenty ssh transports racing for the same phone.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "../../lib-mcp/src/tools.js";
import { loadModules } from "../../lib-mcp/src/registry.js";

const server = new McpServer({ name: "cloud-superapp-mcp", version: "1.0.0" });

const log = (msg: string) => process.stderr.write(`[cloud-superapp-mcp] ${msg}\n`);

async function main() {
  const modules = await loadModules();
  registerTools(server, modules);

  const transport = new StdioServerTransport();
  log(`Starting cloud-superapp-mcp v1.0.0 (stdio, hosts=${process.env.SUPERAPP_HOSTS ?? "phone,phone-v6,phone-pub"})`);
  log(`${modules.length} app modules: ${modules.map((m) => m.id).join(", ")}`);
  if (!process.env.SUPERAPP_FLEET_TOKEN) {
    log("SUPERAPP_FLEET_TOKEN unset — discovery works, data routes will answer 401 (SuperApp → Configs → About)");
  }
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
