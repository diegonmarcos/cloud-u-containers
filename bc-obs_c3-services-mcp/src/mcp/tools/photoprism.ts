import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const PHOTOPRISM_BASE = "http://10.0.0.6:3013";

function ppApi(method: string, path: string, body?: string): string {
  const token = process.env.PHOTOPRISM_SESSION_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["X-Session-ID"] = token;
  const result = rawHttpRequest(method, `${PHOTOPRISM_BASE}/api/v1${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerPhotoprismTools(server: McpServer) {
  server.tool(
    "user.photoprism.status",
    "Get PhotoPrism server status and config",
    {},
    async () => ({
      content: [{ type: "text" as const, text: ppApi("GET", "/status") }],
    })
  );

  server.tool(
    "user.photoprism.photos",
    "Search photos with filters",
    {
      q: z.string().default("").describe("Search query (keyword, label, or empty for recent)"),
      count: z.number().default(20).describe("Max results"),
      offset: z.number().default(0).describe("Pagination offset"),
      order: z.string().default("newest").describe("Sort order: newest, oldest, relevance, name"),
    },
    async ({ q, count, offset, order }) => {
      const params = new URLSearchParams({ q, count: String(count), offset: String(offset), order });
      return {
        content: [{ type: "text" as const, text: ppApi("GET", `/photos?${params}`) }],
      };
    }
  );

  server.tool(
    "user.photoprism.photo_detail",
    "Get details for a specific photo by UID",
    { uid: z.string().describe("Photo UID") },
    async ({ uid }) => ({
      content: [{ type: "text" as const, text: ppApi("GET", `/photos/${encodeURIComponent(uid)}`) }],
    })
  );

  server.tool(
    "user.photoprism.albums",
    "List photo albums",
    { count: z.number().default(20).describe("Max results"), q: z.string().default("").describe("Search query") },
    async ({ count, q }) => ({
      content: [{ type: "text" as const, text: ppApi("GET", `/albums?count=${count}&q=${encodeURIComponent(q)}`) }],
    })
  );

  server.tool(
    "user.photoprism.album_photos",
    "List photos in a specific album",
    { uid: z.string().describe("Album UID"), count: z.number().default(50).describe("Max results") },
    async ({ uid, count }) => ({
      content: [{ type: "text" as const, text: ppApi("GET", `/albums/${encodeURIComponent(uid)}/photos?count=${count}`) }],
    })
  );

  server.tool(
    "user.photoprism.labels",
    "List auto-detected labels (AI tags)",
    { count: z.number().default(50).describe("Max results") },
    async ({ count }) => ({
      content: [{ type: "text" as const, text: ppApi("GET", `/labels?count=${count}`) }],
    })
  );

  server.tool(
    "user.photoprism.faces",
    "List recognized faces",
    { count: z.number().default(50).describe("Max results") },
    async ({ count }) => ({
      content: [{ type: "text" as const, text: ppApi("GET", `/faces?count=${count}`) }],
    })
  );

  server.tool(
    "user.photoprism.stats",
    "Get photo library statistics",
    {},
    async () => ({
      content: [{ type: "text" as const, text: ppApi("GET", "/stats") }],
    })
  );
}
