import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const MATOMO_BASE = "http://10.0.0.4:8080";

function matomoApiCall(method: string, params: Record<string, string> = {}): string {
  const token = process.env.MATOMO_API_TOKEN ?? "";
  const qs = new URLSearchParams({
    module: "API",
    method,
    format: "JSON",
    token_auth: token,
    ...params,
  });
  const result = rawHttpRequest("GET", `${MATOMO_BASE}/?${qs.toString()}`);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerMatomoTools(server: McpServer) {
  server.tool(
    "infra.matomo.visits",
    "Get visit summary from Matomo analytics",
    {
      idSite: z.string().default("1").describe("Site ID"),
      period: z.string().default("day").describe("Period: day, week, month, year"),
      date: z.string().default("today").describe("Date or range"),
    },
    async ({ idSite, period, date }) => ({
      content: [{ type: "text" as const, text: matomoApiCall("VisitsSummary.get", { idSite, period, date }) }],
    })
  );

  server.tool(
    "infra.matomo.sites",
    "List all tracked sites in Matomo",
    {},
    async () => ({
      content: [{ type: "text" as const, text: matomoApiCall("SitesManager.getAllSites") }],
    })
  );

  server.tool(
    "infra.matomo.actions",
    "Get page view and action stats from Matomo",
    {
      idSite: z.string().default("1"),
      period: z.string().default("day"),
      date: z.string().default("today"),
    },
    async ({ idSite, period, date }) => ({
      content: [{ type: "text" as const, text: matomoApiCall("Actions.get", { idSite, period, date }) }],
    })
  );

  server.tool(
    "infra.matomo.referrers",
    "Get referrer stats from Matomo",
    {
      idSite: z.string().default("1"),
      period: z.string().default("day"),
      date: z.string().default("today"),
    },
    async ({ idSite, period, date }) => ({
      content: [{ type: "text" as const, text: matomoApiCall("Referrers.get", { idSite, period, date }) }],
    })
  );

  server.tool(
    "infra.matomo.live",
    "Get last visits (live) from Matomo",
    {
      idSite: z.string().default("1"),
      period: z.string().default("day"),
      date: z.string().default("today"),
    },
    async ({ idSite, period, date }) => ({
      content: [{ type: "text" as const, text: matomoApiCall("Live.getLastVisitsDetails", { idSite, period, date }) }],
    })
  );
}
