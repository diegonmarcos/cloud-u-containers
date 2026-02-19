import { z } from "zod";
import { readFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { getConfig, reloadConfig, getDriftReport, getServiceFolder, getServiceDir, getVmSshAlias, getServicesForVm, resolveVmId, } from "../config.js";
import { SOLUTIONS_DIR } from "../utils/paths.js";
export function registerInfraTools(server) {
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
    server.tool("list_services", "List services, optionally filtered by VM or category", {
        vm: z.string().optional().describe("Filter by VM ID or SSH alias"),
        category: z.string().optional().describe("Filter by category (app, mic, sec, tools, cloud, data)"),
    }, async ({ vm, category }) => {
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
    });
    server.tool("get_service_detail", "Get full service info: folder, flake.nix presence, secrets status, dist files", {
        service: z.string().describe("Service name from config.json"),
    }, async ({ service }) => {
        const config = getConfig();
        const svc = config.services[service];
        if (!svc) {
            return { content: [{ type: "text", text: `Unknown service: ${service}` }] };
        }
        const folder = getServiceFolder(service);
        const svcDir = getServiceDir(service);
        const srcDir = join(svcDir, "src");
        const info = [
            `Service: ${service}`,
            `Category: ${svc.category}`,
            `VM: ${svc.vm}`,
            `Description: ${svc.description}`,
            `Folder: ${folder}`,
            `Path: ${svcDir}`,
        ];
        if (svc.flake)
            info.push(`Flake override: ${svc.flake}`);
        if (svc.subfolder)
            info.push(`Subfolder: ${svc.subfolder}`);
        // Check for key files
        const flakePath = join(srcDir, "flake.nix");
        if (existsSync(flakePath)) {
            info.push(`\n--- flake.nix ---`);
            info.push(readFileSync(flakePath, "utf-8"));
        }
        else {
            info.push(`flake.nix: not found`);
        }
        const secretsPath = join(srcDir, "secrets.yaml");
        if (existsSync(secretsPath)) {
            const content = readFileSync(secretsPath, "utf-8");
            const encrypted = content.includes("sops:");
            info.push(`\nSecrets: ${encrypted ? "encrypted (sops)" : "PLAINTEXT WARNING"}`);
        }
        else {
            info.push(`Secrets: none`);
        }
        // List dist/ files if present
        const distDir = join(svcDir, "dist");
        if (existsSync(distDir)) {
            try {
                const files = readdirSync(distDir);
                info.push(`\nDist files: ${files.join(", ")}`);
            }
            catch {
                info.push(`Dist: exists but unreadable`);
            }
        }
        else {
            info.push(`Dist: not built`);
        }
        const buildSh = join(svcDir, "build.sh");
        info.push(`build.sh: ${existsSync(buildSh) ? "present" : "missing"}`);
        return { content: [{ type: "text", text: info.join("\n") }] };
    });
    server.tool("reload_config", "Reload config.json from disk and show diff (services/VMs added or removed since last load)", {}, async () => {
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
        const lines = [
            `Config reloaded. ${newVms.size} VMs, ${newServices.size} services.`,
        ];
        if (addedVms.length)
            lines.push(`+ VMs added: ${addedVms.join(", ")}`);
        if (removedVms.length)
            lines.push(`- VMs removed: ${removedVms.join(", ")}`);
        if (addedServices.length)
            lines.push(`+ Services added: ${addedServices.join(", ")}`);
        if (removedServices.length)
            lines.push(`- Services removed: ${removedServices.join(", ")}`);
        if (!addedVms.length && !removedVms.length && !addedServices.length && !removedServices.length) {
            lines.push("No structural changes detected.");
        }
        // Drift report: filesystem vs config.json
        const drift = getDriftReport();
        const autoCount = Object.values(newConfig.services).filter((s) => s.discovered).length;
        lines.push(`\n--- Drift Report ---`);
        lines.push(`Auto-discovered: ${autoCount} services from build.json`);
        if (drift.onDiskOnly.length) {
            lines.push(`On disk only (auto-discovered, not in config.json): ${drift.onDiskOnly.join(", ")}`);
        }
        if (drift.configOnly.length) {
            lines.push(`In config.json only (no folder on disk): ${drift.configOnly.join(", ")}`);
        }
        if (!drift.onDiskOnly.length && !drift.configOnly.length) {
            lines.push("Config and disk are in sync.");
        }
        return { content: [{ type: "text", text: lines.join("\n") }] };
    });
}
//# sourceMappingURL=infra.js.map