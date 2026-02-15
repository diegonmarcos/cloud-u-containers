import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rustApiGet, rawHttpRequest } from "../utils/http.js";

export function registerRustApiProxyTools(server: McpServer) {
  server.tool(
    "service_api_call",
    "Call any discovered service API endpoint. First use service_get_spec to understand available endpoints, then use this tool to make the actual call. Resolves service domain via Rust API discovery.",
    {
      service: z.string().describe("Service name (e.g. authelia, matomo, photoprism)"),
      method: z.enum(["GET", "POST", "PUT", "DELETE", "PATCH"]).optional().describe("HTTP method (default: GET)"),
      path: z.string().describe("API path on the service (e.g. /api/verify, /index.php?module=API)"),
      body: z.string().optional().describe("JSON request body for POST/PUT/PATCH"),
      headers: z.string().optional().describe("Extra headers as JSON object (e.g. {\"Authorization\": \"Bearer ...\"})"),
    },
    async ({ service, method, path, body, headers }) => {
      // Step 1: Resolve service domain via discovery API
      const infoResult = rustApiGet(`/api/services/${encodeURIComponent(service)}`);
      if (!infoResult.ok) {
        return {
          content: [{
            type: "text" as const,
            text: `Failed to resolve service "${service}": ${infoResult.error ?? "unknown"}\n${infoResult.raw}`,
          }],
          isError: true,
        };
      }

      // Extract domain from service info
      const info = infoResult.data as Record<string, unknown>;
      const domain = info.domain as string | undefined;
      if (!domain) {
        return {
          content: [{
            type: "text" as const,
            text: `Service "${service}" has no domain configured.\nInfo: ${JSON.stringify(info, null, 2)}`,
          }],
          isError: true,
        };
      }

      // Step 2: Construct URL and make the call
      const httpMethod = method ?? "GET";
      const url = `https://${domain}${path}`;

      // Parse extra headers if provided
      let extraHeaders: Record<string, string> | undefined;
      if (headers) {
        try {
          extraHeaders = JSON.parse(headers) as Record<string, string>;
        } catch {
          return {
            content: [{
              type: "text" as const,
              text: `Invalid headers JSON: ${headers}`,
            }],
            isError: true,
          };
        }
      }

      const result = rawHttpRequest(httpMethod, url, body, 30_000, extraHeaders);

      const responseText = typeof result.data === "string"
        ? result.data
        : JSON.stringify(result.data, null, 2);

      // Truncate very large responses
      const truncated = responseText.length > 10000
        ? `...(truncated)\n${responseText.slice(-10000)}`
        : responseText;

      return {
        content: [{
          type: "text" as const,
          text: [
            `${httpMethod} ${url}: ${result.ok ? "OK" : "FAILED"} (HTTP ${result.status})`,
            "",
            truncated,
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    }
  );
}
