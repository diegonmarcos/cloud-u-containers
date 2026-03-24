import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { registry } from "../../registry/index.js";
import { rawHttpRequest } from "../../shared/http.js";

export function registerProxyTools(server: McpServer) {
  server.tool(
    "service_api_call",
    "Make a proxied API call to any service via its WireGuard mesh address",
    {
      service: z.string().describe("Service name (e.g. nocodb, gitea)"),
      method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]).describe("HTTP method"),
      path: z.string().describe("API path (e.g. /api/v1/users)"),
      body: z.string().optional().describe("JSON request body"),
    },
    async ({ service, method, path, body }) => {
      const baseUrl = registry.getBaseUrl(service);
      if (!baseUrl) {
        return { content: [{ type: "text" as const, text: `Service '${service}' not found` }], isError: true };
      }

      const svc = registry.get(service)!;
      if (svc.api.type === "no-api") {
        return { content: [{ type: "text" as const, text: `Service '${service}' has no API` }], isError: true };
      }

      const envToken = process.env[`${service.toUpperCase()}_API_TOKEN`];
      const headers: Record<string, string> = {};
      if (envToken) headers["Authorization"] = `Bearer ${envToken}`;

      const result = rawHttpRequest(method, `${baseUrl}${path}`, body, 30_000,
        Object.keys(headers).length > 0 ? headers : undefined);

      return {
        content: [{ type: "text" as const, text: JSON.stringify({
          status: result.status,
          ok: result.ok,
          data: result.data,
          ...(result.error ? { error: result.error } : {}),
        }, null, 2) }],
      };
    }
  );
}
