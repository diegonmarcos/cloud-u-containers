import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const GRIST_BASE = "http://10.0.0.6:3011";

function gristApi(method: string, path: string, body?: string): string {
  const token = process.env.GRIST_API_KEY ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${GRIST_BASE}/api${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerGristTools(server: McpServer) {
  server.tool(
    "grist-orgs",
    "List Grist organizations (workspaces)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: gristApi("GET", "/orgs") }],
    })
  );

  server.tool(
    "grist-docs",
    "List documents in an org/workspace",
    { org_id: z.string().default("current").describe("Org ID or 'current'") },
    async ({ org_id }) => ({
      content: [{ type: "text" as const, text: gristApi("GET", `/orgs/${encodeURIComponent(org_id)}/workspaces`) }],
    })
  );

  server.tool(
    "grist-tables",
    "List tables in a document",
    { doc_id: z.string().describe("Document ID") },
    async ({ doc_id }) => ({
      content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(doc_id)}/tables`) }],
    })
  );

  server.tool(
    "grist-records",
    "Fetch records from a table",
    {
      doc_id: z.string().describe("Document ID"),
      table_id: z.string().describe("Table ID"),
      limit: z.number().default(50).describe("Max records"),
      filter: z.string().optional().describe("JSON filter object (e.g. '{\"Status\":[\"Active\"]}')")
    },
    async ({ doc_id, table_id, limit, filter }) => {
      const params = new URLSearchParams({ limit: String(limit) });
      if (filter) params.set("filter", filter);
      return {
        content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(doc_id)}/tables/${encodeURIComponent(table_id)}/records?${params}`) }],
      };
    }
  );

  server.tool(
    "grist-record_create",
    "Add records to a table",
    {
      doc_id: z.string().describe("Document ID"),
      table_id: z.string().describe("Table ID"),
      records: z.string().describe("JSON array of {fields: {col: value}} objects"),
    },
    async ({ doc_id, table_id, records }) => ({
      content: [{ type: "text" as const, text: gristApi("POST", `/docs/${encodeURIComponent(doc_id)}/tables/${encodeURIComponent(table_id)}/records`, records) }],
    })
  );

  server.tool(
    "grist-record_update",
    "Update records in a table",
    {
      doc_id: z.string().describe("Document ID"),
      table_id: z.string().describe("Table ID"),
      records: z.string().describe("JSON array of {id: N, fields: {col: value}} objects"),
    },
    async ({ doc_id, table_id, records }) => ({
      content: [{ type: "text" as const, text: gristApi("PATCH", `/docs/${encodeURIComponent(doc_id)}/tables/${encodeURIComponent(table_id)}/records`, records) }],
    })
  );

  server.tool(
    "grist-columns",
    "List columns in a table (schema)",
    { doc_id: z.string().describe("Document ID"), table_id: z.string().describe("Table ID") },
    async ({ doc_id, table_id }) => ({
      content: [{ type: "text" as const, text: gristApi("GET", `/docs/${encodeURIComponent(doc_id)}/tables/${encodeURIComponent(table_id)}/columns`) }],
    })
  );
}
