// ── Inventory Pillar — "What exists" (25 tools) ──
// Config, topology, discovery, repos, files, frontend projects

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join, resolve } from "path";
import {
  getConfig,
  reloadConfig,
  getDriftReport,
  getServiceFolder,
  getServiceDir,
  getVmSshAlias,
  getServicesForVm,
  resolveVmId,
} from "../../shared/libs/config.js";
import { SOLUTIONS_DIR, REPOS, getDepsPath, FRONT_DIR } from "../../shared/libs/paths.js";
import { exec } from "../../shared/libs/exec.js";
import {
  listServices as listServiceApis,
  getService,
  probeSpec,
  getAllSpecs,
  serviceVersion,
  allServiceVersions,
  SERVICE_BASE_PATHS,
} from "../../shared/libs/discovery.js";
import { rawHttpRequest, getBearerToken } from "../../shared/libs/http.js";
import { getConfigPath } from "../../shared/libs/paths.js";
import { getConfigFile } from "../../shared/libs/files.js";

// ── Helpers ──

function jsonText(label: string, data: unknown): { content: { type: "text"; text: string }[] } {
  const text = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text" as const, text: `${label}\n\n${text}` }] };
}

function plainText(text: string): { content: { type: "text"; text: string }[] } {
  return { content: [{ type: "text" as const, text }] };
}

const VALID_REPOS = Object.keys(REPOS);

function validateRepoPath(repo: string, path: string): string {
  const repoBase = REPOS[repo];
  if (!repoBase) throw new Error(`Unknown repo: ${repo}. Valid: ${VALID_REPOS.join(", ")}`);
  const resolved = resolve(repoBase, path);
  if (!resolved.startsWith(repoBase)) {
    throw new Error("Path traversal detected — access denied");
  }
  if (resolved.includes("/dist/.env")) {
    throw new Error("Access to dist/.env files is denied (plaintext secrets)");
  }
  return resolved;
}

// ── Frontend helpers ──

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

