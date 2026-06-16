import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const ETHERPAD_BASE = "http://10.0.0.6:3012";

function epApi(method: string, params: Record<string, string> = {}): string {
  const apiKey = process.env.ETHERPAD_API_KEY ?? "";
  const qs = new URLSearchParams({ apikey: apiKey, ...params });
  const result = rawHttpRequest("GET", `${ETHERPAD_BASE}/api/1.3.0/${method}?${qs}`, undefined, 15_000);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerEtherpadTools(server: McpServer) {
  server.tool(
    "user.etherpad.pads",
    "List all pad IDs",
    {},
    async () => ({
      content: [{ type: "text" as const, text: epApi("listAllPads") }],
    })
  );

  server.tool(
    "user.etherpad.pad_text",
    "Get the text content of a pad",
    { pad_id: z.string().describe("Pad ID") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("getText", { padID: pad_id }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_html",
    "Get the HTML content of a pad",
    { pad_id: z.string().describe("Pad ID") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("getHTML", { padID: pad_id }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_create",
    "Create a new pad (optionally with initial text)",
    {
      pad_id: z.string().describe("Pad ID to create"),
      text: z.string().optional().describe("Initial text content"),
    },
    async ({ pad_id, text }) => {
      const params: Record<string, string> = { padID: pad_id };
      if (text) params.text = text;
      return {
        content: [{ type: "text" as const, text: epApi("createPad", params) }],
      };
    }
  );

  server.tool(
    "user.etherpad.pad_set_text",
    "Replace all text in a pad",
    { pad_id: z.string().describe("Pad ID"), text: z.string().describe("New text content") },
    async ({ pad_id, text }) => ({
      content: [{ type: "text" as const, text: epApi("setText", { padID: pad_id, text }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_delete",
    "Delete a pad",
    { pad_id: z.string().describe("Pad ID to delete") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("deletePad", { padID: pad_id }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_revisions",
    "Get revision count for a pad",
    { pad_id: z.string().describe("Pad ID") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("getRevisionsCount", { padID: pad_id }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_authors",
    "List authors who edited a pad",
    { pad_id: z.string().describe("Pad ID") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("listAuthorsOfPad", { padID: pad_id }) }],
    })
  );

  server.tool(
    "user.etherpad.pad_users",
    "Get currently connected users on a pad",
    { pad_id: z.string().describe("Pad ID") },
    async ({ pad_id }) => ({
      content: [{ type: "text" as const, text: epApi("padUsersCount", { padID: pad_id }) }],
    })
  );
}
