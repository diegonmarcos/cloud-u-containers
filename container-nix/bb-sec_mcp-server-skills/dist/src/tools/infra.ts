import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import {
  getConfig,
  getServiceFolder,
  getServiceDir,
  getVmSshAlias,
  getServicesForVm,
  resolveVmId,
} from "../config.js";
import { CONTAINER_NIX_DIR } from "../utils/paths.js";

export function registerInfraTools(server: McpServer) {
  server.tool("list_vms", "List all VMs with IP, user, SSH alias, and description", {}, async () => {
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
    "list_services",
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
        const hasDistDir = existsSync(join(CONTAINER_NIX_DIR, folder, "dist"));
        return `${name} | ${svc.category} | ${svc.vm} | ${hasDistDir ? "built" : "-"} | ${svc.description}`;
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
    "get_service_detail",
    "Get full service info: folder, flake.nix presence, secrets status, dist files",
    {
      service: z.string().describe("Service name from config.json"),
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

      // Check for key files
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

      // List dist/ files if present
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
}
