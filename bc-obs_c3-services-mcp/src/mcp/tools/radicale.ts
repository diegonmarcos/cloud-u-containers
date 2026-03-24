import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";
import { XMLParser } from "fast-xml-parser";

const RADICALE_BASE = "http://10.0.0.3:5232";

const PROPFIND_BODY = `<?xml version="1.0" encoding="utf-8" ?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:resourcetype/>
    <D:getcontenttype/>
  </D:prop>
</D:propfind>`;

function radicaleRequest(method: string, path: string, body?: string): string {
  const user = process.env.RADICALE_USER ?? "";
  const pass = process.env.RADICALE_PASSWORD ?? "";
  const auth = Buffer.from(`${user}:${pass}`).toString("base64");

  const headers: Record<string, string> = {
    Authorization: `Basic ${auth}`,
  };
  if (body) {
    headers["Content-Type"] = "application/xml; charset=utf-8";
  }

  const result = rawHttpRequest(method, `${RADICALE_BASE}${path}`, body, 10_000, headers);
  if (!result.ok) return JSON.stringify({ error: result.error, status: result.status }, null, 2);

  if (typeof result.raw === "string" && result.raw.includes("<?xml")) {
    const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "@_" });
    return JSON.stringify(parser.parse(result.raw), null, 2);
  }
  return JSON.stringify(result.data, null, 2);
}

export function registerRadicaleTools(server: McpServer) {
  server.tool(
    "radicale-calendars",
    "List calendars in Radicale",
    {},
    async () => {
      const user = process.env.RADICALE_USER ?? "";
      return {
        content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${user}/`, PROPFIND_BODY) }],
      };
    }
  );

  server.tool(
    "radicale-contacts",
    "List contact collections in Radicale",
    {},
    async () => {
      const user = process.env.RADICALE_USER ?? "";
      return {
        content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${user}/`, PROPFIND_BODY) }],
      };
    }
  );

  server.tool(
    "radicale-events",
    "Get events from a Radicale calendar collection",
    {
      collection: z.string().describe("Calendar collection name"),
    },
    async ({ collection }) => {
      const user = process.env.RADICALE_USER ?? "";
      return {
        content: [{ type: "text" as const, text: radicaleRequest("PROPFIND", `/${user}/${collection}/`, PROPFIND_BODY) }],
      };
    }
  );
}
