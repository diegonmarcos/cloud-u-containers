import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);
const OCTOCODE_BIN = process.env.OCTOCODE_BIN ?? "octocode";

async function runOctocode(args: string[]): Promise<string> {
  try {
    const { stdout, stderr } = await exec(OCTOCODE_BIN, args, {
      timeout: 60_000,
      maxBuffer: 10 * 1024 * 1024,
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
    "octocode_search",
    "Semantic code search across indexed repositories using Octocode",
    {
      query: z.string().describe("Natural language or code search query"),
      path: z.string().optional().describe("Limit search to a specific directory path"),
      limit: z.number().optional().default(10).describe("Max results to return"),
    },
    async ({ query, path, limit }) => {
      const args = ["search", query, "--limit", String(limit ?? 10)];
      if (path) args.push("--path", path);
      const result = await runOctocode(args);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );

  server.tool(
    "octocode_memory",
    "Query Octocode's code memory — semantic summaries of indexed files and functions",
    {
      query: z.string().describe("What to look up in code memory"),
    },
    async ({ query }) => {
      const result = await runOctocode(["memory", "search", query]);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );

  server.tool(
    "octocode_index",
    "Trigger Octocode to (re-)index a repository or directory",
    {
      path: z.string().describe("Absolute path to the repository or directory to index"),
    },
    async ({ path }) => {
      const result = await runOctocode(["index", path]);
      return { content: [{ type: "text" as const, text: result }] };
    }
  );
}
