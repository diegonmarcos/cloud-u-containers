import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { rawHttpRequest } from "../../shared/http.js";

const SYNCTHING_BASE = "http://10.0.0.3:8384";

function syncthingGet(path: string): string {
  const apiKey = process.env.SYNCTHING_API_KEY ?? "";
  const result = rawHttpRequest("GET", `${SYNCTHING_BASE}${path}`, undefined, 10_000, {
    "X-API-Key": apiKey,
  });
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerSyncthingTools(server: McpServer) {
  server.tool(
    "syncthing_status",
    "Get Syncthing system status",
    {},
    async () => ({
      content: [{ type: "text" as const, text: syncthingGet("/rest/system/status") }],
    })
  );

  server.tool(
    "syncthing_config",
    "Get Syncthing current configuration",
    {},
    async () => ({
      content: [{ type: "text" as const, text: syncthingGet("/rest/config") }],
    })
  );

  server.tool(
    "syncthing_folders",
    "List all synced folders",
    {},
    async () => ({
      content: [{ type: "text" as const, text: syncthingGet("/rest/config/folders") }],
    })
  );

  server.tool(
    "syncthing_devices",
    "List connected devices",
    {},
    async () => ({
      content: [{ type: "text" as const, text: syncthingGet("/rest/system/connections") }],
    })
  );
}
