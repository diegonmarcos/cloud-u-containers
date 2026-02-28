import { McpServer, ResourceTemplate } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import {
  getConfig,
  getServiceFolder,
  getServiceDir,
  getVmSshAlias,
  getServicesForVm,
  resolveVmId,
} from "../../shared/config.js";
import {
  CONFIG_PATH,
  SSH_CONFIG_PATH,
  SOLUTIONS_DIR,
  FRONT_DIR,
} from "../../shared/paths.js";
import { listServices } from "../../shared/discovery.js";

export function registerResources(server: McpServer) {
  server.resource("config", "cloud://config", async (uri) => {
    const content = readFileSync(CONFIG_PATH, "utf-8");
    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "application/json",
          text: content,
        },
      ],
    };
  });

  server.resource("ssh-config", "cloud://ssh-config", async (uri) => {
    const content = readFileSync(SSH_CONFIG_PATH, "utf-8");
    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "text/plain",
          text: content,
        },
      ],
    };
  });

  server.resource("services-overview", "cloud://services-overview", async (uri) => {
    const config = getConfig();
    const lines: string[] = [
      "# Cloud Infrastructure Services Overview",
      "",
      "| Service | Category | VM | SSH Alias | Description |",
      "|---------|----------|----|-----------|-------------|",
    ];

    for (const [name, svc] of Object.entries(config.services)) {
      const alias = svc.vm === "local" || svc.vm === "all" ? svc.vm : getVmSshAlias(svc.vm);
      lines.push(`| ${name} | ${svc.category} | ${svc.vm} | ${alias} | ${svc.description} |`);
    }

    lines.push("");
    lines.push("## VMs");
    lines.push("");
    lines.push("| VM ID | SSH Alias | IP | User | Description |");
    lines.push("|-------|-----------|----|----|-------------|");

    for (const [id, vm] of Object.entries(config.vms)) {
      const alias = getVmSshAlias(id);
      const svcCount = getServicesForVm(id).length;
      lines.push(`| ${id} | ${alias} | ${vm.ip} | ${vm.user} | ${vm.description} (${svcCount} services) |`);
    }

    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "text/markdown",
          text: lines.join("\n"),
        },
      ],
    };
  });

  server.resource("readme", "cloud://readme", async (uri) => {
    const readmePath = join(SOLUTIONS_DIR, "README.md");
    const content = existsSync(readmePath)
      ? readFileSync(readmePath, "utf-8")
      : "README.md not found";
    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "text/markdown",
          text: content,
        },
      ],
    };
  });

  server.resource("front-projects", "cloud://front-projects", async (uri) => {
    const lines: string[] = [
      "# Front-End Projects Overview",
      "",
      "Monorepo with 32 web projects deployed to GitHub Pages (diegonmarcos.github.io)",
      "",
      "| Project | Framework | Port | Build Modules | Category |",
      "|---------|-----------|------|---------------|----------|",
    ];

    // Scan for build.json files
    const scanDir = (dir: string, category: string) => {
      try {
        const entries = readdirSync(dir);
        for (const entry of entries) {
          const entryPath = join(dir, entry);
          const buildJson = join(entryPath, "build.json");
          if (existsSync(buildJson)) {
            try {
              const config = JSON.parse(readFileSync(buildJson, "utf-8"));
              const mods = (config.build ?? []).map((b: any) => b.mod).join(", ");
              lines.push(
                `| ${entry} | ${config.framework ?? "vanilla"} | ${config.port ?? "-"} | ${mods || "none"} | ${category} |`
              );
            } catch { /* skip */ }
          }
        }
      } catch { /* skip */ }
    };

    // c_root is a direct project
    const rootBuildJson = join(FRONT_DIR, "c_root", "build.json");
    if (existsSync(rootBuildJson)) {
      try {
        const config = JSON.parse(readFileSync(rootBuildJson, "utf-8"));
        const mods = (config.build ?? []).map((b: any) => b.mod).join(", ");
        lines.push(`| c_root | ${config.framework ?? "vanilla"} | ${config.port ?? "-"} | ${mods} | root |`);
      } catch { /* skip */ }
    }

    for (const cat of ["a_Portals", "b_Work_Profiles", "b_Work_Tools", "c_Personal_Profiles", "c_Personal_Tools"]) {
      scanDir(join(FRONT_DIR, cat), cat);
    }

    return {
      contents: [
        {
          uri: uri.href,
          mimeType: "text/markdown",
          text: lines.join("\n"),
        },
      ],
    };
  });

  server.resource("c3-api-endpoints", "cloud://c3-api-endpoints", async (uri) => {
    const text = `# C3 API — Cloud Control Center

API: api.diegonmarcos.com/c3-api/ (port 8081 via WG mesh)
MCP tools call shared/ layer directly (no HTTP proxy needed).

## Health
| Endpoint | MCP Tool |
|----------|----------|
| GET /health | health_alive |
| GET /health/declared | health_declared |
| GET /health/deployed[/{vm}] | health_deployed |
| GET /health/drift | health_drift |
| GET /health/status[/{vm}] | health_status |
| GET /profiling/{container} | profile_container |
| GET /profiling/vm/{vm_id} | profile_vm |

## Discovery
| Endpoint | MCP Tool |
|----------|----------|
| GET /services | service_list_apis |
| GET /services/{service} | service_get_info |
| GET /services/{service}/spec | service_get_spec |
| GET /services/all/specs | service_discover_all |

## Control
| Endpoint | MCP Tool |
|----------|----------|
| POST /vms/{vm_id}/start | vm_start |
| POST /vms/{vm_id}/stop | vm_stop |
| POST /vms/{vm_id}/reset | vm_reset |
| POST /vms/{vm_id}/containers/{name}/start | container_start |
| POST /vms/{vm_id}/containers/{name}/stop | container_stop |
| POST /vms/{vm_id}/containers/{name}/restart | container_restart |
| POST /vms/{vm_id}/services/{service}/start | service_start |
| POST /vms/{vm_id}/services/{service}/stop | service_stop |

## Proxy
| Usage | MCP Tool |
|-------|----------|
| Any service endpoint via discovery | service_api_call |

## C3 New
| Endpoint | MCP Tool |
|----------|----------|
| GET /topology | c3_topology |
| GET /topology/drift | c3_topology_drift |
| GET /topology/security | c3_topology_security |
| GET /tests/run/{suite} | c3_test |
| GET /files/config/{service} | c3_file |
| GET /files/report/{type} | c3_report |
| GET /files/status/{vm} | c3_vm_status |
| GET /health/tier1 | health_tier1 |
| GET /health/tier2 | health_tier2 |
| GET /health/tier3 | health_tier3 |

`;

    return {
      contents: [{
        uri: uri.href,
        mimeType: "text/markdown",
        text,
      }],
    };
  });

  server.resource("service-apis", "cloud://service-apis", async (uri) => {
    const services = listServices();
    const text = `# Service API Catalog\n\n${services.length} services discovered from config.\n\n\`\`\`json\n${JSON.stringify(services, null, 2)}\n\`\`\``;

    return {
      contents: [{
        uri: uri.href,
        mimeType: "text/markdown",
        text,
      }],
    };
  });

  // ── Resource Templates ──

  server.resource(
    "service-detail",
    new ResourceTemplate("cloud://services/{name}", {
      list: async () => ({
        resources: Object.keys(getConfig().services).map((name) => ({
          uri: `cloud://services/${name}`,
          name,
          description: getConfig().services[name].description,
        })),
      }),
    }),
    async (uri, variables) => {
      const name = variables.name as string;
      const config = getConfig();
      const svc = config.services[name];
      if (!svc) {
        return { contents: [{ uri: uri.href, mimeType: "text/plain", text: `Unknown service: ${name}` }] };
      }

      const folder = getServiceFolder(name);
      const svcDir = getServiceDir(name);
      const alias = svc.vm === "local" || svc.vm === "all" ? svc.vm : getVmSshAlias(svc.vm);

      const info = {
        name,
        category: svc.category,
        vm: svc.vm,
        ssh_alias: alias,
        description: svc.description,
        folder,
        path: svcDir,
        flake: svc.flake ?? null,
        subfolder: svc.subfolder ?? null,
        has_build_sh: existsSync(join(svcDir, "build.sh")),
        has_flake_nix: existsSync(join(svcDir, "src", "flake.nix")),
        has_dist: existsSync(join(svcDir, "dist")),
      };

      return {
        contents: [{
          uri: uri.href,
          mimeType: "application/json",
          text: JSON.stringify(info, null, 2),
        }],
      };
    }
  );

  server.resource(
    "vm-detail",
    new ResourceTemplate("cloud://vms/{vm_id}", {
      list: async () => ({
        resources: Object.keys(getConfig().vms).map((vmId) => ({
          uri: `cloud://vms/${vmId}`,
          name: getVmSshAlias(vmId),
          description: getConfig().vms[vmId].description,
        })),
      }),
    }),
    async (uri, variables) => {
      const vmId = variables.vm_id as string;
      const config = getConfig();

      // Accept both VM ID and alias
      let resolvedId: string;
      try {
        resolvedId = resolveVmId(vmId);
      } catch {
        return { contents: [{ uri: uri.href, mimeType: "text/plain", text: `Unknown VM: ${vmId}` }] };
      }

      const vm = config.vms[resolvedId];
      const alias = getVmSshAlias(resolvedId);
      const services = getServicesForVm(resolvedId);

      const info = {
        vm_id: resolvedId,
        ssh_alias: alias,
        ip: vm.ip,
        user: vm.user,
        method: vm.method,
        description: vm.description,
        service_count: services.length,
        services: services.map(([name, svc]) => ({ name, category: svc.category, description: svc.description })),
      };

      return {
        contents: [{
          uri: uri.href,
          mimeType: "application/json",
          text: JSON.stringify(info, null, 2),
        }],
      };
    }
  );
}
