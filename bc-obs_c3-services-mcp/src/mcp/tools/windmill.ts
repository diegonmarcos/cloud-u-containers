import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const WINDMILL_BASE = "http://10.0.0.4:8000";

function wmApi(method: string, path: string, body?: string): string {
  const token = process.env.WINDMILL_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `Bearer ${token}`;
  const result = rawHttpRequest(method, `${WINDMILL_BASE}/api${path}`, body, 30_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerWindmillTools(server: McpServer) {
  server.tool(
    "windmill-scripts",
    "List scripts in a workspace",
    { workspace: z.string().default("admins").describe("Workspace name") },
    async ({ workspace }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/scripts/list`) }],
    })
  );

  server.tool(
    "windmill-script_detail",
    "Get script content and metadata by path",
    { workspace: z.string().default("admins").describe("Workspace"), path: z.string().describe("Script path (e.g. 'f/folder/script')") },
    async ({ workspace, path }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/scripts/get/p/${path}`) }],
    })
  );

  server.tool(
    "windmill-run_script",
    "Execute a script and get the job ID",
    {
      workspace: z.string().default("admins").describe("Workspace"),
      path: z.string().describe("Script path"),
      args: z.string().default("{}").describe("JSON arguments object"),
    },
    async ({ workspace, path, args }) => ({
      content: [{ type: "text" as const, text: wmApi("POST", `/w/${encodeURIComponent(workspace)}/jobs/run/p/${path}`, args) }],
    })
  );

  server.tool(
    "windmill-flows",
    "List flows in a workspace",
    { workspace: z.string().default("admins").describe("Workspace") },
    async ({ workspace }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/flows/list`) }],
    })
  );

  server.tool(
    "windmill-run_flow",
    "Execute a flow and get the job ID",
    {
      workspace: z.string().default("admins").describe("Workspace"),
      path: z.string().describe("Flow path"),
      args: z.string().default("{}").describe("JSON arguments object"),
    },
    async ({ workspace, path, args }) => ({
      content: [{ type: "text" as const, text: wmApi("POST", `/w/${encodeURIComponent(workspace)}/jobs/run/f/${path}`, args) }],
    })
  );

  server.tool(
    "windmill-jobs",
    "List recent jobs (completed and running)",
    { workspace: z.string().default("admins").describe("Workspace"), limit: z.number().default(20).describe("Max results") },
    async ({ workspace, limit }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/jobs/list?per_page=${limit}`) }],
    })
  );

  server.tool(
    "windmill-job_detail",
    "Get details and result of a specific job",
    { workspace: z.string().default("admins").describe("Workspace"), job_id: z.string().describe("Job UUID") },
    async ({ workspace, job_id }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/jobs_u/get/${encodeURIComponent(job_id)}`) }],
    })
  );

  server.tool(
    "windmill-schedules",
    "List scheduled jobs",
    { workspace: z.string().default("admins").describe("Workspace") },
    async ({ workspace }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/schedules/list`) }],
    })
  );

  server.tool(
    "windmill-resources",
    "List resources (secrets, connections, configs)",
    { workspace: z.string().default("admins").describe("Workspace") },
    async ({ workspace }) => ({
      content: [{ type: "text" as const, text: wmApi("GET", `/w/${encodeURIComponent(workspace)}/resources/list`) }],
    })
  );
}
