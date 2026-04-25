#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerSearchTools } from "./tools/gmail_search.js";
import { registerReadTools } from "./tools/gmail_read.js";
import { registerSendTools } from "./tools/gmail_send.js";
import { registerLabelTools } from "./tools/gmail_labels.js";
import { registerThreadTools } from "./tools/gmail_threads.js";
import { registerAccountTools } from "./tools/account.js";
import { listAccounts, configuredAccountAliases } from "./shared/config.js";

const log = (msg: string) => process.stderr.write(`[google-personal-mcp] ${msg}\n`);

async function main() {
  const all = listAccounts();
  const ready = configuredAccountAliases();
  if (all.length === 0) {
    log("ERROR: No accounts in build.json (accounts: []). Add at least one.");
    process.exit(1);
  }
  if (ready.length === 0) {
    log(`WARNING: No App Passwords in env. Configured: ${all.map(a => `${a.alias}(${a.secret_env})`).join(", ")}. ` +
        `Server will start but tools will fail until at least one secret is loaded via sops.`);
  } else {
    log(`Loaded credentials for ${ready.length}/${all.length} accounts: ${ready.join(", ")}`);
  }

  if (process.argv.includes("--http")) {
    const { startMcpHttpServer } = await import("./http.js");
    const port = parseInt(process.env.MCP_HTTP_PORT || process.env.PORT || "3105", 10);
    await startMcpHttpServer(port);
  } else {
    const server = new McpServer({ name: "google-personal-mcp", version: "1.0.0" });
    registerAccountTools(server);
    registerSearchTools(server);
    registerReadTools(server);
    registerSendTools(server);
    registerLabelTools(server);
    registerThreadTools(server);
    const transport = new StdioServerTransport();
    log(`Starting google-personal-mcp v1.0.0 (8 tools: account, search, read, send, labels, threads)...`);
    await server.connect(transport);
    log("Connected via stdio transport");
  }
}

main().catch((err) => {
  log(`Fatal: ${err?.stack ?? err}`);
  process.exit(1);
});
