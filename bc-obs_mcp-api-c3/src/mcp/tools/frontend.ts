// ── Frontend Extension — "Front-end monorepo" (5 tools) ──
// Build, dev, deploy for 32-project front-end monorepo

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

export function registerFrontendTools(server: McpServer) {
  server.tool(
    "front_list_projects",
    "List all front-end web projects with framework, port, and build type",
    {
      category: z
        .string()
        .optional()
        .describe("Filter by category folder (a_Portals, b_Work_Profiles, b_Work_Tools, c_Personal_Profiles, c_Personal_Tools, c_root)"),
    },
    async ({ category }) => {
      const projects = findProjects();
      let entries = [...projects.entries()];

      if (category) {
        entries = entries.filter(([, p]) => p.category === category);
      }

      const rows = entries.map(([name, p]) => {
        const c = p.config;
        const mods = (c.build ?? []).map((b) => b.mod).join(", ");
        const hasDist = existsSync(join(p.dir, c.dist ?? "dist"));
        return `${name} | ${c.framework ?? "vanilla"} | port:${c.port ?? "-"} | ${mods || "none"} | ${hasDist ? "built" : "-"} | ${p.category}`;
      });

      return {
        content: [
          {
            type: "text",
            text: `Front-end projects (${rows.length}):\n\nNAME | FRAMEWORK | PORT | BUILD MODULES | BUILT | CATEGORY\n${rows.join("\n")}`,
          },
        ],
      };
    }
  );

  server.tool(
    "front_get_project",
    "Get detailed info about a front-end project: build.json, package.json deps, file structure",
    {
      project: z.string().describe("Project name (directory name, e.g. 'landpage', 'myfeed', 'c_root')"),
    },
    async ({ project }) => {
      const projects = findProjects();
      const p = projects.get(project);
      if (!p) {
        const names = [...projects.keys()].sort().join(", ");
        return {
          content: [{ type: "text", text: `Unknown project: ${project}\n\nAvailable: ${names}` }],
          isError: true,
        };
      }

      const c = p.config;
      const info: string[] = [
        `Project: ${c.name} (${project})`,
        `Category: ${p.category}`,
        `Framework: ${c.framework ?? "vanilla"}`,
        `Port: ${c.port ?? "none"}`,
        `Source: ${c.src ?? "src"}`,
        `Dist: ${c.dist ?? "dist"}`,
        `Path: ${p.dir}`,
      ];

      const mods = (c.build ?? []).map((b) => b.mod);
      info.push(`Build modules: ${mods.join(" → ") || "none"}`);

      if (c.serve) {
        info.push(`Serve mode: ${c.serve.mode ?? "auto"}`);
        info.push(`Serve dir: ${c.serve.dir ?? c.src ?? "src"}`);
      }

      info.push(`\n--- build.json ---`);
      info.push(JSON.stringify(c, null, 2));

      const pkgPath = join(p.dir, "package.json");
      if (existsSync(pkgPath)) {
        try {
          const pkg = JSON.parse(readFileSync(pkgPath, "utf-8"));
          const deps = Object.keys(pkg.dependencies ?? {});
          const devDeps = Object.keys(pkg.devDependencies ?? {});
          info.push(`\n--- Dependencies ---`);
          if (deps.length) info.push(`deps: ${deps.join(", ")}`);
          if (devDeps.length) info.push(`devDeps: ${devDeps.join(", ")}`);
        } catch { /* skip */ }
      }

      const distDir = join(p.dir, c.dist ?? "dist");
      if (existsSync(distDir)) {
        try {
          const files = readdirSync(distDir);
          info.push(`\nDist files: ${files.join(", ")}`);
        } catch {
          info.push(`Dist: exists but unreadable`);
        }
      } else {
        info.push(`\nDist: not built`);
      }

      const pidFile = join(p.dir, ".build.pid");
      if (existsSync(pidFile)) {
        try {
          const pidData = JSON.parse(readFileSync(pidFile, "utf-8"));
          info.push(`\nDev server PID: ${JSON.stringify(pidData)}`);
        } catch {
          info.push(`\nDev server: .build.pid exists but unparseable`);
        }
      }

      return { content: [{ type: "text", text: info.join("\n") }] };
    }
  );

  server.tool(
    "front_build",
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
    "front_dev_server",
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
    "front_deploy",
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
