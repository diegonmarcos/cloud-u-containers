import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { getOctocodeRepos } from "../../shared/libs/paths.js";

const exec = promisify(execFile);
const OCTOCODE_BIN = process.env.OCTOCODE_BIN ?? "octocode";
// REPOS: local repo name -> checkout dir, data-driven from build.json
// .runtime.octocode.index_repos (via shared/libs/paths.ts's GIT_BASE, which
// itself prefers $GIT_ROOT — the env var compose.nix actually sets). Replaces
// a hardcoded map that still held PRE-RENAME names (cloud, unix, tools) long
// after the cloud-* rename — octocode returns EMPTY results for an unknown
// project key (no error), so the drift silently served nothing for every
// renamed repo. 2026-08-21.
const REPOS: Record<string, string> = getOctocodeRepos();
// z.enum's TS type wants a non-empty tuple; the values themselves are only
// known at runtime (from build.json). If the config load ever fails,
// getOctocodeRepoConfig() degrades to an empty list (see paths.ts) rather
// than falling back to a fresh hardcoded list — an empty enum just refuses
// every repo value instead of silently resolving to the wrong directory.
const REPO_ENUM = Object.keys(REPOS) as [string, ...string[]];

async function runOctocode(args: string[], cwd?: string): Promise<string> {
  try {
    const { stdout, stderr } = await exec(OCTOCODE_BIN, args, {
      timeout: 60_000,
      maxBuffer: 10 * 1024 * 1024,
      ...(cwd ? { cwd } : {}),
    });
    return stdout || stderr || "(no output)";
  } catch (err: unknown) {
    const e = err as { code?: string; message?: string };
    if (e.code === "ENOENT") {
      return `Octocode binary not found at "${OCTOCODE_BIN}". Install: cargo install octocode (https://github.com/Muvon/octocode)`;
    }
    return `Octocode error: ${e.message ?? String(err)}`;
  }
}

export function registerOctocodeTools(server: McpServer): void {
  server.tool(
    "cgc.octocode.search",
    "Semantic code search across indexed repositories using Octocode",
    {
      query: z.string().describe("Natural language or code search query"),
      repo: z.enum(REPO_ENUM).describe("Repository to search in"),
      mode: z.enum(["all", "code", "docs", "text"]).optional().describe("Search mode (default: all)"),
      format: z.enum(["json", "md", "text"]).optional().describe("Output format (default: text)"),
      threshold: z.number().optional().describe("Similarity threshold 0.0-1.0 (higher = stricter, default: 0.3)"),
    },
    async ({ query, repo, mode, format, threshold }) => {
      const args = ["search", query, "--format", format ?? "text", "--threshold", String(threshold ?? 0.3)];
      if (mode) args.push("--mode", mode);
      const cwd = REPOS[repo];
      if (!cwd) return { content: [{ type: "text" as const, text: `Unknown repo: ${repo}` }] };
      const result = await runOctocode(args, cwd);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );

  server.tool(
    "cgc.octocode.graphrag",
    "Query the code relationship graph (GraphRAG) — search nodes, get relationships, find paths between files, or get an overview of the graph structure",
    {
      operation: z.enum(["search", "get-node", "get-relationships", "find-path", "overview"]).describe("GraphRAG operation: search (semantic query), get-node (node details), get-relationships (node edges), find-path (path between two nodes), overview (graph summary)"),
      repo: z.enum(REPO_ENUM).describe("Repository to query"),
      query: z.string().optional().describe("Search query (required for 'search' operation)"),
      node_id: z.string().optional().describe("Node ID (required for 'get-node' and 'get-relationships')"),
      source_id: z.string().optional().describe("Source node ID (required for 'find-path')"),
      target_id: z.string().optional().describe("Target node ID (required for 'find-path')"),
      max_depth: z.number().optional().describe("Max path depth for 'find-path' (default: 3)"),
      format: z.enum(["json", "md", "text"]).optional().describe("Output format (default: text)"),
    },
    async ({ operation, repo, query, node_id, source_id, target_id, max_depth, format }) => {
      const cwd = REPOS[repo];
      if (!cwd) return { content: [{ type: "text" as const, text: `Unknown repo: ${repo}` }] };
      const args = ["graphrag", operation, "--format", format ?? "text"];
      if (query) args.push("--query", query);
      if (node_id) args.push("--node-id", node_id);
      if (source_id) args.push("--source-id", source_id);
      if (target_id) args.push("--target-id", target_id);
      if (max_depth != null) args.push("--max-depth", String(max_depth));
      const result = await runOctocode(args, cwd);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );

  server.tool(
    "cgc.octocode.index",
    "Trigger Octocode to (re-)index a repository or directory",
    {
      path: z.string().describe("Absolute path to the repository or directory to index"),
    },
    async ({ path }) => {
      const result = await runOctocode(["index"], path);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );
}
