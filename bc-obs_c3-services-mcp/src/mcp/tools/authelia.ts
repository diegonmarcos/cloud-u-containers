import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const AUTHELIA_BASE = "http://10.0.0.1:9091";

function autheliaApi(path: string, extraHeaders?: Record<string, string>): string {
  const result = rawHttpRequest("GET", `${AUTHELIA_BASE}${path}`, undefined, 10_000, extraHeaders);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerAutheliaTools(server: McpServer) {
  server.tool(
    "infra.authelia.health",
    "Check Authelia server health",
    {},
    async () => ({
      content: [{ type: "text" as const, text: autheliaApi("/api/health") }],
    })
  );

  server.tool(
    "infra.authelia.state",
    "Get Authelia state (config validation, ready status)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: autheliaApi("/api/state") }],
    })
  );

  server.tool(
    "infra.authelia.config",
    "Get Authelia OIDC discovery configuration",
    {},
    async () => ({
      content: [{ type: "text" as const, text: autheliaApi("/.well-known/openid-configuration") }],
    })
  );

  server.tool(
    "infra.authelia.jwks",
    "Get Authelia JSON Web Key Set (public keys)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: autheliaApi("/jwks.json") }],
    })
  );

  server.tool(
    "infra.authelia.user_info",
    "Get user info via OIDC userinfo endpoint (requires bearer token)",
    { token: z.string().describe("OIDC access token") },
    async ({ token }) => ({
      content: [{ type: "text" as const, text: autheliaApi("/api/oidc/userinfo", { Authorization: `Bearer ${token}` }) }],
    })
  );
}
