import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

// scrappers-api on oci-apps host-net, wg0-bound (:3020). Internal WG call bypasses the Caddy 2FA edge.
const SCRAPPERS_BASE = "http://10.0.0.6:3020/scrappers";

function scrappersApi(method: string, path: string, body?: string): string {
  const result = rawHttpRequest(method, `${SCRAPPERS_BASE}${path}`, body, 120_000, {});
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerScrappersTools(server: McpServer) {
  server.tool(
    "infra.scrappers.health",
    "scrappers-api health + available platforms/targets",
    {},
    async () => ({ content: [{ type: "text" as const, text: scrappersApi("GET", "/health") }] })
  );

  server.tool(
    "infra.scrappers.targets",
    "List the data-driven scrape targets (scrappers.json)",
    {},
    async () => ({ content: [{ type: "text" as const, text: scrappersApi("GET", "/targets") }] })
  );

  server.tool(
    "infra.scrappers.scrape",
    "Scrape a profile/board now. platform ∈ {instagram, pinterest, linkedin, crawl}",
    {
      platform: z.enum(["instagram", "pinterest", "linkedin", "crawl"]).describe("Scraper platform"),
      handle: z.string().optional().describe("Instagram handle"),
      board_url: z.string().optional().describe("Pinterest board URL"),
      url: z.string().optional().describe("Crawl URL"),
      selector: z.string().optional().describe("Crawl CSS selector → text list"),
    },
    async ({ platform, ...params }) => {
      const body = JSON.stringify(Object.fromEntries(Object.entries(params).filter(([, v]) => v != null)));
      return { content: [{ type: "text" as const, text: scrappersApi("POST", `/scrape/${platform}`, body) }] };
    }
  );

  server.tool(
    "infra.scrappers.run",
    "Run a configured target by id (as Dagu does on schedule)",
    { target_id: z.string().describe("Target id from /targets") },
    async ({ target_id }) => ({
      content: [{ type: "text" as const, text: scrappersApi("POST", `/run/${encodeURIComponent(target_id)}`) }],
    })
  );
}
