/**
 * MCP Streamable HTTP Server — exposes the MCP server over HTTP
 * so that rig-agentic (Rust MCP client) can connect over the Docker network.
 *
 * Runs on a separate port (default 3100) alongside the Fastify REST API.
 * Stateless mode — no session management needed for single-client use.
 */
import { createServer, IncomingMessage, ServerResponse } from "node:http";
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
import { registerMattermostTools } from "./tools/mattermost.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";

const log = (msg: string) => process.stderr.write(`[mcp-http] ${msg}\n`);

function createMcpServer(): McpServer {
  const server = new McpServer({
    name: "cloud-infra",
    version: "3.0.0",
  });

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
  registerPrompts(server);

  return server;
}

// Track active sessions: sessionId → { transport, server }
const sessions = new Map<
  string,
  { transport: StreamableHTTPServerTransport; server: McpServer }
>();

async function handleMcpRequest(
  req: IncomingMessage,
  res: ServerResponse
): Promise<void> {
  // Only handle /mcp path
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

    // handleRequest must run first — it generates the sessionId
    await transport.handleRequest(req, res);

    const sid = transport.sessionId!;
    sessions.set(sid, { transport, server });
    log(`New MCP session: ${sid}`);

    transport.onclose = () => {
      sessions.delete(sid);
      log(`Session closed: ${sid}`);
    };
  } else if (sessionId && sessions.has(sessionId)) {
    // Existing session
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
  } else if (sessionId && !sessions.has(sessionId)) {
    // Stale/unknown session → 404 tells MCP client to clear session and re-initialize
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Session not found" }));
  } else {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Bad Request — missing session" }));
  }
}

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

    httpServer.listen(port, "0.0.0.0", () => {
      log(`MCP Streamable HTTP server listening on 0.0.0.0:${port}`);
      resolve();
    });
  });
}
