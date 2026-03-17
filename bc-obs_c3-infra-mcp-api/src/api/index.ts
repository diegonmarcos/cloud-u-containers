import { buildApp } from "./app.js";
import { startMcpHttpServer } from "../mcp/http.js";

const PORT = parseInt(process.env.PORT ?? "8080", 10);
const MCP_PORT = parseInt(process.env.MCP_HTTP_PORT ?? "3100", 10);
const HOST = process.env.HOST ?? "0.0.0.0";

async function main() {
  const app = await buildApp();

  await app.listen({ port: PORT, host: HOST });
  app.log.info(`C3 API v3.0.0 listening on ${HOST}:${PORT}`);
  app.log.info(`Swagger UI: http://${HOST}:${PORT}/docs`);

  // Start MCP Streamable HTTP server for rig-agentic
  await startMcpHttpServer(MCP_PORT);
  app.log.info(`MCP HTTP transport on ${HOST}:${MCP_PORT}/mcp`);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
