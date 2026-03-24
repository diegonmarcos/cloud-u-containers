// ── Frontend Exec — "Build & Deploy" (3 tools) ──
// Build, dev server, deploy for front-end monorepo

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { exec } from "../../shared/exec.js";
import { FRONT_DIR, FRONT_BUILD_SCRIPT } from "../../shared/paths.js";

interface BuildJsonConfig {
  name: string;
  framework: string;
  port?: number;
  src?: string;
  dist?: string;
  build?: Array<{ mod: string; [key: string]: any }>;
  serve?: { mode?: string; dir?: string };
}

let _projectsCache: Map<string, { dir: string; category: string; config: BuildJsonConfig }> | null = null;
let _projectsCacheTimestamp = 0;
const PROJECTS_TTL = 60 * 1000;

function findProjects(): Map<string, { dir: string; category: string; config: BuildJsonConfig }> {
  const now = Date.now();
  if (_projectsCache && now - _projectsCacheTimestamp < PROJECTS_TTL) {
    return _projectsCache;
  }

  const projects = new Map<string, { dir: string; category: string; config: BuildJsonConfig }>();

  const entries = readdirSync(FRONT_DIR).filter((name) => {
    const full = join(FRONT_DIR, name);
    return statSync(full).isDirectory() && !name.startsWith(".") && name !== "node_modules" && name !== "1.ops" && name !== "0_docs" && name !== "0.spec";
  });

  for (const entry of entries) {
    const entryPath = join(FRONT_DIR, entry);
    const buildJson = join(entryPath, "build.json");

    if (existsSync(buildJson)) {
      try {
        const config = JSON.parse(readFileSync(buildJson, "utf-8")) as BuildJsonConfig;
        projects.set(entry, { dir: entryPath, category: entry, config });
      } catch { /* skip malformed */ }
      continue;
    }

    if (!statSync(entryPath).isDirectory()) continue;
    try {
      const subs = readdirSync(entryPath);
      for (const sub of subs) {
        const subPath = join(entryPath, sub);
        const subBuildJson = join(subPath, "build.json");
        if (existsSync(subBuildJson)) {
          try {
            const config = JSON.parse(readFileSync(subBuildJson, "utf-8")) as BuildJsonConfig;
            const key = projects.has(sub) ? `${entry}/${sub}` : sub;
            projects.set(key, { dir: subPath, category: entry, config });
          } catch { /* skip */ }
        }
      }
    } catch { /* skip */ }
  }

  _projectsCache = projects;
  _projectsCacheTimestamp = Date.now();
  return projects;
}

export function registerFrontendExecTools(server: McpServer) {
  server.tool(
    "front-build",
    "Build a front-end project using the universal build.sh engine",
    {
      project: z.string().describe("Project name"),
      command: z
        .enum(["build", "clean", "deps", "status"])
        .optional()
        .describe("Build command (default: build)"),
    },
    async ({ project, command }) => {
      const projects = findProjects();
      const p = projects.get(project);
      if (!p) {
        return { content: [{ type: "text", text: `Unknown project: ${project}` }], isError: true };
      }

      const buildSh = join(p.dir, "build.sh");
      if (!existsSync(buildSh)) {
        return {
          content: [{ type: "text", text: `No build.sh in ${p.dir}` }],
          isError: true,
        };
      }

      const cmd = command ?? "build";
      const result = exec("sh", [buildSh, cmd], {
        timeout: 120_000,
        cwd: p.dir,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `front build ${project} ${cmd}: ${result.ok ? "SUCCESS" : "FAILED"}`,
              `Exit code: ${result.exitCode}`,
              result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-3000)}` : "",
              result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-1000)}` : "",
            ].join("\n"),
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "front-dev_server",
    "Start, stop, or check status of a project's dev server",
    {
      project: z.string().describe("Project name"),
      action: z.enum(["dev", "stop", "status"]).describe("Dev server action"),
    },
    async ({ project, action }) => {
      const projects = findProjects();
      const p = projects.get(project);
      if (!p) {
        return { content: [{ type: "text", text: `Unknown project: ${project}` }], isError: true };
      }

      const buildSh = join(p.dir, "build.sh");
      if (!existsSync(buildSh)) {
        return { content: [{ type: "text", text: `No build.sh in ${p.dir}` }], isError: true };
      }

      const result = exec("sh", [buildSh, action], {
        timeout: 15_000,
        cwd: p.dir,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `front ${action} ${project}: ${result.ok ? "OK" : "FAILED"}`,
              result.stdout ? `\n${result.stdout}` : "",
              result.stderr ? `\nstderr: ${result.stderr}` : "",
            ].join("\n"),
          },
        ],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "front-deploy",
    "Run deploy.sh to merge deps and build all changed projects (CI-like)",
    {
      phase: z
        .enum(["deps", "build", "all"])
        .optional()
        .describe("Deploy phase: deps (merge package.json + npm install), build (compile all), all (both)"),
    },
    async ({ phase }) => {
      const deployScript = join(FRONT_DIR, "deploy.sh");
      if (!existsSync(deployScript)) {
        return { content: [{ type: "text", text: `deploy.sh not found in ${FRONT_DIR}` }], isError: true };
      }

      const args = [deployScript];
      if (phase && phase !== "all") args.push(phase);

      const result = exec("sh", args, {
        timeout: 300_000,
        cwd: FRONT_DIR,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `front deploy ${phase ?? "all"}: ${result.ok ? "SUCCESS" : "FAILED"}`,
              `Exit code: ${result.exitCode}`,
              result.stdout ? `\n--- stdout ---\n${result.stdout.slice(-5000)}` : "",
              result.stderr ? `\n--- stderr ---\n${result.stderr.slice(-2000)}` : "",
            ].join("\n"),
          },
        ],
        isError: !result.ok,
      };
    }
  );
}
