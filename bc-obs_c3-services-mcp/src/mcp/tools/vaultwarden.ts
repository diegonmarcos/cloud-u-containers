import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { rawHttpRequest } from "../../shared/http.js";

const VW_BASE = "http://10.0.0.6:8880";

function vwApi(path: string): string {
  const token = process.env.VAULTWARDEN_ADMIN_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest("GET", `${VW_BASE}${path}`, undefined, 10_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerVaultwardenTools(server: McpServer) {
  server.tool(
    "user.vaultwarden.health",
    "Check Vaultwarden server health",
    {},
    async () => ({
      content: [{ type: "text" as const, text: vwApi("/alive") }],
    })
  );

  server.tool(
    "user.vaultwarden.status",
    "Get Vaultwarden admin status and config",
    {},
    async () => ({
      content: [{ type: "text" as const, text: vwApi("/admin/status") }],
    })
  );

  server.tool(
    "user.vaultwarden.users",
    "List registered users (admin endpoint)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: vwApi("/admin/users") }],
    })
  );

  server.tool(
    "user.vaultwarden.orgs",
    "List organizations (admin endpoint)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: vwApi("/admin/organizations") }],
    })
  );
}
