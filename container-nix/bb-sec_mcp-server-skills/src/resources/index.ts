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
} from "../utils/paths.js";

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
}
