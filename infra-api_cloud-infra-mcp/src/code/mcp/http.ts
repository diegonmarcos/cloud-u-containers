/**
 * MCP Streamable HTTP Server — persistent session design.
 *
 * Uses a FIXED session ID so Claude Code's cached session survives container restarts.
 * At startup, self-initializes the session via localhost request.
 * Client never needs /mcp reconnect — the session ID is always valid.
 */
import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { bindHost } from "../shared/libs/binds.js";

// A) Observability
import { registerHealthCloudTools } from "./tools/health_cloud.js";
import { registerHealthMailTools } from "./tools/health_mail.js";
import { registerObservabilityReadTools } from "./tools/observability-read.js";
import { registerFinOpsTools } from "./tools/finops.js";
import { registerFinOpsCloudTools } from "./tools/finops-cloud.js";
import { registerObservabilityExecTools } from "./tools/observability.js";
// B) DevOps
import { registerWorkflowTools } from "./tools/workflows.js";
import { registerVpsOpsTools } from "./tools/vps-ops.js";
import { registerDeliveryTools } from "./tools/delivery.js";
import { registerOperationsTools } from "./tools/operations.js";
import { registerMailOpsTools } from "./tools/mail-ops.js";
import { registerFrontendExecTools } from "./tools/frontend.js";
import { registerTelegramTools } from "./tools/telegram.js";
// C) Security
import { registerSecurityExecTools } from "./tools/security.js";
// Resources
import { registerResources } from "./resources/index.js";

const log = (msg: string) => process.stderr.write(`[mcp-http] ${msg}\n`);
const SESSION_ID = "c3-infra-mcp-session";

function createMcpServer(): McpServer {
  const server = new McpServer({ name: "cloud-infra", version: "5.0.0" });

  // A) Observability
  registerHealthCloudTools(server);
  registerHealthMailTools(server);
  registerObservabilityReadTools(server);
  registerFinOpsTools(server);
  registerFinOpsCloudTools(server);
  registerObservabilityExecTools(server);
  // B) DevOps
  registerWorkflowTools(server);
  registerVpsOpsTools(server);
  registerDeliveryTools(server);
  registerOperationsTools(server);
  registerMailOpsTools(server);
  registerFrontendExecTools(server);
  registerTelegramTools(server);
  // C) Security
  registerSecurityExecTools(server);
  // Resources
  registerResources(server);

  return server;
}

// ── Single persistent session ────────────────────────────────────────
let session: { transport: StreamableHTTPServerTransport; server: McpServer } | null = null;

async function handleMcpRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  if (url.pathname !== "/mcp") {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Not Found" }));
    return;
  }

  if (req.method === "DELETE") {
    // Client wants to close session — acknowledge but don't destroy (persist across reconnects)
    res.writeHead(200);
    res.end();
    return;
  }

  if (!session) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Server initializing — retry in 1s" }));
    return;
  }

  const clientSessionId = req.headers["mcp-session-id"] as string | undefined;

  if (req.method === "POST" && !clientSessionId) {
    // New client connecting (initialize request) — recreate session
    // This handles /mcp reconnect: Claude Code sends initialize without session ID
    log(`New client initialize — recreating session`);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
    const server = createMcpServer();
    await server.connect(transport);
    session = { transport, server };
    await session.transport.handleRequest(req, res);
  } else if (clientSessionId === SESSION_ID) {
    // Existing client with correct session ID
    await session.transport.handleRequest(req, res);
  } else if (clientSessionId && clientSessionId !== SESSION_ID) {
    // Client has a stale session ID from before restart — swap to our fixed ID
    log(`Session swap: ${clientSessionId} → ${SESSION_ID}`);
    req.headers["mcp-session-id"] = SESSION_ID;
    await session.transport.handleRequest(req, res);
  } else {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Bad Request" }));
  }
}

// ── Self-initialize session at startup ───────────────────────────────
async function initSession(port: number): Promise<void> {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => SESSION_ID,
  });
  const server = createMcpServer();
  await server.connect(transport);

  session = { transport, server };

  // Self-initialize via localhost request
  await new Promise<void>((resolve) => {
    const body = JSON.stringify({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "self", version: "1.0" } },
    });
    const req = httpRequest({
      hostname: "127.0.0.1", port, path: "/mcp", method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "Content-Length": Buffer.byteLength(body) },
    }, (res) => {
      res.on("data", () => {});
      res.on("end", () => {
        // Send initialized notification
        const notif = JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
        const nr = httpRequest({
          hostname: "127.0.0.1", port, path: "/mcp", method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream",
            "Mcp-Session-Id": SESSION_ID, "Content-Length": Buffer.byteLength(notif) },
        });
        nr.write(notif);
        nr.end();
        nr.on("response", (r) => { r.on("data", () => {}); r.on("end", () => resolve()); });
        nr.on("error", () => resolve());
      });
    });
    req.on("error", () => resolve());
    req.write(body);
    req.end();
  });

  log(`Persistent session ready: ${SESSION_ID}`);
}

// ── Start server ─────────────────────────────────────────────────────
export function startMcpHttpServer(port: number = 3100): Promise<void> {
  return new Promise((resolve) => {
    const httpServer = createServer(async (req, res) => {
      try {
        await handleMcpRequest(req, res);
      } catch (err) {
        log(`Error: ${err}`);
        if (!res.headersSent) {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Internal Server Error" }));
        }
      }
    });

    const host = bindHost();
    httpServer.listen(port, host, async () => {
      log(`MCP Streamable HTTP server listening on ${host}:${port}`);
      await initSession(port);
      resolve();
    });
  });
}

// ── Self-start when run directly ─────────────────────────────────────
const port = parseInt(process.env.MCP_HTTP_PORT ?? "3100", 10);
startMcpHttpServer(port).catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
