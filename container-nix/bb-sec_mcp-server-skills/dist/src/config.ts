import { readFileSync } from "fs";
import { join } from "path";
import type { InfraConfig, ServiceConfig } from "./types.js";
import { CONFIG_PATH, CONTAINER_NIX_DIR } from "./utils/paths.js";

let _config: InfraConfig | null = null;
let _configTimestamp = 0;
const CONFIG_TTL = 5 * 60 * 1000; // 5 minutes

export function getConfig(): InfraConfig {
  const now = Date.now();
  if (!_config || now - _configTimestamp > CONFIG_TTL) {
    _config = JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) as InfraConfig;
    _configTimestamp = now;
  }
  return _config;
}

export function reloadConfig(): InfraConfig {
  _config = null;
  _configTimestamp = 0;
  return getConfig();
}

const CATEGORY_PREFIX: Record<string, string> = {
  app: "aa-sui_",
  mic: "ab-mic_",
  cloud: "ba-clo_",
  sec: "bb-sec_",
  tools: "bc-obs_",
  data: "ca-dat_",
};

export function getServiceFolder(name: string): string {
  const config = getConfig();
  const svc = config.services[name];
  if (!svc) throw new Error(`Unknown service: ${name}`);
  const baseName = svc.flake ?? name;
  const prefix = CATEGORY_PREFIX[svc.category] ?? "";
  return `${prefix}${baseName}`;
}

export function getServiceDir(name: string): string {
  return join(CONTAINER_NIX_DIR, getServiceFolder(name));
}

// Hardcoded fallback — used when config.json VMs lack ssh_alias
const VM_SSH_ALIASES_FALLBACK: Record<string, string> = {
  "gcp-f-micro_1": "gcp-proxy",
  "oci-f-micro_1": "oci-mail",
  "oci-f-micro_2": "oci-analytics",
  "oci-p-flex_0": "oci-flex-0",
  "oci-p-flex_1": "oci-flex-1",
};

function buildAliasMap(): { vmToAlias: Record<string, string>; aliasToVm: Record<string, string> } {
  const config = getConfig();
  const vmToAlias: Record<string, string> = { ...VM_SSH_ALIASES_FALLBACK };
  const aliasToVm: Record<string, string> = {};

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
