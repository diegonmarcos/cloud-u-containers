/**
 * MCP Streamable HTTP Server — session-resilient design.
 *
 * Problem: every container restart destroys MCP sessions, forcing /mcp reconnect.
 * Solution: pre-warm a default session at startup via self-initialization.
 * Stale session requests are transparently routed to the default session.
 *
 * Flow:
 *   1. Server starts → creates default transport+server → self-initializes via localhost
 *   2. Claude Code connects → gets its own session (normal MCP flow)
 *   3. Container restarts → Claude Code sends tools/call with stale session ID
 *   4. Server doesn't recognize it → routes to pre-warmed default session
 *   5. Response includes default session's ID → client uses it going forward
 */
import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { randomUUID } from "node:crypto";

// ── Same tool registrations as stdio server ──
import { registerInventoryTools } from "./tools/inventory.js";
import { registerDeliveryTools } from "./tools/delivery.js";
import { registerOperationsTools } from "./tools/operations.js";
import { registerObservabilityTools } from "./tools/observability.js";
import { registerSecurityTools } from "./tools/security.js";
import { registerFinOpsTools } from "./tools/finops.js";
import { registerFrontendTools } from "./tools/frontend.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerMattermostTools } from "./tools/health_mattermost.js";
import { registerHealthMailuTools } from "./tools/health_mailu.js";
import { registerResources } from "./resources/index.js";

const log = (msg: string) => process.stderr.write(`[mcp-http] ${msg}\n`);

function createMcpServer(): McpServer {
  const server = new McpServer({
    name: "cloud-infra",
    version: "3.2.0",
  });

  registerHealthMailuTools(server);   // 5: mail health — register first (Claude Code tool limit)
  registerInventoryTools(server);
  registerDeliveryTools(server);
  registerOperationsTools(server);
  registerObservabilityTools(server);
  registerSecurityTools(server);
  registerFinOpsTools(server);
  registerFrontendTools(server);
  registerCrawleeTools(server);
  registerMattermostTools(server);
  registerResources(server);

  return server;
}

// ── Session management ───────────────────────────────────────────────
const sessions = new Map<
  string,
  { transport: StreamableHTTPServerTransport; server: McpServer }
>();

// Default pre-warmed session — survives stale client requests after restart
let defaultSession: { transport: StreamableHTTPServerTransport; server: McpServer; id: string } | null = null;

async function handleMcpRequest(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  if (url.pathname !== "/mcp") {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Not Found" }));
    return;
  }

  const sessionId = req.headers["mcp-session-id"] as string | undefined;

  if (req.method === "POST" && !sessionId) {
    // New session — create transport + server
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
    });
    const server = createMcpServer();
    await server.connect(transport);
    await transport.handleRequest(req, res);

    const sid = transport.sessionId!;
    sessions.set(sid, { transport, server });
    log(`New MCP session: ${sid}`);

    transport.onclose = () => {
      sessions.delete(sid);
      log(`Session closed: ${sid}`);
    };
  } else if (sessionId && sessions.has(sessionId)) {
    // Existing valid session
    const session = sessions.get(sessionId)!;
    await session.transport.handleRequest(req, res);
  } else if (req.method === "DELETE" && sessionId) {
    // Session cleanup
    const session = sessions.get(sessionId!);
    if (session) {
      await session.transport.close();
      sessions.delete(sessionId!);
      log(`Session deleted: ${sessionId}`);
    }
    res.writeHead(200);
    res.end();
  } else if (req.method === "POST" && sessionId && !sessions.has(sessionId) && defaultSession) {
    // ── SESSION RECOVERY ──
    // Client sends stale session ID (server restarted). Route to pre-warmed default session.
    // Replace the stale session ID header with the default session's ID so the SDK accepts it.
    log(`Session recovery: ${sessionId} → default ${defaultSession.id}`);
    req.headers["mcp-session-id"] = defaultSession.id;
    await defaultSession.transport.handleRequest(req, res);
  } else {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Bad Request — missing or invalid session" }));
  }
}

// ── Pre-warm default session via self-initialization ─────────────────
async function prewarmDefaultSession(port: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "self-init", version: "1.0" },
      },
    });

    const req = httpRequest(
      {
        hostname: "127.0.0.1",
        port,
        path: "/mcp",
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json, text/event-stream",
          "Content-Length": Buffer.byteLength(body),
        },
      },
      (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          // Extract session ID from response header
          const sid = res.headers["mcp-session-id"] as string | undefined;
          if (sid && sessions.has(sid)) {
            defaultSession = { ...sessions.get(sid)!, id: sid };
            log(`Default session pre-warmed: ${sid}`);

            // Send initialized notification
            const notif = JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
            const notifReq = httpRequest({
              hostname: "127.0.0.1",
              port,
              path: "/mcp",
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                Accept: "application/json, text/event-stream",
                "Mcp-Session-Id": sid,
                "Content-Length": Buffer.byteLength(notif),
              },
            });
            notifReq.write(notif);
            notifReq.end();
            notifReq.on("response", () => resolve());
            notifReq.on("error", () => resolve()); // non-fatal
          } else {
            log(`Default session pre-warm failed — no session ID in response`);
            resolve(); // non-fatal, server still works without recovery
          }
        });
      },
    );
    req.on("error", (err) => {
      log(`Default session pre-warm error: ${err.message}`);
      resolve(); // non-fatal
    });
    req.write(body);
    req.end();
  });
}

// ── Start server ─────────────────────────────────────────────────────
export function startMcpHttpServer(port: number = 3100): Promise<void> {
  return new Promise((resolve) => {
    const httpServer = createServer(async (req, res) => {
      try {
        await handleMcpRequest(req, res);
      } catch (err) {
        log(`Error handling MCP request: ${err}`);
        if (!res.headersSent) {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ error: "Internal Server Error" }));
        }
      }
    });

    httpServer.listen(port, "0.0.0.0", async () => {
      log(`MCP Streamable HTTP server listening on 0.0.0.0:${port}`);
      // Pre-warm default session for stale client recovery
      await prewarmDefaultSession(port);
      resolve();
    });
  });
}
