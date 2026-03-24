import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const GH_API = "https://api.github.com";
const GH_TOKEN = process.env.GITHUB_TOKEN ?? "";
const GH_OWNER = process.env.GH_OWNER ?? "diegonmarcos";

function ghHeaders(): Record<string, string> {
  return {
    "Authorization": `Bearer ${GH_TOKEN}`,
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
}

export function registerGithubTools(server: McpServer) {
  server.tool(
    "gha_list_runs",
    "List recent GitHub Actions workflow runs for a repository",
    {
      repo: z.string().describe("Repository name (e.g. 'cloud')"),
      per_page: z.number().optional().describe("Number of runs to return (default 5)"),
    },
    async ({ repo, per_page }) => {
      const limit = per_page ?? 5;
      const result = rawHttpRequest(
        "GET",
        `${GH_API}/repos/${GH_OWNER}/${repo}/actions/runs?per_page=${limit}`,
        undefined,
        10000,
        ghHeaders()
      );
      if (!result.ok) {
        return { content: [{ type: "text" as const, text: JSON.stringify({ error: result.error }) }] };
      }
      const data = result.data as { workflow_runs?: Array<Record<string, unknown>> };
      const runs = (data.workflow_runs ?? []).map((r) => ({
        id: r.id,
        name: r.name,
        status: r.status,
        conclusion: r.conclusion,
        branch: r.head_branch,
        created_at: r.created_at,
        html_url: r.html_url,
      }));
      return { content: [{ type: "text" as const, text: JSON.stringify(runs, null, 2) }] };
    }
  );

  server.tool(
    "gha_trigger",
    "Trigger a GitHub Actions workflow via workflow_dispatch",
    {
      repo: z.string().describe("Repository name (e.g. 'cloud')"),
      workflow: z.string().describe("Workflow filename (e.g. 'ship-oci-apps.yml')"),
      ref: z.string().optional().describe("Git ref to run on (default 'main')"),
      inputs: z.record(z.string()).optional().describe("Workflow dispatch inputs"),
    },
    async ({ repo, workflow, ref: gitRef, inputs }) => {
      const body = JSON.stringify({
        ref: gitRef ?? "main",
        ...(inputs ? { inputs } : {}),
      });
      const result = rawHttpRequest(
        "POST",
        `${GH_API}/repos/${GH_OWNER}/${repo}/actions/workflows/${workflow}/dispatches`,
        body,
        15000,
        ghHeaders()
      );
      if (result.status === 204 || result.ok) {
        return { content: [{ type: "text" as const, text: JSON.stringify({ status: "triggered", workflow, repo }) }] };
      }
      return { content: [{ type: "text" as const, text: JSON.stringify({ error: result.error, status: result.status }) }] };
    }
  );
}
