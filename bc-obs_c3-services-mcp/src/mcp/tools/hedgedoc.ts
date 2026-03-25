import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const HEDGEDOC_BASE = "http://10.0.0.6:3018";

function hdApi(method: string, path: string, body?: string): string {
  const token = process.env.HEDGEDOC_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${HEDGEDOC_BASE}/api/v2${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerHedgedocTools(server: McpServer) {
  server.tool(
    "user.hedgedoc.notes",
    "List all notes accessible to the user",
    {},
    async () => ({
      content: [{ type: "text" as const, text: hdApi("GET", "/me/notes") }],
    })
  );

  server.tool(
    "user.hedgedoc.note_detail",
    "Get note metadata by alias or ID",
    { id: z.string().describe("Note ID or alias") },
    async ({ id }) => ({
      content: [{ type: "text" as const, text: hdApi("GET", `/notes/${encodeURIComponent(id)}`) }],
    })
  );

  server.tool(
    "user.hedgedoc.note_content",
    "Get raw markdown content of a note",
    { id: z.string().describe("Note ID or alias") },
    async ({ id }) => ({
      content: [{ type: "text" as const, text: hdApi("GET", `/notes/${encodeURIComponent(id)}/content`) }],
    })
  );

  server.tool(
    "user.hedgedoc.note_create",
    "Create a new note",
    {
      content: z.string().describe("Markdown content"),
      alias: z.string().optional().describe("URL-friendly alias"),
    },
    async ({ content, alias }) => {
      const payload: Record<string, unknown> = { content };
      if (alias) payload.alias = alias;
      return {
        content: [{ type: "text" as const, text: hdApi("POST", "/notes", JSON.stringify(payload)) }],
      };
    }
  );

  server.tool(
    "user.hedgedoc.note_delete",
    "Delete a note by ID",
    { id: z.string().describe("Note ID") },
    async ({ id }) => ({
      content: [{ type: "text" as const, text: hdApi("DELETE", `/notes/${encodeURIComponent(id)}`) }],
    })
  );

  server.tool(
    "user.hedgedoc.me",
    "Get current user profile info",
    {},
    async () => ({
      content: [{ type: "text" as const, text: hdApi("GET", "/me") }],
    })
  );

  server.tool(
    "user.hedgedoc.history",
    "Get note edit history for current user",
    {},
    async () => ({
      content: [{ type: "text" as const, text: hdApi("GET", "/me/history") }],
    })
  );
}
