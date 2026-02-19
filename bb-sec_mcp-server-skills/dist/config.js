import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";
import { CONFIG_PATH, SOLUTIONS_DIR } from "./utils/paths.js";
let _config = null;
let _configTimestamp = 0;
const CONFIG_TTL = 5 * 60 * 1000; // 5 minutes
// Hardcoded fallback — used when config.json VMs lack ssh_alias
const VM_SSH_ALIASES_FALLBACK = {
    "gcp-E2-f_0": "gcp-proxy",
    "oci-E2-f_0": "oci-mail",
    "oci-E2-f_1": "oci-analytics",
    "oci-A1-f_0": "oci-apps",
    "oci-A1-f_1": "oci-apps-1",
};
export function getConfig() {
    const now = Date.now();
    if (!_config || now - _configTimestamp > CONFIG_TTL) {
        const fileConfig = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
        const discovered = discoverServicesFromDisk(fileConfig);
        // Merge: discovered first, then config.json overrides win
        const merged = { ...discovered };
        for (const [name, svc] of Object.entries(fileConfig.services)) {
            merged[name] = svc;
        }
        fileConfig.services = merged;
        _config = fileConfig;
        _configTimestamp = now;
    }
    return _config;
}
export function reloadConfig() {
    _config = null;
    _configTimestamp = 0;
    return getConfig();
}
export function getDriftReport() {
    const fileConfig = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
    const discovered = discoverServicesFromDisk(fileConfig);
    const configNames = new Set(Object.keys(fileConfig.services));
    const diskNames = new Set(Object.keys(discovered));
    return {
        onDiskOnly: [...diskNames].filter((n) => !configNames.has(n)).sort(),
        configOnly: [...configNames].filter((n) => {
            // Check if the config entry's folder exists on disk (with or without build.json)
            const svc = fileConfig.services[n];
            const baseName = svc.flake ?? n;
            const prefix = CATEGORY_PREFIX[svc.category] ?? "";
            const folder = `${prefix}${baseName}`;
            return !existsSync(join(SOLUTIONS_DIR, folder));
        }).sort(),
    };
}
const CATEGORY_PREFIX = {
    app: "aa-sui_",
    mic: "ab-mic_",
    fin: "ac-fin_",
    agi: "ad-agi_",
    cloud: "ba-clo_",
    sec: "bb-sec_",
    tools: "bc-obs_",
    data: "ca-dat_",
};
// Reverse map: directory prefix → category
const PREFIX_TO_CATEGORY = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
    PREFIX_TO_CATEGORY[prefix] = cat;
}
function discoverServicesFromDisk(fileConfig) {
    const discovered = {};
    // Build alias→vmId map from config VMs for host resolution
    const aliasToVm = {};
    for (const [vmId, vm] of Object.entries(fileConfig.vms)) {
        if (vm.ssh_alias)
            aliasToVm[vm.ssh_alias] = vmId;
    }
    // Include hardcoded fallbacks
    for (const [vmId, alias] of Object.entries(VM_SSH_ALIASES_FALLBACK)) {
        if (!aliasToVm[alias])
            aliasToVm[alias] = vmId;
    }
    let dirs;
    try {
        dirs = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
            .filter((d) => d.isDirectory() && d.name !== "z_archive")
            .map((d) => d.name);
    }
    catch {
        return discovered;
    }
    for (const dirName of dirs) {
        const buildJsonPath = join(SOLUTIONS_DIR, dirName, "build.json");
        if (!existsSync(buildJsonPath))
            continue;
        let buildJson;
        try {
            buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
        }
        catch {
            continue;
        }
        const name = buildJson.name;
        if (!name)
            continue;
        // Reverse-map prefix → category
        const prefix = Object.keys(PREFIX_TO_CATEGORY).find((p) => dirName.startsWith(p));
        if (!prefix)
            continue;
        const category = PREFIX_TO_CATEGORY[prefix];
        // Map deploy.host alias → VM ID
        const host = buildJson.deploy?.host ?? "local";
        const vmId = aliasToVm[host] ?? host;
        discovered[name] = {
            category,
            vm: vmId,
            description: buildJson.description ?? "",
            discovered: true,
        };
    }
    return discovered;
}
export function getServiceFolder(name) {
    const config = getConfig();
    const svc = config.services[name];
    if (!svc)
        throw new Error(`Unknown service: ${name}`);
    const baseName = svc.flake ?? name;
    const prefix = CATEGORY_PREFIX[svc.category] ?? "";
    return `${prefix}${baseName}`;
}
export function getServiceDir(name) {
    return join(SOLUTIONS_DIR, getServiceFolder(name));
}
function buildAliasMap() {
    const config = getConfig();
    const vmToAlias = { ...VM_SSH_ALIASES_FALLBACK };
    const aliasToVm = {};
    // Prefer ssh_alias from config.json when present
    for (const [vmId, vm] of Object.entries(config.vms)) {
        if (vm.ssh_alias) {
            vmToAlias[vmId] = vm.ssh_alias;
        }
    }
    // Build reverse map
    for (const [vmId, alias] of Object.entries(vmToAlias)) {
        aliasToVm[alias] = vmId;
    }
    return { vmToAlias, aliasToVm };
}
export function getVmSshAlias(vmId) {
    const { vmToAlias } = buildAliasMap();
    return vmToAlias[vmId] ?? vmId;
}
export function resolveVmId(nameOrAlias) {
    const { aliasToVm } = buildAliasMap();
    if (aliasToVm[nameOrAlias])
        return aliasToVm[nameOrAlias];
    const config = getConfig();
    if (config.vms[nameOrAlias])
        return nameOrAlias;
    const { vmToAlias } = buildAliasMap();
    throw new Error(`Unknown VM: ${nameOrAlias}. Valid: ${Object.keys(config.vms).join(", ")} or aliases: ${Object.values(vmToAlias).join(", ")}`);
}
export function getServicesForVm(vmId) {
    const config = getConfig();
    return Object.entries(config.services).filter(([, svc]) => svc.vm === vmId || svc.vm === "all");
}
//# sourceMappingURL=config.js.map