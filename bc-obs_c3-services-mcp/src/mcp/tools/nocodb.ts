import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const NOCODB_BASE = "http://10.0.0.6:8085";

function nocoApi(method: string, path: string, body?: string): string {
  const token = process.env.NOCODB_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["xc-token"] = token;
  const result = rawHttpRequest(method, `${NOCODB_BASE}${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerNocodbTools(server: McpServer) {
  server.tool(
    "nocodb-bases",
    "List all NocoDB bases (projects)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: nocoApi("GET", "/api/v2/meta/bases") }],
    })
  );

  server.tool(
    "nocodb-tables",
    "List tables in a base",
    { base_id: z.string().describe("Base ID") },
    async ({ base_id }) => ({
      content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/meta/bases/${encodeURIComponent(base_id)}/tables`) }],
    })
  );

  server.tool(
    "nocodb-rows",
    "List rows from a table",
    {
      table_id: z.string().describe("Table ID"),
      limit: z.number().default(25).describe("Max rows"),
      offset: z.number().default(0).describe("Offset for pagination"),
      where: z.string().optional().describe("Filter condition (e.g. 'Status,eq,Active')"),
      sort: z.string().optional().describe("Sort field (prefix with - for desc)"),
    },
    async ({ table_id, limit, offset, where, sort }) => {
      const params = new URLSearchParams({ limit: String(limit), offset: String(offset) });
      if (where) params.set("where", where);
      if (sort) params.set("sort", sort);
      return {
        content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/tables/${encodeURIComponent(table_id)}/records?${params}`) }],
      };
    }
  );

  server.tool(
    "nocodb-row_create",
    "Create a new row in a table",
    {
      table_id: z.string().describe("Table ID"),
      data: z.string().describe("JSON object with field:value pairs"),
    },
    async ({ table_id, data }) => ({
      content: [{ type: "text" as const, text: nocoApi("POST", `/api/v2/tables/${encodeURIComponent(table_id)}/records`, data) }],
    })
  );

  server.tool(
    "nocodb-row_update",
    "Update an existing row",
    {
      table_id: z.string().describe("Table ID"),
      row_id: z.string().describe("Row ID"),
      data: z.string().describe("JSON object with field:value pairs to update"),
    },
    async ({ table_id, row_id, data }) => ({
      content: [{ type: "text" as const, text: nocoApi("PATCH", `/api/v2/tables/${encodeURIComponent(table_id)}/records`, JSON.stringify([{ Id: row_id, ...JSON.parse(data) }])) }],
    })
  );

  server.tool(
    "nocodb-row_delete",
    "Delete a row from a table",
    {
      table_id: z.string().describe("Table ID"),
      row_id: z.string().describe("Row ID"),
    },
    async ({ table_id, row_id }) => ({
      content: [{ type: "text" as const, text: nocoApi("DELETE", `/api/v2/tables/${encodeURIComponent(table_id)}/records`, JSON.stringify([{ Id: row_id }])) }],
    })
  );

  server.tool(
    "nocodb-table_info",
    "Get table schema (fields, types, constraints)",
    { table_id: z.string().describe("Table ID") },
    async ({ table_id }) => ({
      content: [{ type: "text" as const, text: nocoApi("GET", `/api/v2/meta/tables/${encodeURIComponent(table_id)}`) }],
    })
  );
}
