import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const FB_BASE = "http://10.0.0.6:3015";

function fbApi(method: string, path: string, body?: string): string {
  const token = process.env.FILEBROWSER_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["X-Auth"] = token;
  const result = rawHttpRequest(method, `${FB_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerFilebrowserTools(server: McpServer) {
  server.tool(
    "user.filebrowser.ls",
    "List files and directories at a path",
    { path: z.string().default("/").describe("Directory path (e.g. '/' or '/documents')") },
    async ({ path }) => ({
      content: [{ type: "text" as const, text: fbApi("GET", `/resources${path.startsWith("/") ? path : `/${path}`}`) }],
    })
  );

  server.tool(
    "user.filebrowser.info",
    "Get file/directory metadata (size, modified, type)",
    { path: z.string().describe("File or directory path") },
    async ({ path }) => ({
      content: [{ type: "text" as const, text: fbApi("GET", `/resources${path.startsWith("/") ? path : `/${path}`}?checksum=md5`) }],
    })
  );

  server.tool(
    "user.filebrowser.search",
    "Search for files by name pattern",
    { query: z.string().describe("Search query or glob pattern"), path: z.string().default("/").describe("Base path to search in") },
    async ({ query, path }) => ({
      content: [{ type: "text" as const, text: fbApi("GET", `/search${path.startsWith("/") ? path : `/${path}`}?query=${encodeURIComponent(query)}`) }],
    })
  );

  server.tool(
    "user.filebrowser.mkdir",
    "Create a new directory",
    { path: z.string().describe("New directory path") },
    async ({ path }) => ({
      content: [{ type: "text" as const, text: fbApi("POST", `/resources${path.startsWith("/") ? path : `/${path}`}/`) }],
    })
  );

  server.tool(
    "user.filebrowser.delete",
    "Delete a file or directory",
    { path: z.string().describe("Path to delete") },
    async ({ path }) => ({
      content: [{ type: "text" as const, text: fbApi("DELETE", `/resources${path.startsWith("/") ? path : `/${path}`}`) }],
    })
  );

  server.tool(
    "user.filebrowser.move",
    "Move or rename a file/directory",
    {
      src: z.string().describe("Source path"),
      dst: z.string().describe("Destination path"),
    },
    async ({ src, dst }) => ({
      content: [{ type: "text" as const, text: fbApi("PATCH", `/resources${src.startsWith("/") ? src : `/${src}`}`, JSON.stringify({ action: "rename", destination: dst })) }],
    })
  );

  server.tool(
    "user.filebrowser.shares",
    "List active file shares/links",
    {},
    async () => ({
      content: [{ type: "text" as const, text: fbApi("GET", "/shares") }],
    })
  );

  server.tool(
    "user.filebrowser.share_create",
    "Create a share link for a file/directory",
    {
      path: z.string().describe("Path to share"),
      expires: z.string().optional().describe("Expiry (e.g. '24h', '7d')"),
      password: z.string().optional().describe("Optional password protection"),
    },
    async ({ path, expires, password }) => {
      const payload: Record<string, unknown> = { path };
      if (expires) payload.expires = expires;
      if (password) payload.password = password;
      return {
        content: [{ type: "text" as const, text: fbApi("POST", "/shares", JSON.stringify(payload)) }],
      };
    }
  );

  server.tool(
    "user.filebrowser.usage",
    "Get disk usage stats",
    {},
    async () => ({
      content: [{ type: "text" as const, text: fbApi("GET", "/usage") }],
    })
  );
}
