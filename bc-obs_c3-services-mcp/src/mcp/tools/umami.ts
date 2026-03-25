import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const UMAMI_BASE = "http://10.0.0.4:3000";

function umamiApi(method: string, path: string, body?: string): string {
  const token = process.env.UMAMI_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${UMAMI_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerUmamiTools(server: McpServer) {
  server.tool(
    "infra.umami.websites",
    "List tracked websites",
    {},
    async () => ({
      content: [{ type: "text" as const, text: umamiApi("GET", "/websites") }],
    })
  );

  server.tool(
    "infra.umami.website_stats",
    "Get stats summary for a website (pageviews, visitors, bounces)",
    {
      website_id: z.string().describe("Website UUID"),
      start_at: z.string().describe("Start timestamp (epoch ms) or ISO date"),
      end_at: z.string().describe("End timestamp (epoch ms) or ISO date"),
    },
    async ({ website_id, start_at, end_at }) => ({
      content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(website_id)}/stats?startAt=${encodeURIComponent(start_at)}&endAt=${encodeURIComponent(end_at)}`) }],
    })
  );

  server.tool(
    "infra.umami.pageviews",
    "Get pageview stats over time for a website",
    {
      website_id: z.string().describe("Website UUID"),
      start_at: z.string().describe("Start timestamp"),
      end_at: z.string().describe("End timestamp"),
      unit: z.enum(["hour", "day", "week", "month"]).default("day").describe("Time bucket unit"),
    },
    async ({ website_id, start_at, end_at, unit }) => ({
      content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(website_id)}/pageviews?startAt=${encodeURIComponent(start_at)}&endAt=${encodeURIComponent(end_at)}&unit=${unit}`) }],
    })
  );

  server.tool(
    "infra.umami.metrics",
    "Get metrics breakdown (URLs, referrers, browsers, OS, countries, etc.)",
    {
      website_id: z.string().describe("Website UUID"),
      start_at: z.string().describe("Start timestamp"),
      end_at: z.string().describe("End timestamp"),
      type: z.enum(["url", "referrer", "browser", "os", "device", "country", "event"]).describe("Metric type"),
      limit: z.number().default(20).describe("Max results"),
    },
    async ({ website_id, start_at, end_at, type, limit }) => ({
      content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(website_id)}/metrics?startAt=${encodeURIComponent(start_at)}&endAt=${encodeURIComponent(end_at)}&type=${type}&limit=${limit}`) }],
    })
  );

  server.tool(
    "infra.umami.active",
    "Get currently active visitors on a website",
    { website_id: z.string().describe("Website UUID") },
    async ({ website_id }) => ({
      content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(website_id)}/active`) }],
    })
  );

  server.tool(
    "infra.umami.events",
    "Get custom event data for a website",
    {
      website_id: z.string().describe("Website UUID"),
      start_at: z.string().describe("Start timestamp"),
      end_at: z.string().describe("End timestamp"),
    },
    async ({ website_id, start_at, end_at }) => ({
      content: [{ type: "text" as const, text: umamiApi("GET", `/websites/${encodeURIComponent(website_id)}/events?startAt=${encodeURIComponent(start_at)}&endAt=${encodeURIComponent(end_at)}`) }],
    })
  );
}
