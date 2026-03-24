import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const CRAWLEE_BASE = "http://10.0.0.6:3000";

function crawleeApi(method: string, path: string, body?: string): string {
  const token = process.env.CRAWLEE_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${CRAWLEE_BASE}/api/v1${path}`, body, 30_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerCrawleeTools(server: McpServer) {
  server.tool(
    "crawlee-actors",
    "List available Crawlee actors (scrapers)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", "/actors") }],
    })
  );

  server.tool(
    "crawlee-actor_detail",
    "Get details for a specific actor",
    { actor_id: z.string().describe("Actor ID") },
    async ({ actor_id }) => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", `/actors/${encodeURIComponent(actor_id)}`) }],
    })
  );

  server.tool(
    "crawlee-run_actor",
    "Start an actor run with input",
    {
      actor_id: z.string().describe("Actor ID to run"),
      input: z.string().default("{}").describe("JSON input for the actor"),
    },
    async ({ actor_id, input }) => ({
      content: [{ type: "text" as const, text: crawleeApi("POST", `/actors/${encodeURIComponent(actor_id)}/runs`, input) }],
    })
  );

  server.tool(
    "crawlee-runs",
    "List recent actor runs",
    { limit: z.number().default(20).describe("Max results") },
    async ({ limit }) => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", `/actor-runs?limit=${limit}`) }],
    })
  );

  server.tool(
    "crawlee-run_detail",
    "Get details and status of a specific run",
    { run_id: z.string().describe("Run ID") },
    async ({ run_id }) => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", `/actor-runs/${encodeURIComponent(run_id)}`) }],
    })
  );

  server.tool(
    "crawlee-run_abort",
    "Abort a running actor",
    { run_id: z.string().describe("Run ID to abort") },
    async ({ run_id }) => ({
      content: [{ type: "text" as const, text: crawleeApi("POST", `/actor-runs/${encodeURIComponent(run_id)}/abort`) }],
    })
  );

  server.tool(
    "crawlee-datasets",
    "List datasets (output storage)",
    {},
    async () => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", "/datasets") }],
    })
  );

  server.tool(
    "crawlee-dataset_items",
    "Get items from a dataset",
    { dataset_id: z.string().describe("Dataset ID"), limit: z.number().default(50).describe("Max items") },
    async ({ dataset_id, limit }) => ({
      content: [{ type: "text" as const, text: crawleeApi("GET", `/datasets/${encodeURIComponent(dataset_id)}/items?limit=${limit}`) }],
    })
  );
}
