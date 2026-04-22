import { createServer, IncomingMessage, ServerResponse, request as httpRequest } from "node:http";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

// ── Meta ────────────────────────────────────────
import { registerRegistryTools } from "./tools/registry.js";
import { registerProxyTools } from "./tools/proxy.js";
import { registerDiscoveryTools } from "./tools/discovery.js";
// ── Infra ───────────────────────────────────────
import { registerGrafanaTools } from "./tools/grafana.js";
import { registerMatomoTools } from "./tools/matomo.js";
import { registerUmamiTools } from "./tools/umami.js";
import { registerNtfyTools } from "./tools/ntfy.js";
import { registerSyncthingTools } from "./tools/syncthing.js";
import { registerOllamaTools } from "./tools/ollama.js";
import { registerDaguTools } from "./tools/dagu.js";
import { registerCrawleeTools } from "./tools/crawlee.js";
import { registerAutheliaTools } from "./tools/authelia.js";
import { registerNocodbTools } from "./tools/nocodb.js";
import { registerRigTools } from "./tools/rig.js";
// ── User ────────────────────────────────────────
import { registerPhotoprismTools } from "./tools/photoprism.js";
import { registerFilebrowserTools } from "./tools/filebrowser.js";
import { registerGiteaTools } from "./tools/gitea.js";
import { registerGristTools } from "./tools/grist.js";
import { registerHedgedocTools } from "./tools/hedgedoc.js";
import { registerEtherpadTools } from "./tools/etherpad.js";
import { registerSnappymailTools } from "./tools/snappymail.js";
import { registerRadicaleTools } from "./tools/radicale.js";
import { registerVaultwardenTools } from "./tools/vaultwarden.js";
// ── Proxied ─────────────────────────────────────
import { registerProxiedInfraTools, registerProxiedUserTools, startProxyRetryLoop, connectedChildren } from "./tools/proxy-mcp.js";

const log = (msg: string) => process.stderr.write(`[mcp-http] ${msg}\n`);
const SESSION_ID = "c3-services-mcp-session";

function createNativeServer(): McpServer {
  const server = new McpServer({ name: "c3-services", version: "2.3.0" });
  // Meta
  registerRegistryTools(server);
  registerProxyTools(server);
  registerDiscoveryTools(server);
  // Infra
  registerGrafanaTools(server);
  registerMatomoTools(server);
  registerUmamiTools(server);
  registerNtfyTools(server);
  registerSyncthingTools(server);
  registerOllamaTools(server);
  registerDaguTools(server);
  registerCrawleeTools(server);
  registerAutheliaTools(server);
  registerNocodbTools(server);
  registerRigTools(server);
  // User
  registerPhotoprismTools(server);
  registerFilebrowserTools(server);
  registerGiteaTools(server);
  registerGristTools(server);
  registerHedgedocTools(server);
  registerEtherpadTools(server);
  registerSnappymailTools(server);
  registerRadicaleTools(server);
  registerVaultwardenTools(server);
  return server;
}

/** Connect proxied child MCPs in background, send listChanged when each connects */
function connectProxiesInBackground(server: McpServer): void {
  (async () => {
    await registerProxiedInfraTools(server);
    await registerProxiedUserTools(server);
    if (connectedChildren.size > 0) {
      log(`Proxied tools registered — sending tools/list_changed`);
      server.sendToolListChanged();
    }
    startProxyRetryLoop(server);
  })().catch((err) => log(`Proxy background connect error: ${err}`));
}

let session: { transport: StreamableHTTPServerTransport; server: McpServer } | null = null;

async function handleMcpRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
  if (url.pathname !== "/mcp") {
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Not Found" }));
    return;
  }
  if (req.method === "DELETE") { res.writeHead(200); res.end(); return; }
  if (!session) { res.writeHead(503, { "Content-Type": "application/json" }); res.end(JSON.stringify({ error: "Initializing" })); return; }

  const clientSessionId = req.headers["mcp-session-id"] as string | undefined;

  if (req.method === "POST" && !clientSessionId) {
    // New client connecting — recreate session with native tools,
    // proxied tools join via retry loop + tools/list_changed notification.
    //
    // IMPORTANT: proactively close the previous session's transport + server
    // so Node can GC the streams / AbortControllers. Without this, every
    // client reconnect leaks one StreamableHTTPServerTransport.
    log("New client initialize — recreating session");
    if (session) {
      try { await session.transport.close?.(); } catch { /* already closed */ }
      try { await session.server.close?.(); } catch { /* already closed */ }
    }
    connectedChildren.clear();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
    const server = await createNativeServer();
    await server.connect(transport);
    session = { transport, server };
    // Proxy tools connect in background, send listChanged when ready.
    // startProxyRetryLoop is idempotent (guarded by module-level retryTimer),
    // so calling it on every init does NOT spawn additional setIntervals.
    connectProxiesInBackground(server);
    await session.transport.handleRequest(req, res);
  } else if (clientSessionId === SESSION_ID) {
    await session.transport.handleRequest(req, res);
  } else if (clientSessionId && clientSessionId !== SESSION_ID) {
    log(`Session swap: ${clientSessionId} → ${SESSION_ID}`);
    req.headers["mcp-session-id"] = SESSION_ID;
    await session.transport.handleRequest(req, res);
  } else {
    res.writeHead(400, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "Bad Request" }));
  }
}

async function initSession(port: number): Promise<void> {
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: () => SESSION_ID });
  const server = createNativeServer();
  await server.connect(transport);
  session = { transport, server };

  await new Promise<void>((resolve) => {
    const body = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "self", version: "1.0" } } });
    const req = httpRequest({ hostname: "127.0.0.1", port, path: "/mcp", method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream", "Content-Length": Buffer.byteLength(body) },
    }, (res) => {
      res.on("data", () => {}); res.on("end", () => {
        const notif = JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" });
        const nr = httpRequest({ hostname: "127.0.0.1", port, path: "/mcp", method: "POST",
          headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream",
            "Mcp-Session-Id": SESSION_ID, "Content-Length": Buffer.byteLength(notif) } });
        nr.write(notif); nr.end();
        nr.on("response", (r) => { r.on("data", () => {}); r.on("end", () => resolve()); });
        nr.on("error", () => resolve());
      });
    });
    req.on("error", () => resolve());
    req.write(body); req.end();
  });
  log(`Persistent session ready: ${SESSION_ID}`);

  // Connect proxied child MCPs in background, notify client when ready
  connectProxiesInBackground(server);
}

export function startMcpHttpServer(port: number = 3101): Promise<void> {
  return new Promise((resolve) => {
    const httpServer = createServer(async (req, res) => {
      try { await handleMcpRequest(req, res); }
      catch (err) { log(`Error: ${err}`); if (!res.headersSent) { res.writeHead(500); res.end(JSON.stringify({ error: "Internal Server Error" })); } }
    });
    httpServer.listen(port, "0.0.0.0", async () => {
      log(`MCP Streamable HTTP server listening on 0.0.0.0:${port}`);
      await initSession(port);
      resolve();
    });
  });
}

// ── Self-start when run directly ─────────────────────────────────────
const port = parseInt(process.env.MCP_HTTP_PORT ?? "3101", 10);
startMcpHttpServer(port).catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
