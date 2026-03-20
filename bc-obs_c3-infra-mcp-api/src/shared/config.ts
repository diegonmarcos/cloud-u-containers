import { readFileSync, readdirSync, existsSync } from "fs";
import { join } from "path";
import type { InfraConfig, ServiceConfig } from "./types.js";
import { CONFIG_PATH, SOLUTIONS_DIR, syncRepos } from "./paths.js";

let _config: InfraConfig | null = null;
let _configTimestamp = 0;
const CONFIG_TTL = 5 * 60 * 1000; // 5 minutes

// Hardcoded fallback — used when cloud-data-topology.json VMs lack ssh_alias
const VM_SSH_ALIASES_FALLBACK: Record<string, string> = {
  "gcp-E2-f_0": "gcp-proxy",
  "oci-E2-f_0": "oci-mail",
  "oci-E2-f_1": "oci-analytics",
  "oci-A1-f_0": "oci-apps",
  // oci-A1-f_1 (oci-apps-1) DECOMMISSIONED 2026-02-28
};

export function getConfig(): InfraConfig {
  const now = Date.now();
  if (!_config || now - _configTimestamp > CONFIG_TTL) {
    syncRepos();
    const fileConfig = JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) as InfraConfig;
    const discovered = discoverServicesFromDisk(fileConfig);
    // Merge: discovered first, then cloud-data-topology.json overrides win
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

export function reloadConfig(): InfraConfig {
  _config = null;
  _configTimestamp = 0;
  return getConfig();
}

export function getDriftReport(): { onDiskOnly: string[]; configOnly: string[] } {
  const fileConfig = JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) as InfraConfig;
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

const CATEGORY_PREFIX: Record<string, string> = {
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
const PREFIX_TO_CATEGORY: Record<string, ServiceConfig["category"]> = {};
for (const [cat, prefix] of Object.entries(CATEGORY_PREFIX)) {
  PREFIX_TO_CATEGORY[prefix] = cat as ServiceConfig["category"];
}

function discoverServicesFromDisk(fileConfig: InfraConfig): Record<string, ServiceConfig> {
  const discovered: Record<string, ServiceConfig> = {};

  // Build alias→vmId map from config VMs for host resolution
  const aliasToVm: Record<string, string> = {};
  for (const [vmId, vm] of Object.entries(fileConfig.vms)) {
    if (vm.ssh_alias) aliasToVm[vm.ssh_alias] = vmId;
  }
  // Include hardcoded fallbacks
  for (const [vmId, alias] of Object.entries(VM_SSH_ALIASES_FALLBACK)) {
    if (!aliasToVm[alias]) aliasToVm[alias] = vmId;
  }

  let dirs: string[];
  try {
    dirs = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory() && d.name !== "z_archive")
      .map((d) => d.name);
  } catch {
    return discovered;
  }

  for (const dirName of dirs) {
    const buildJsonPath = join(SOLUTIONS_DIR, dirName, "build.json");
    if (!existsSync(buildJsonPath)) continue;

    let buildJson: { name?: string; description?: string; deploy?: { host?: string } };
    try {
      buildJson = JSON.parse(readFileSync(buildJsonPath, "utf-8"));
    } catch {
      continue;
    }

    const name = buildJson.name;
    if (!name) continue;

    // Reverse-map prefix → category (fall back to build.json category)
    const prefix = Object.keys(PREFIX_TO_CATEGORY).find((p) => dirName.startsWith(p));
    const category = prefix
      ? PREFIX_TO_CATEGORY[prefix]
      : ((buildJson as any).category as ServiceConfig["category"]) ?? "tools";

    // Map deploy.host alias → VM ID
    const host = buildJson.deploy?.host ?? "local";
    const vmId = aliasToVm[host] ?? host;

    discovered[name] = {
      category,
      vm: vmId,
      folder: dirName,
      description: buildJson.description ?? "",
      discovered: true,
    };
  }

  return discovered;
}

export function getServiceFolder(name: string): string {
  const config = getConfig();
  const svc = config.services[name];
  if (!svc) throw new Error(`Unknown service: ${name}`);
  // Use actual folder from discovery, fall back to prefix+name reconstruction
  if (svc.folder) return svc.folder;
  const baseName = svc.flake ?? name;
  const prefix = CATEGORY_PREFIX[svc.category] ?? "";
  const constructed = `${prefix}${baseName}`;
  // Verify constructed path exists, otherwise scan for matching build.json
  if (existsSync(join(SOLUTIONS_DIR, constructed))) return constructed;
  try {
    const dirs = readdirSync(SOLUTIONS_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory())
      .map((d) => d.name);
    for (const dir of dirs) {
      const bjPath = join(SOLUTIONS_DIR, dir, "build.json");
      if (!existsSync(bjPath)) continue;
      try {
        const bj = JSON.parse(readFileSync(bjPath, "utf-8"));
        if (bj.name === name) return dir;
      } catch { continue; }
    }
  } catch { /* fall through */ }
  return constructed;
}

export function getServiceDir(name: string): string {
  return join(SOLUTIONS_DIR, getServiceFolder(name));
}

function buildAliasMap(): { vmToAlias: Record<string, string>; aliasToVm: Record<string, string> } {
  const config = getConfig();
  const vmToAlias: Record<string, string> = { ...VM_SSH_ALIASES_FALLBACK };
  const aliasToVm: Record<string, string> = {};

  // Prefer ssh_alias from cloud-data-topology.json when present
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

export function getVmSshAlias(vmId: string): string {
  const { vmToAlias } = buildAliasMap();
  return vmToAlias[vmId] ?? vmId;
}

export function resolveVmId(nameOrAlias: string): string {
  const { aliasToVm } = buildAliasMap();
  if (aliasToVm[nameOrAlias]) return aliasToVm[nameOrAlias];
  const config = getConfig();
  if (config.vms[nameOrAlias]) return nameOrAlias;
  const { vmToAlias } = buildAliasMap();
  throw new Error(
    `Unknown VM: ${nameOrAlias}. Valid: ${Object.keys(config.vms).join(", ")} or aliases: ${Object.values(vmToAlias).join(", ")}`
  );
}

export function getServicesForVm(vmId: string): [string, ServiceConfig][] {
  const config = getConfig();
  return Object.entries(config.services).filter(
    ([, svc]) => svc.vm === vmId || svc.vm === "all"
  );
}
