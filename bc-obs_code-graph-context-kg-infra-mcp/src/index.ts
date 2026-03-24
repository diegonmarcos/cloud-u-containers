#!/usr/bin/env node
import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { registerSpecTools } from "./tools/a-raw-json/specs.js";
import { registerDocsTools } from "./tools/a-raw-json/docs.js";
import { registerSkillTools } from "./tools/a-raw-json/skills.js";
import { registerOctocodeTools } from "./tools/b-octocode/octocode.js";
import { registerCodegraphTools } from "./tools/c-codegraph-rust/codegraph.js";
import { registerInventoryTools } from "./tools/d-infra-read/inventory.js";
import { registerFinOpsTools } from "./tools/d-infra-read/finops.js";
import { registerObservabilityReadTools } from "./tools/d-infra-read/observability-read.js";
import { registerSecurityReadTools } from "./tools/d-infra-read/security-read.js";
import { registerFrontendReadTools } from "./tools/d-infra-read/frontend-read.js";
import { registerCrawleeReadTools } from "./tools/d-infra-read/crawlee-read.js";
import { registerResources } from "./tools/d-infra-read/resources/index.js";
import { buildContextSummary } from "./context.js";

const log = (msg: string) => process.stderr.write(`[code-graph-context] ${msg}\n`);

function createMcpServer(): McpServer {
  const server = new McpServer({
    name: "code-graph-context",
    version: "5.0.0",
  });

  // ── Resources ─────────────────────────────────────────────────────────
  server.resource(
    "context-compact",
    "cloud://context/compact",
    { description: "Compact infrastructure context (~10k tokens) — VM table, service table, architecture, tool index" },
    async () => ({
      contents: [{
        uri: "cloud://context/compact",
        mimeType: "text/markdown",
        text: buildContextSummary("compact"),
      }],
    })
  );

  server.resource(
    "context-full",
    "cloud://context/full",
    { description: "Full infrastructure context (~50k tokens) — everything from compact + topology.md, configs.md, README, deps" },
    async () => ({
      contents: [{
        uri: "cloud://context/full",
        mimeType: "text/markdown",
        text: buildContextSummary("full"),
      }],
    })
  );

  // ── Section A: Raw JSON Infra Knowledge ──────────────────────────────
  registerSpecTools(server);
  registerDocsTools(server);
  registerSkillTools(server);

  // ── Section B: Octocode — Semantic Code Search ───────────────────────
  registerOctocodeTools(server);

  // ── Section C: CodeGraph-Rust — Graph Analysis (Future) ──────────────
  registerCodegraphTools(server);

  // ── Section D: Infra READ tools (from c3-infra-mcp) ────────────────
  registerInventoryTools(server);         // 21: list_vms, list_services, read_file, search_repos, c3_topology*, c3_deps*, c3_file
  registerFinOpsTools(server);            // 10: cloud_oci/gcp/aws instances/resources/costs
  registerObservabilityReadTools(server); // 24: health_*, profile_*, c3_test/report, db_*_history, vm_*
  registerSecurityReadTools(server);      //  2: c3_topology_security, c3_secrets_status
  registerFrontendReadTools(server);      //  2: front_list_projects, front_get_project
  registerCrawleeReadTools(server);       //  5: crawlee list/get tools
  registerResources(server);              //  9: cloud:// resources

  return server;
}

// ── Stdio transport (default, for local CLI usage) ────────────────────
async function startStdio(): Promise<void> {
  const server = createMcpServer();
  const transport = new StdioServerTransport();
  log("Starting code-graph-context MCP server v6.0.0 (81 tools, 11 resources) via stdio...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

// ── HTTP transport (for proxying via c3-services-mcp) ─────────────────
const HTTP_PORT = parseInt(process.env.MCP_HTTP_PORT ?? "3105", 10);
const SESSION_ID = "code-graph-context-session";

async function startHttp(): Promise<void> {
  let session: { transport: StreamableHTTPServerTransport; server: McpServer } | null = null;

  const initSession = async (): Promise<void> => {
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
    const server = createMcpServer();
    await server.connect(transport);
    session = { transport, server };
  };

  await initSession();

  const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname !== "/mcp") {
      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "Not Found" }));
      return;
    }
    if (req.method === "DELETE") { res.writeHead(200); res.end(); return; }
    if (!session) { res.writeHead(503); res.end(JSON.stringify({ error: "Initializing" })); return; }

    try {
      const clientSessionId = req.headers["mcp-session-id"] as string | undefined;
      if (req.method === "POST" && !clientSessionId) {
        await initSession();
        await session!.transport.handleRequest(req, res);
      } else if (clientSessionId && clientSessionId !== SESSION_ID) {
        req.headers["mcp-session-id"] = SESSION_ID;
        await session.transport.handleRequest(req, res);
      } else {
        await session.transport.handleRequest(req, res);
      }
    } catch (err) {
      log(`Error: ${err}`);
      if (!res.headersSent) { res.writeHead(500); res.end(JSON.stringify({ error: "Internal Server Error" })); }
    }
  });

  httpServer.listen(HTTP_PORT, "0.0.0.0", () => {
    log(`MCP HTTP server listening on 0.0.0.0:${HTTP_PORT}`);
  });
}

// ── Main — stdio + HTTP in parallel ───────────────────────────────────
async function main(): Promise<void> {
  const mode = process.env.MCP_TRANSPORT ?? "stdio";

  if (mode === "http") {
    await startHttp();
  } else if (mode === "both") {
    await Promise.all([startStdio(), startHttp()]);
  } else {
    await startStdio();
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
