import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { getService } from "../../shared/discovery.js";
import { rawHttpRequest, getBearerToken } from "../../shared/http.js";

export function registerDiscoveryTools(server: McpServer) {
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
      // Step 1: Resolve service domain via discovery
      const info = getService(service);
      if (!info) {
        return {
          content: [{ type: "text" as const, text: `Unknown service: "${service}"` }],
          isError: true,
        };
      }

      const domain = info.domain;
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
            content: [{ type: "text" as const, text: `Invalid headers JSON: ${headers}` }],
            isError: true,
          };
        }
      }

      // Auto-add bearer token if not provided
      if (!extraHeaders?.["Authorization"]) {
        const token = getBearerToken();
        if (token) {
          extraHeaders = { ...extraHeaders, Authorization: `Bearer ${token}` };
        }
      }

      const result = rawHttpRequest(httpMethod, url, body, 30_000, extraHeaders);

      const responseText = typeof result.data === "string"
        ? result.data
        : JSON.stringify(result.data, null, 2);

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
    },
  );
}
