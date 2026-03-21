import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { randomUUID } from "node:crypto";

import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";
import { registerMatomoTools } from "./tools/matomo.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerRadicaleTools } from "./tools/radicale.js";
import { registerProxiedTools } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[mcp-http] ${msg}\n`);

async function createMcpServer(): Promise<McpServer> {
  const server = new McpServer({
    name: "c3-services",
    version: "1.1.0",
  });

  registerRegistryTools(server);
  registerProxyTools(server);
  registerMatomoTools(server);
  registerSyncthingTools(server);
  registerNtfyTools(server);
  registerOllamaTools(server);
  registerRadicaleTools(server);

  // Proxy tools from child MCPs (mattermost-mcp, mailu-mcp)
  await registerProxiedTools(server);

  return server;
}

const sessions = new Map<
  string,
  { transport: StreamableHTTPServerTransport; server: McpServer }
>();

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
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
    });

    const server = await createMcpServer();
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
    const session = sessions.get(sessionId)!;
    await session.transport.handleRequest(req, res);
  } else if (req.method === "DELETE" && sessionId) {
    const session = sessions.get(sessionId!);
    if (session) {
      await session.transport.close();
      sessions.delete(sessionId!);
      log(`Session deleted: ${sessionId}`);
    }
    res.writeHead(200);
    res.end();
  } else if (sessionId && !sessions.has(sessionId)) {
    // Stale session (server restarted) → return 404 so client re-initializes
    log(`Session expired: ${sessionId} — returning 404 for client retry`);
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Session expired — please re-initialize" }));
  } else {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Bad Request — missing session" }));
  }
}

export function startMcpHttpServer(port: number = 3101): Promise<void> {
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
