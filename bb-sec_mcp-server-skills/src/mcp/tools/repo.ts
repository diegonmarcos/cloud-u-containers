import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, readdirSync, statSync } from "fs";
import { join, resolve } from "path";
import { REPOS } from "../../shared/paths.js";
import { exec } from "../../shared/exec.js";

const VALID_REPOS = Object.keys(REPOS);

function validatePath(repo: string, path: string): string {
  const repoBase = REPOS[repo];
  if (!repoBase) throw new Error(`Unknown repo: ${repo}. Valid: ${VALID_REPOS.join(", ")}`);
  const resolved = resolve(repoBase, path);
  if (!resolved.startsWith(repoBase)) {
    throw new Error("Path traversal detected — access denied");
  }
  // Block plaintext secrets in dist/.env
  if (resolved.includes("/dist/.env")) {
    throw new Error("Access to dist/.env files is denied (plaintext secrets)");
  }
  return resolved;
}

export function registerRepoTools(server: McpServer) {
  server.tool(
    "read_file",
    "Read a file from a repository (cloud, unix, vault, front, tools)",
    {
      repo: z.enum(["cloud", "unix", "vault", "front", "tools"]).describe("Repository name"),
      path: z.string().describe("Relative path within the repo"),
      maxLines: z.number().optional().describe("Max lines to read (default: all)"),
    },
    async ({ repo, path, maxLines }) => {
      try {
        const fullPath = validatePath(repo, path);
        let content = readFileSync(fullPath, "utf-8");
        if (maxLines) {
          const lines = content.split("\n");
          content = lines.slice(0, maxLines).join("\n");
          if (lines.length > maxLines) {
            content += `\n\n... (${lines.length - maxLines} more lines truncated)`;
          }
        }
        return { content: [{ type: "text", text: content }] };
      } catch (err: any) {
        return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
      }
    }
  );

  server.tool(
    "search_repos",
    "Search (grep) across repositories for a pattern",
    {
      pattern: z.string().describe("Search pattern (grep -rn)"),
      repo: z.enum(["cloud", "unix", "vault", "front", "tools"]).optional().describe("Limit to specific repo"),
      fileGlob: z.string().optional().describe("File glob filter (e.g. *.nix, *.yaml)"),
      maxResults: z.number().optional().describe("Max results (default: 50)"),
    },
    async ({ pattern, repo, fileGlob, maxResults }) => {
      const limit = maxResults ?? 50;
      const repos = repo ? { [repo]: REPOS[repo] } : REPOS;
      const allResults: string[] = [];

      for (const [name, base] of Object.entries(repos)) {
        const args = ["-rn", "--include", fileGlob ?? "*", "-l", pattern, base];
        const result = exec("grep", args, { timeout: 15_000 });
        if (result.ok && result.stdout.trim()) {
          const files = result.stdout.trim().split("\n");
          for (const file of files) {
            if (allResults.length >= limit) break;
            // Get matching lines
            const lineResult = exec("grep", ["-n", pattern, file], { timeout: 5_000 });
            if (lineResult.ok) {
              const relPath = file.replace(base + "/", "");
              const lines = lineResult.stdout.trim().split("\n").slice(0, 5);
              allResults.push(`[${name}] ${relPath}:\n${lines.join("\n")}`);
            }
          }
        }
      }

      if (allResults.length === 0) {
        return { content: [{ type: "text", text: `No matches for "${pattern}"` }] };
      }

      return {
        content: [
          {
            type: "text",
            text: `Found ${allResults.length} matches:\n\n${allResults.join("\n\n")}`,
          },
        ],
      };
    }
  );

  server.tool(
    "list_directory",
    "List directory contents in a repository",
    {
      repo: z.enum(["cloud", "unix", "vault", "front", "tools"]).describe("Repository name"),
      path: z.string().optional().describe("Relative path (default: repo root)"),
    },
    async ({ repo, path }) => {
      try {
        const fullPath = validatePath(repo, path ?? ".");
        const entries = readdirSync(fullPath);
        const detailed = entries.map((name) => {
          try {
            const stat = statSync(join(fullPath, name));
            const type = stat.isDirectory() ? "dir" : "file";
            const size = stat.isFile() ? ` (${stat.size}b)` : "";
            return `${type === "dir" ? "📁" : "📄"} ${name}${size}`;
          } catch {
            return `❓ ${name}`;
          }
        });

        return {
          content: [
            {
              type: "text",
              text: `${repo}/${path ?? "."} (${entries.length} entries):\n\n${detailed.join("\n")}`,
            },
          ],
        };
      } catch (err: any) {
        return { content: [{ type: "text", text: `Error: ${err.message}` }], isError: true };
      }
    }
  );
}
