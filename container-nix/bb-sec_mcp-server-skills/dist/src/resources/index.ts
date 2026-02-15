import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import {
  getConfig,
  getServiceFolder,
  getVmSshAlias,
  getServicesForVm,
} from "../config.js";
import {
  CONFIG_PATH,
  SSH_CONFIG_PATH,
  CONTAINER_NIX_DIR,
  FRONT_DIR,
  RUST_API_BASE,
} from "../utils/paths.js";
import { rustApiGet } from "../utils/http.js";

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
    const readmePath = join(CONTAINER_NIX_DIR, "README.md");
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

  server.resource("rust-api-endpoints", "cloud://rust-api-endpoints", async (uri) => {
    const text = `# Rust API → MCP Tool Mapping

Base URL: ${RUST_API_BASE}

## Health (Waiter Read)
| Endpoint | MCP Tool |
|----------|----------|
| GET /api/health | health_alive |
| GET /api/health/declared | health_declared |
| GET /api/health/deployed[/{vm}] | health_deployed |
| GET /api/health/drift | health_drift |
| GET /api/health/status[/{vm}] | health_status |
| GET /api/profiling/{container} | profile_container |
| GET /api/profiling/vm/{vm_id} | profile_vm |

## Discovery (Waiter Read)
| Endpoint | MCP Tool |
|----------|----------|
| GET /api/services | service_list_apis |
| GET /api/services/{service} | service_get_info |
| GET /api/services/{service}/spec | service_get_spec |
| GET /api/services/all/specs | service_discover_all |

## Control (Waiter Write)
| Endpoint | MCP Tool |
|----------|----------|
| POST /api/vms/{vm_id}/start | vm_start |
| POST /api/vms/{vm_id}/stop | vm_stop |
| POST /api/vms/{vm_id}/reset | vm_reset |
| POST /api/vms/{vm_id}/containers/{name}/start | container_start |
| POST /api/vms/{vm_id}/containers/{name}/stop | container_stop |
| POST /api/vms/{vm_id}/containers/{name}/restart | container_restart |
| POST /api/vms/{vm_id}/services/{service}/start | service_start |
| POST /api/vms/{vm_id}/services/{service}/stop | service_stop |

## Proxy (Waiter Proxy)
| Usage | MCP Tool |
|-------|----------|
| Any service endpoint via discovery | service_api_call |

## Legacy (Deprecated)
| Endpoint | MCP Tool |
|----------|----------|
| Flask API (any) | api_call |
| Flask /vms/control | api_vm_control |
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
    const result = rustApiGet("/api/services");
    let text: string;

    if (!result.ok) {
      text = `# Service API Catalog\n\nFailed to fetch from Rust API: ${result.error ?? "unavailable"}\n\nThe Rust API at ${RUST_API_BASE} may be down. Use health_alive to check.`;
    } else {
      const services = result.data as Record<string, unknown>[] | Record<string, unknown>;
      text = `# Service API Catalog (Live)\n\nFetched from ${RUST_API_BASE}/api/services\n\n\`\`\`json\n${JSON.stringify(services, null, 2)}\n\`\`\``;
    }

    return {
      contents: [{
        uri: uri.href,
        mimeType: "text/markdown",
        text,
      }],
    };
  });
}
