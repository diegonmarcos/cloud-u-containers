import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { rawHttpRequest } from "../../shared/http.js";

const MAILU_BASE = "http://10.0.0.3:8444";

function mailuGet(path: string): string {
  const apiKey = process.env.MAILU_API_KEY ?? "";
  const result = rawHttpRequest("GET", `${MAILU_BASE}${path}`, undefined, 10_000, {
    Authorization: apiKey,
  });
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerMailuTools(server: McpServer) {
  server.tool(
    "mailu_domains",
    "List all mail domains in Mailu",
    {},
    async () => ({
      content: [{ type: "text" as const, text: mailuGet("/api/v1/domain") }],
    })
  );

  server.tool(
    "mailu_users",
    "List all mail users in Mailu",
    {},
    async () => ({
      content: [{ type: "text" as const, text: mailuGet("/api/v1/user") }],
    })
  );

  server.tool(
    "mailu_aliases",
    "List all mail aliases in Mailu",
    {},
    async () => ({
      content: [{ type: "text" as const, text: mailuGet("/api/v1/alias") }],
    })
  );
}
