import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const DAGU_BASE = process.env.DAGU_API_URL ?? "http://10.0.0.3:8070";
const DAGU_AUTH = process.env.DAGU_BASIC_AUTH ?? "";

function daguHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};
  if (DAGU_AUTH) {
    headers["Authorization"] = `Basic ${Buffer.from(DAGU_AUTH).toString("base64")}`;
  }
  return headers;
}

export function registerDaguTools(server: McpServer) {
  server.tool(
    "infra.dagu.list",
    "List available Dagu DAG workflows",
    {},
    async () => {
      const result = rawHttpRequest("GET", `${DAGU_BASE}/api/v2/dags`, undefined, 10000, daguHeaders());
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );

  server.tool(
    "infra.dagu.trigger",
    "Trigger a Dagu DAG workflow by name",
    {
      dag_id: z.string().describe("DAG ID or name to trigger"),
      params: z.string().optional().describe("Optional parameters as key=value pairs"),
    },
    async ({ dag_id, params }) => {
      const body = params ? JSON.stringify({ params }) : undefined;
      const result = rawHttpRequest("POST", `${DAGU_BASE}/api/v2/dags/${dag_id}`, body, 15000, daguHeaders());
      return {
        content: [{ type: "text" as const, text: JSON.stringify(result.ok ? result.data : { error: result.error }, null, 2) }],
      };
    }
  );
}
