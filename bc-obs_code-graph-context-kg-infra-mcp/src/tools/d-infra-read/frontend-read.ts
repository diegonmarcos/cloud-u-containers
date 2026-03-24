// ── Frontend READ tools (extracted from c3-infra-mcp frontend.ts) ──
// List and inspect front-end projects (read-only, no build/dev/deploy)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { FRONT_DIR } from "../../shared/paths.js";

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

export function registerFrontendReadTools(server: McpServer) {
  server.tool(
    "front-data-list_projects",
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
    "front-data-get_project",
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
}
