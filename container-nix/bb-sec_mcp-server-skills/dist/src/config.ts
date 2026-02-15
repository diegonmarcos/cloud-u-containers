import { readFileSync } from "fs";
import { join } from "path";
import type { InfraConfig, ServiceConfig } from "./types.js";
import { CONFIG_PATH, CONTAINER_NIX_DIR } from "./utils/paths.js";

let _config: InfraConfig | null = null;

export function getConfig(): InfraConfig {
  if (!_config) {
    _config = JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) as InfraConfig;
  }
  return _config;
}

export function reloadConfig(): InfraConfig {
  _config = null;
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

const VM_SSH_ALIASES: Record<string, string> = {
  "gcp-f-micro_1": "gcp-proxy",
  "oci-f-micro_1": "oci-mail",
  "oci-f-micro_2": "oci-analytics",
  "oci-p-flex_1": "oci-flex",
};

const ALIAS_TO_VM: Record<string, string> = Object.fromEntries(
  Object.entries(VM_SSH_ALIASES).map(([k, v]) => [v, k])
);

export function getVmSshAlias(vmId: string): string {
  return VM_SSH_ALIASES[vmId] ?? vmId;
}

export function resolveVmId(nameOrAlias: string): string {
  if (ALIAS_TO_VM[nameOrAlias]) return ALIAS_TO_VM[nameOrAlias];
  const config = getConfig();
  if (config.vms[nameOrAlias]) return nameOrAlias;
  throw new Error(
    `Unknown VM: ${nameOrAlias}. Valid: ${Object.keys(config.vms).join(", ")} or aliases: ${Object.values(VM_SSH_ALIASES).join(", ")}`
  );
}

export function getServicesForVm(vmId: string): [string, ServiceConfig][] {
  const config = getConfig();
  return Object.entries(config.services).filter(
    ([, svc]) => svc.vm === vmId || svc.vm === "all"
  );
}
