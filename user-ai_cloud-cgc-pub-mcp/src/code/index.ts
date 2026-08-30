#!/usr/bin/env node
import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
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

const exec = promisify(execFile);
const log = (msg: string) => process.stderr.write(`[cloud-cgc-pub-mcp] ${msg}\n`);

interface CreatedServer {
  server: McpServer;
  toolCount: number;
  resourceCount: number;
}

function createMcpServer(): CreatedServer {
  const server = new McpServer({
    name: "cloud-cgc-pub-mcp",
    version: "7.0.0",
  });

  // Wrap tool/resource registration so the startup banner + /health report the
  // REAL counts instead of a hardcoded number someone forgets to bump.
  let toolCount = 0;
  let resourceCount = 0;
  const registerTool = server.tool.bind(server);
  const registerResource = server.resource.bind(server);
  server.tool = ((...args: Parameters<typeof registerTool>) => {
    toolCount += 1;
    return registerTool(...args);
  }) as typeof server.tool;
  server.resource = ((...args: Parameters<typeof registerResource>) => {
    resourceCount += 1;
    return registerResource(...args);
  }) as typeof server.resource;

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
  registerSpecTools(server);              //  1: knowledge.spec (service|vm|services_by_category)
  registerDocsTools(server);              //  1: knowledge.docs (overview|readme|service|context)
  registerInventoryTools(server);         //  1: knowledge.inventory (25 methods)
  registerConfigTools(server);            //  1: knowledge.config (topology|topology_md|configs|configs_md|deps|front_deps)
  registerSkillTools(server);             //  1: knowledge.skill (cloud_architect|frontend_developer|debug_ops|crawlee_scraping)

  // ── Section B: Code Graph Context ──────────────────────────────────
  registerOctocodeTools(server);          //  3: search, memory, index (octocode Lance DB)
  registerCodegraphTools(server);         //  3: stubs (future)
  registerKgStoreTools(server);           //  2: query, overview (kg-store SurrealDB unified graph)

  return { server, toolCount, resourceCount };
}

// ── /health checks — cheap, parallel, never block or throw ────────────────
const KG_STORE_URL = process.env.KG_STORE_URL ?? "http://127.0.0.1:8001";
const OCTOCODE_BIN = process.env.OCTOCODE_BIN ?? "octocode";
const GIT_ROOT = process.env.GIT_ROOT ?? `${process.env.HOME ?? "/home/diego"}/git`;
const GRAPHS_DIR = join(import.meta.dirname!, "graphs");

async function checkKgStore(): Promise<{ reachable: boolean; error: string | null }> {
  try {
    const r = await fetch(`${KG_STORE_URL.replace(/\/$/, "")}/health`, { signal: AbortSignal.timeout(2000) });
    return { reachable: r.ok, error: r.ok ? null : `HTTP ${r.status}` };
  } catch (e) {
    return { reachable: false, error: (e as Error).message };
  }
}

function checkCodegraphBundle(): { present: boolean; count: number; generated_at: string | null } {
  try {
    if (!existsSync(GRAPHS_DIR)) return { present: false, count: 0, generated_at: null };
    const files = readdirSync(GRAPHS_DIR).filter((f) => f.startsWith("code-signatures-") && f.endsWith(".json"));
    let newest = 0;
    for (const f of files) {
      const mtime = statSync(join(GRAPHS_DIR, f)).mtimeMs;
      if (mtime > newest) newest = mtime;
    }
    return {
      present: files.length > 0,
      count: files.length,
      generated_at: newest > 0 ? new Date(newest).toISOString() : null,
    };
  } catch {
    return { present: false, count: 0, generated_at: null };
  }
}

async function checkOctocode(): Promise<{
  binary: boolean;
  version: string | null;
  repos_volume_present: boolean;
  repo_count: number;
}> {
  let binary = false;
  let version: string | null = null;
  try {
    const { stdout } = await exec(OCTOCODE_BIN, ["--version"], { timeout: 2000 });
    binary = true;
    version = stdout.trim() || null;
  } catch {
    binary = false;
  }

  let repos_volume_present = false;
  let repo_count = 0;
  try {
    repos_volume_present = existsSync(GIT_ROOT);
    if (repos_volume_present) repo_count = readdirSync(GIT_ROOT).length;
  } catch {
    repos_volume_present = false;
    repo_count = 0;
  }

  return { binary, version, repos_volume_present, repo_count };
}

async function buildHealthBody(toolCount: number, resourceCount: number) {
  const [kgstore, codegraph_bundle, octocode] = await Promise.all([
    checkKgStore(),
    Promise.resolve(checkCodegraphBundle()),
    checkOctocode(),
  ]);

  const degraded = !kgstore.reachable || !codegraph_bundle.present || !octocode.binary;
  return {
    status: degraded ? "degraded" : "ok",
    timestamp: new Date().toISOString(),
    tools: toolCount,
    resources: resourceCount,
    checks: { kgstore, codegraph_bundle, octocode },
  };
}

// ── Stdio transport (default, for local CLI usage) ────────────────────
async function startStdio(): Promise<void> {
  const { server, toolCount, resourceCount } = createMcpServer();
  const transport = new StdioServerTransport();
  log(`Starting cloud-cgc-pub-mcp v7.0.0 (${toolCount} tools, ${resourceCount} resources) via stdio...`);
  await server.connect(transport);
  log("Connected via stdio transport");
}

// ── HTTP transport (for proxying via cloud-services-mcp) ─────────────────
const HTTP_PORT = parseInt(process.env.MCP_HTTP_PORT ?? "3105", 10);
const SESSION_ID = "cloud-cgc-pub-mcp-session";

async function startHttp(): Promise<void> {
  let session: { transport: StreamableHTTPServerTransport; server: McpServer; toolCount: number; resourceCount: number } | null = null;

  const initSession = async (): Promise<void> => {
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
    const { server, toolCount, resourceCount } = createMcpServer();
    await server.connect(transport);
    session = { transport, server, toolCount, resourceCount };
  };

  await initSession();

  const httpServer = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname === "/health") {
      const body = await buildHealthBody(session?.toolCount ?? 0, session?.resourceCount ?? 0);
      res.writeHead(body.checks.octocode.binary === false ? 503 : 200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
      return;
    }
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
