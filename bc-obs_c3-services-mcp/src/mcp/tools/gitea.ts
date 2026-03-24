import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { rawHttpRequest } from "../../shared/http.js";

const GITEA_BASE = "http://10.0.0.6:3017";

function giteaApi(method: string, path: string, body?: string): string {
  const token = process.env.GITEA_API_TOKEN ?? "";
  const headers: Record<string, string> = {};
  if (token) headers["Authorization"] = `token ${token}`;
  const result = rawHttpRequest(method, `${GITEA_BASE}/api/v1${path}`, body, 15_000, headers);
  return JSON.stringify(result.ok ? result.data : { error: result.error, status: result.status }, null, 2);
}

export function registerGiteaTools(server: McpServer) {
  server.tool(
    "gitea-repos",
    "List repositories (optionally filter by owner)",
    { owner: z.string().optional().describe("Owner username (omit for all accessible repos)"), limit: z.number().default(20).describe("Max results") },
    async ({ owner, limit }) => ({
      content: [{ type: "text" as const, text: owner
        ? giteaApi("GET", `/repos/search?q=&owner=${encodeURIComponent(owner)}&limit=${limit}`)
        : giteaApi("GET", `/repos/search?limit=${limit}`) }],
    })
  );

  server.tool(
    "gitea-repo_detail",
    "Get details for a specific repository",
    { owner: z.string().describe("Repo owner"), repo: z.string().describe("Repo name") },
    async ({ owner, repo }) => ({
      content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}`) }],
    })
  );

  server.tool(
    "gitea-issues",
    "List issues for a repository",
    {
      owner: z.string().describe("Repo owner"),
      repo: z.string().describe("Repo name"),
      state: z.enum(["open", "closed", "all"]).default("open").describe("Issue state filter"),
      limit: z.number().default(20).describe("Max results"),
    },
    async ({ owner, repo, state, limit }) => ({
      content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues?state=${state}&limit=${limit}&type=issues`) }],
    })
  );

  server.tool(
    "gitea-issue_create",
    "Create a new issue in a repository",
    {
      owner: z.string().describe("Repo owner"),
      repo: z.string().describe("Repo name"),
      title: z.string().describe("Issue title"),
      body: z.string().optional().describe("Issue body (markdown)"),
      labels: z.array(z.number()).optional().describe("Label IDs"),
    },
    async ({ owner, repo, title, body: issueBody, labels }) => {
      const payload: Record<string, unknown> = { title };
      if (issueBody) payload.body = issueBody;
      if (labels) payload.labels = labels;
      return {
        content: [{ type: "text" as const, text: giteaApi("POST", `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/issues`, JSON.stringify(payload)) }],
      };
    }
  );

  server.tool(
    "gitea-pulls",
    "List pull requests for a repository",
    {
      owner: z.string().describe("Repo owner"),
      repo: z.string().describe("Repo name"),
      state: z.enum(["open", "closed", "all"]).default("open").describe("PR state filter"),
    },
    async ({ owner, repo, state }) => ({
      content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/pulls?state=${state}`) }],
    })
  );

  server.tool(
    "gitea-users",
    "Search users",
    { q: z.string().describe("Search query"), limit: z.number().default(10).describe("Max results") },
    async ({ q, limit }) => ({
      content: [{ type: "text" as const, text: giteaApi("GET", `/users/search?q=${encodeURIComponent(q)}&limit=${limit}`) }],
    })
  );

  server.tool(
    "gitea-orgs",
    "List organizations",
    {},
    async () => ({
      content: [{ type: "text" as const, text: giteaApi("GET", "/user/orgs") }],
    })
  );

  server.tool(
    "gitea-releases",
    "List releases for a repository",
    { owner: z.string().describe("Repo owner"), repo: z.string().describe("Repo name") },
    async ({ owner, repo }) => ({
      content: [{ type: "text" as const, text: giteaApi("GET", `/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repo)}/releases`) }],
    })
  );
}
