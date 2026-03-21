/**
 * MCP Streamable HTTP Server for Mailu MCP
 * Runs on port 3103, fixed-session HTTP transport.
 */
import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { registerInboxTools } from "./tools/inbox.js";
import { registerComposeTools } from "./tools/compose.js";
import { registerAdminTools } from "./tools/admin.js";

const log = (msg: string) => process.stderr.write(`[mailu-http] ${msg}\n`);

const SESSION_ID = "mailu-mcp-session";

function createMcpServer(): McpServer {
  const server = new McpServer({
    name: "mailu-mcp",
    version: "1.0.0",
  });
  registerInboxTools(server);
  registerComposeTools(server);
  registerAdminTools(server);
  return server;
}

let session: { transport: StreamableHTTPServerTransport; server: McpServer } | null = null;

async function initSession(port: number): Promise<void> {
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => SESSION_ID,
  });
  const server = createMcpServer();
  await server.connect(transport);

  // Trigger internal session-id assignment by sending a synthetic initialize POST
  const initBody = JSON.stringify({
    jsonrpc: "2.0",
    id: 0,
    method: "initialize",
    params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "self-init", version: "0.0.0" } },
  });

  const { req, res } = fakeHttp(initBody);
  await transport.handleRequest(req, res);

  session = { transport, server };
  log(`Persistent session initialized: ${SESSION_ID} (port ${port})`);
}

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

  if (req.method === "DELETE") {
    log(`DELETE received (session kept alive): ${sessionId ?? "(none)"}`);
    res.writeHead(200);
    res.end();
    return;
  }

  if (!session) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Session not yet initialized" }));
    return;
  }

  if (req.method === "POST" && !sessionId) {
    // New client initialize — recreate session
    log(`New client initialize — recreating session`);
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
    const server = createMcpServer();
    await server.connect(transport);
    session = { transport, server };
    await session.transport.handleRequest(req, res);
    return;
  }

  // Swap stale session ID to fixed ID so transport recognises the request
  if (sessionId && sessionId !== SESSION_ID) {
    log(`Swapping stale session ID: ${sessionId} → ${SESSION_ID}`);
    (req.headers as Record<string, string>)["mcp-session-id"] = SESSION_ID;
  }

  await session.transport.handleRequest(req, res);
}

export function startMcpHttpServer(port: number = 3103): Promise<void> {
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
      await initSession(port);
      resolve();
    });
  });
}

/* ── helpers: synthetic request / response for self-init ── */

function fakeHttp(body: string) {
  const { Readable } = require("node:stream");
  const req = Object.assign(new Readable({ read() { this.push(body); this.push(null); } }), {
    method: "POST",
    url: "/mcp",
    headers: { "content-type": "application/json", "accept": "application/json, text/event-stream" } as Record<string, string>,
  }) as unknown as IncomingMessage;

  const chunks: Buffer[] = [];
  const res = {
    writeHead: () => res,
    setHeader: () => res,
    write: (c: any) => { chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)); return true; },
    end: (c?: any) => { if (c) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)); },
    headersSent: false,
    statusCode: 200,
  } as unknown as ServerResponse;

  return { req, res };
}
