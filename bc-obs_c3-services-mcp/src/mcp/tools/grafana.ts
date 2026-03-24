import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const GRAFANA_BASE = "http://10.0.0.6:3200";

function grafanaApi(method: string, path: string, body?: string): string {
  const token = process.env.GRAFANA_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${GRAFANA_BASE}${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerGrafanaTools(server: McpServer) {
  server.tool(
    "grafana-health",
    "Check Grafana server health",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/health") }],
    })
  );

  server.tool(
    "grafana-dashboards",
    "Search dashboards",
    {
      query: z.string().default("").describe("Search query (empty for all)"),
      limit: z.number().default(20).describe("Max results"),
    },
    async ({ query, limit }) => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", `/api/search?query=${encodeURIComponent(query)}&limit=${limit}&type=dash-db`) }],
    })
  );

  server.tool(
    "grafana-dashboard_detail",
    "Get full dashboard by UID",
    { uid: z.string().describe("Dashboard UID") },
    async ({ uid }) => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", `/api/dashboards/uid/${encodeURIComponent(uid)}`) }],
    })
  );

  server.tool(
    "grafana-datasources",
    "List all configured datasources",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/datasources") }],
    })
  );

  server.tool(
    "grafana-alerts",
    "List alert rules",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/v1/provisioning/alert-rules") }],
    })
  );

  server.tool(
    "grafana-alert_state",
    "Get current alert instances (firing, pending, normal)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/alertmanager/grafana/api/v2/alerts") }],
    })
  );

  server.tool(
    "grafana-annotations",
    "List annotations (events) on dashboards",
    {
      from: z.string().optional().describe("Start time (epoch ms or ISO)"),
      to: z.string().optional().describe("End time (epoch ms or ISO)"),
      limit: z.number().default(50).describe("Max results"),
    },
    async ({ from, to, limit }) => {
      const params = new URLSearchParams({ limit: String(limit) });
      if (from) params.set("from", from);
      if (to) params.set("to", to);
      return {
        content: [{ type: "text" as const, text: grafanaApi("GET", `/api/annotations?${params}`) }],
      };
    }
  );

  server.tool(
    "grafana-annotation_create",
    "Create an annotation on a dashboard",
    {
      text: z.string().describe("Annotation text"),
      dashboardUID: z.string().optional().describe("Dashboard UID (omit for org-level)"),
      tags: z.array(z.string()).optional().describe("Tags for the annotation"),
    },
    async ({ text, dashboardUID, tags }) => {
      const payload: Record<string, unknown> = { text };
      if (dashboardUID) payload.dashboardUID = dashboardUID;
      if (tags) payload.tags = tags;
      return {
        content: [{ type: "text" as const, text: grafanaApi("POST", "/api/annotations", JSON.stringify(payload)) }],
      };
    }
  );

  server.tool(
    "grafana-folders",
    "List dashboard folders",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/folders") }],
    })
  );

  server.tool(
    "grafana-org",
    "Get current org info and stats",
    {},
    async () => ({
      content: [{ type: "text" as const, text: grafanaApi("GET", "/api/org") }],
    })
  );
}
