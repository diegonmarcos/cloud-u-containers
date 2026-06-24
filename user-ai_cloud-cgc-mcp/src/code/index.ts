#!/usr/bin/env node
import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { registerSpecTools } from "./tools/a-knowledge/specs.js";
import { registerConfigTools } from "./tools/a-knowledge/configs.js";
import { registerDocsTools } from "./tools/a-knowledge/docs.js";
import { registerInventoryTools } from "./tools/a-knowledge/inventory.js";
import { registerSkillTools } from "./tools/a-knowledge/skills.js";
import { registerOctocodeTools } from "./tools/b-code-graph-context/octocode.js";
import { registerCodegraphTools } from "./tools/b-code-graph-context/codegraph.js";
import { registerKgStoreTools } from "./tools/b-code-graph-context/kgstore.js";
import { buildContextSummary } from "./context.js";
import { bindHost } from "./shared/libs/binds.js";

const log = (msg: string) => process.stderr.write(`[kg-mcp] ${msg}\n`);

function createMcpServer(): McpServer {
  const server = new McpServer({
    name: "kg-mcp",
    version: "7.0.0",
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

  // ── Section A: Knowledge & Data ─────────────────────────────────────
  registerSpecTools(server);              //  3: service, vm, services_by_category
  registerDocsTools(server);              //  4: overview, service, readme, context
  registerInventoryTools(server);         // 25: cloud inventory + frontend projects
  registerConfigTools(server);            //  6: topology, configs, deps, topology_md, configs_md, front-deps
  registerSkillTools(server);             //  4: cloud_architect, frontend_developer, debug_ops, crawlee_scraping

  // ── Section B: Code Graph Context ──────────────────────────────────
  registerOctocodeTools(server);          //  3: search, memory, index (octocode Lance DB)
  registerCodegraphTools(server);         //  3: stubs (future)
  registerKgStoreTools(server);           //  2: query, overview (kg-store SurrealDB unified graph)

  return server;
}

// ── Stdio transport (default, for local CLI usage) ────────────────────
async function startStdio(): Promise<void> {
  const server = createMcpServer();
  const transport = new StdioServerTransport();
  log("Starting kg-mcp v7.0.0 (48 tools, 2 resources) via stdio...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

// ── HTTP transport (for proxying via c3-services-mcp) ─────────────────
const HTTP_PORT = parseInt(process.env.MCP_HTTP_PORT ?? "3105", 10);
const SESSION_ID = "kg-mcp-session";

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

  const host = bindHost();
  httpServer.listen(HTTP_PORT, host, () => {
    log(`MCP HTTP server listening on ${host}:${HTTP_PORT}`);
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