export function registerInventoryTools(server: McpServer) {
  // ── Config (4 tools, from infra.ts) ──

  server.tool("knowledge.inventory.list_vms", "List all VMs with IP, user, SSH alias, and description", {}, async () => {
    const config = getConfig();
    const rows = Object.entries(config.vms).map(([id, vm]) => {
      const alias = getVmSshAlias(id);
      const serviceCount = getServicesForVm(id).length;
      return `${id} (${alias}) | ${vm.ip} | ${vm.user} | ${vm.method} | ${serviceCount} services | ${vm.description}`;
    });
    return {
      content: [
        {
          type: "text",
          text: `VMs (${rows.length}):\n\n${rows.join("\n")}`,
        },
      ],
    };
  });

  server.tool(
    "knowledge.inventory.list_services",
    "List services, optionally filtered by VM or category",
    {
      vm: z.string().optional().describe("Filter by VM ID or SSH alias"),
      category: z.string().optional().describe("Filter by category (app, mic, sec, tools, cloud, data)"),
    },
    async ({ vm, category }) => {
      const config = getConfig();
      let entries = Object.entries(config.services);

      if (vm) {
        const vmId = resolveVmId(vm);
        entries = entries.filter(([, s]) => s.vm === vmId || s.vm === "all");
      }
      if (category) {
        entries = entries.filter(([, s]) => s.category === category);
      }

      const rows = entries.map(([name, svc]) => {
        const folder = getServiceFolder(name);
        const hasDistDir = existsSync(join(SOLUTIONS_DIR, folder, "dist"));
        const tag = svc.discovered ? " [auto]" : "";
        return `${name}${tag} | ${svc.category} | ${svc.vm} | ${hasDistDir ? "built" : "-"} | ${svc.description}`;
      });

      return {
        content: [
          {
            type: "text",
            text: `Services (${rows.length}):\n\n${rows.join("\n")}`,
          },
        ],
      };
    }
  );

  server.tool(
    "knowledge.inventory.service_detail",
    "Get full service info: folder, flake.nix presence, secrets status, dist files",
    {
      service: z.string().describe("Service name from cloud-data-topology.json"),
    },
    async ({ service }) => {
      const config = getConfig();
      const svc = config.services[service];
      if (!svc) {
        return { content: [{ type: "text", text: `Unknown service: ${service}` }] };
      }

      const folder = getServiceFolder(service);
      const svcDir = getServiceDir(service);
      const srcDir = join(svcDir, "src");

      const info: string[] = [
        `Service: ${service}`,
        `Category: ${svc.category}`,
        `VM: ${svc.vm}`,
        `Description: ${svc.description}`,
        `Folder: ${folder}`,
        `Path: ${svcDir}`,
      ];

      if (svc.flake) info.push(`Flake override: ${svc.flake}`);
      if (svc.subfolder) info.push(`Subfolder: ${svc.subfolder}`);

      const flakePath = join(srcDir, "flake.nix");
      if (existsSync(flakePath)) {
        info.push(`\n--- flake.nix ---`);
        info.push(readFileSync(flakePath, "utf-8"));
      } else {
        info.push(`flake.nix: not found`);
      }

      const secretsPath = join(srcDir, "secrets.yaml");
      if (existsSync(secretsPath)) {
        const content = readFileSync(secretsPath, "utf-8");
        const encrypted = content.includes("sops:");
        info.push(`\nSecrets: ${encrypted ? "encrypted (sops)" : "PLAINTEXT WARNING"}`);
      } else {
        info.push(`Secrets: none`);
      }

      const distDir = join(svcDir, "dist");
      if (existsSync(distDir)) {
        try {
          const files = readdirSync(distDir);
          info.push(`\nDist files: ${files.join(", ")}`);
        } catch {
          info.push(`Dist: exists but unreadable`);
        }
      } else {
        info.push(`Dist: not built`);
      }

      const buildSh = join(svcDir, "build.sh");
      info.push(`build.sh: ${existsSync(buildSh) ? "present" : "missing"}`);

      return { content: [{ type: "text", text: info.join("\n") }] };
    }
  );

  server.tool(
    "knowledge.inventory.reload",
    "Reload cloud-data-topology.json from disk and show diff (services/VMs added or removed since last load)",
    {},
    async () => {
      const oldConfig = getConfig();
      const oldVms = new Set(Object.keys(oldConfig.vms));
      const oldServices = new Set(Object.keys(oldConfig.services));

      const newConfig = reloadConfig();
      const newVms = new Set(Object.keys(newConfig.vms));
      const newServices = new Set(Object.keys(newConfig.services));

      const addedVms = [...newVms].filter((v) => !oldVms.has(v));
      const removedVms = [...oldVms].filter((v) => !newVms.has(v));
      const addedServices = [...newServices].filter((s) => !oldServices.has(s));
      const removedServices = [...oldServices].filter((s) => !newServices.has(s));

      const lines: string[] = [
        `Config reloaded. ${newVms.size} VMs, ${newServices.size} services.`,
      ];

      if (addedVms.length) lines.push(`+ VMs added: ${addedVms.join(", ")}`);
      if (removedVms.length) lines.push(`- VMs removed: ${removedVms.join(", ")}`);
      if (addedServices.length) lines.push(`+ Services added: ${addedServices.join(", ")}`);
      if (removedServices.length) lines.push(`- Services removed: ${removedServices.join(", ")}`);
      if (!addedVms.length && !removedVms.length && !addedServices.length && !removedServices.length) {
        lines.push("No structural changes detected.");
      }

      const drift = getDriftReport();
      const autoCount = Object.values(newConfig.services).filter((s) => s.discovered).length;
      lines.push(`\n--- Drift Report ---`);
      lines.push(`Auto-discovered: ${autoCount} services from build.json`);
      if (drift.onDiskOnly.length) {
        lines.push(`On disk only (auto-discovered, not in cloud-data-topology.json): ${drift.onDiskOnly.join(", ")}`);
      }
      if (drift.configOnly.length) {
        lines.push(`In cloud-data-topology.json only (no folder on disk): ${drift.configOnly.join(", ")}`);
      }
      if (!drift.onDiskOnly.length && !drift.configOnly.length) {
        lines.push("Config and disk are in sync.");
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  // ── Repo (3 tools, from repo.ts) ──

  server.tool(
    "knowledge.inventory.read_file",
    "Read a file from a repository (cloud, unix, vault, front, tools)",
    {
      repo: z.enum(["cloud", "unix", "vault", "front", "tools"]).describe("Repository name"),
      path: z.string().describe("Relative path within the repo"),
      maxLines: z.number().optional().describe("Max lines to read (default: all)"),
    },
    async ({ repo, path, maxLines }) => {
      try {
        const fullPath = validateRepoPath(repo, path);
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
    "knowledge.inventory.search_repos",
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
    "knowledge.inventory.list_directory",
    "List directory contents in a repository",
    {
      repo: z.enum(["cloud", "unix", "vault", "front", "tools"]).describe("Repository name"),
      path: z.string().optional().describe("Relative path (default: repo root)"),
    },
    async ({ repo, path }) => {
      try {
        const fullPath = validateRepoPath(repo, path ?? ".");
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

  // ── Discovery (7 tools, from health.ts + discovery.ts) ──

  server.tool("knowledge.inventory.service_apis", "List all services with domain, VM, and API spec availability", {}, async () => {
    return jsonText("Service APIs", listServiceApis());
  });

  server.tool(
    "knowledge.inventory.service_info",
    "Get single service metadata including spec URL",
    { service: z.string().describe("Service name (e.g. authelia, matomo, photoprism)") },
    async ({ service }) => {
      const info = getService(service);
      if (!info) {
        return { content: [{ type: "text" as const, text: `Unknown service: ${service}` }], isError: true };
      }
      return jsonText(`Service info: ${service}`, info);
    },
  );

  server.tool(
    "knowledge.inventory.service_spec",
    "Fetch the full OpenAPI/Swagger spec for a service",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      const result = probeSpec(service);
      if (!result.ok) {
        return {
          content: [{ type: "text" as const, text: `No spec available for ${service}: ${result.error}` }],
          isError: true,
        };
      }
      const text = typeof result.spec === "string" ? result.spec : JSON.stringify(result.spec, null, 2);
      const truncated = text.length > 8000 ? `...(truncated)\n${text.slice(-8000)}` : text;
      return { content: [{ type: "text" as const, text: `OpenAPI spec for ${service}:\n\n${truncated}` }] };
    },
  );

  server.tool("knowledge.inventory.discover_all", "Parallel-fetch all service specs (cached 5min server-side)", {}, async () => {
    const result = getAllSpecs();
    const text = JSON.stringify(result, null, 2);
    const truncated = text.length > 15000 ? `...(truncated)\n${text.slice(-15000)}` : text;
    return { content: [{ type: "text" as const, text: `All service specs:\n\n${truncated}` }] };
  });

  server.tool(
    "knowledge.inventory.service_version",
    "Get version info for a service (via API endpoint)",
    { service: z.string().describe("Service name") },
    async ({ service }) => {
      return jsonText(`Version: ${service}`, serviceVersion(service));
    }
  );

  server.tool("knowledge.inventory.all_versions", "Get version info for all services", {}, async () => {
    return jsonText("All service versions", allServiceVersions());
  });

  server.tool(
    "knowledge.inventory.service_api_call",
    "Call any discovered service API endpoint. First use service_get_spec to understand available endpoints, then use this tool to make the actual call. Resolves service domain via C3 API discovery.",
    {
      service: z.string().describe("Service name (e.g. authelia, matomo, photoprism)"),
      method: z.enum(["GET", "POST", "PUT", "DELETE", "PATCH"]).optional().describe("HTTP method (default: GET)"),
      path: z.string().describe("API path on the service (e.g. /api/verify, /index.php?module=API)"),
      body: z.string().optional().describe("JSON request body for POST/PUT/PATCH"),
      headers: z.string().optional().describe("Extra headers as JSON object (e.g. {\"Authorization\": \"Bearer ...\"})"),
    },
    async ({ service, method, path, body, headers }) => {
      const info = getService(service);
      if (!info) {
        return {
          content: [{ type: "text" as const, text: `Unknown service: "${service}"` }],
          isError: true,
        };
      }

      const domain = info.domain;
      if (!domain) {
        return {
          content: [{
            type: "text" as const,
            text: `Service "${service}" has no domain configured.\nInfo: ${JSON.stringify(info, null, 2)}`,
          }],
          isError: true,
        };
      }

      const httpMethod = method ?? "GET";
      const basePath = SERVICE_BASE_PATHS[service] ?? "";
      const url = `https://${domain}${basePath}${path}`;

      let extraHeaders: Record<string, string> | undefined;
      if (headers) {
        try {
          extraHeaders = JSON.parse(headers) as Record<string, string>;
        } catch {
          return {
            content: [{ type: "text" as const, text: `Invalid headers JSON: ${headers}` }],
            isError: true,
          };
        }
      }

      if (!extraHeaders?.["Authorization"]) {
        const token = getBearerToken();
        if (token) {
          extraHeaders = { ...extraHeaders, Authorization: `Bearer ${token}` };
        }
      }

      const result = rawHttpRequest(httpMethod, url, body, 30_000, extraHeaders);

      const responseText = typeof result.data === "string"
        ? result.data
        : JSON.stringify(result.data, null, 2);

      const truncated = responseText.length > 10000
        ? `...(truncated)\n${responseText.slice(-10000)}`
        : responseText;

      return {
        content: [{
          type: "text" as const,
          text: [
            `${httpMethod} ${url}: ${result.ok ? "OK" : "FAILED"} (HTTP ${result.status})`,
            "",
            truncated,
          ].join("\n"),
        }],
        isError: !result.ok,
      };
    },
  );

  // ── Topology (6 tools, from c3.ts) ──

  server.tool(
    "knowledge.inventory.topology",
    "Unified topology view of all VMs, services, and networks from declarative config",
    {},
    async () => jsonText("Topology", JSON.parse(readFileSync(getConfigPath(), "utf-8"))),
  );

  server.tool(
    "knowledge.inventory.topology_drift",
    "Compare cloud-data-topology.json with on-disk services to find drift",
    {},
    async () => {
      const drift = getDriftReport();
      const parts: string[] = [];
      if (drift.onDiskOnly.length > 0) parts.push(`${drift.onDiskOnly.length} on disk only: ${drift.onDiskOnly.join(", ")}`);
      if (drift.configOnly.length > 0) parts.push(`${drift.configOnly.length} in config only: ${drift.configOnly.join(", ")}`);
      if (parts.length === 0) parts.push("No drift detected.");
      return jsonText("Topology drift", { ...drift, summary: parts.join(" | ") });
    },
  );

  server.tool(
    "knowledge.inventory.topology_network",
    "Show Docker networks per VM with connected containers",
    {},
    async () => {
      const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
      const result = Object.entries(topo.vms).map(([id, vm]) => {
        const vmSvcs = Object.entries(topo.services).filter(([, s]) => s.vm === id);
        const netMap: Record<string, string[]> = {};
        for (const [name, svc] of vmSvcs) {
          for (const n of svc.networks || []) {
            if (!netMap[n]) netMap[n] = [];
            netMap[n].push(name);
          }
        }
        return { vm: vm.ssh_alias, networks: Object.entries(netMap).map(([n, svcs]) => ({ name: n, services: svcs })) };
      });
      return jsonText("Network topology", result);
    },
  );

  server.tool(
    "knowledge.inventory.topology_volumes",
    "Show Docker volumes per VM (from cloud-data-topology.json)",
    {},
    async () => {
      const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
      return jsonText("Volume topology (declarative — from compose files)", topo.services);
    },
  );

  server.tool(
    "knowledge.inventory.topology_images",
    "Show Docker images per VM (from cloud-data-topology.json containers)",
    {},
    async () => {
      const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
      const result = Object.entries(topo.vms).map(([id, vm]) => ({
        vm: vm.ssh_alias, containers: vm.containers, ports: vm.ports,
      }));
      return jsonText("Image/container topology", result);
    },
  );

  server.tool(
    "knowledge.inventory.topology_deps",
    "Show service dependencies (from cloud-data-topology.json)",
    {},
    async () => {
      const topo = JSON.parse(readFileSync(getConfigPath(), "utf-8"));
      // Services sharing networks are implicitly dependent
      const result = Object.entries(topo.services)
        .filter(([, s]) => s.networks && s.networks.length > 0)
        .map(([name, s]) => ({ service: name, networks: s.networks, vm: s.vm }));
      return jsonText("Dependency topology (network-based)", result);
    },
  );

  // ── Deps (2 tools) ──

  server.tool(
    "knowledge.inventory.deps",
    "Get consolidated node dependencies across all cloud services (from cloud-data-deps.json). Grouped by language for home-manager consumption.",
    {},
    async () => {
      const depsPath = getDepsPath();
      if (!existsSync(depsPath)) {
        return plainText("cloud-data-deps.json not generated yet. Run: build.sh config");
      }
      return jsonText("Cloud deps", JSON.parse(readFileSync(depsPath, "utf-8")));
    },
  );

  server.tool(
    "knowledge.inventory.deps_merged",
    "Get merged node package.json (dependencies + devDependencies) across all cloud services — ready for ~/.node_modules/",
    {},
    async () => {
      const depsPath = getDepsPath();
      if (!existsSync(depsPath)) {
        return plainText("cloud-data-deps.json not generated yet. Run: build.sh config");
      }
      const deps = JSON.parse(readFileSync(depsPath, "utf-8"));
      return jsonText("Merged node deps", deps.node?.merged ?? {});
    },
  );

  // ── Files (1 tool, from c3.ts) ──

  server.tool(
    "knowledge.inventory.file",
    "Read a service config file (build.json, docker-compose.yml, flake.nix) with secrets redacted",
    {
      service: z.string().describe("Service name"),
      file: z.enum(["build.json", "docker-compose.yml", "flake.nix"]).optional()
        .describe("File to read (default: build.json)"),
    },
    async ({ service, file }) => plainText(getConfigFile(service, file)),
  );

  // ── Frontend (2 tools, from frontend-read.ts) ──

  server.tool(
    "knowledge.inventory.front_list_projects",
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
    "knowledge.inventory.front_get_project",
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
