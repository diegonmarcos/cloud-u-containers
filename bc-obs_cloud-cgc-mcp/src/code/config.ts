/**
 * Minimal config reader for skill prompts.
 * Reads config.json directly via CONFIG_PATH env var.
 */
import { existsSync, readFileSync } from "fs";
import { join } from "path";

export interface VmConfig {
  ip: string;
  wg_ip?: string;
  user: string;
  description?: string;
  ssh_alias?: string;
}

export interface ServiceConfig {
  category: string;
  vm: string;
  containers?: string[];
  domain?: string;
  description?: string;
  flake?: string;
  folder?: string;
}

export interface InfraConfig {
  vms: Record<string, VmConfig>;
  services: Record<string, ServiceConfig>;
}

// Hardcoded fallback — used when _cloud-data-consolidated.json VMs lack ssh_alias
// 2026-04-27 migrated: cloud-data-topology.json -> _cloud-data-consolidated.json (top-level — superset)
const VM_SSH_ALIASES_FALLBACK: Record<string, string> = {
  "gcp-E2-f_0": "gcp-proxy",
  "oci-E2-f_0": "oci-mail",
  "oci-E2-f_1": "oci-analytics",
  "oci-A1-f_0": "oci-apps",
};

let _config: InfraConfig | null = null;
let _configTimestamp = 0;
const CONFIG_TTL = 5 * 60 * 1000; // 5 minutes

function getConfigPath(): string {
  const p = process.env.CONFIG_PATH;
  if (!p) throw new Error("CONFIG_PATH env var not set — point it at ~/git/cloud/config.json");
  return p;
}

export function getRepoRoot(): string {
  const configPath = getConfigPath();
  // config.json is at repo root
  return join(configPath, "..");
}

/**
 * Resolve a cloud-data / build / consolidated file. Priority:
 *   1. /app/<filename>                             — bundled in-image (build pipeline copies dist/* into the image)
 *   2. <repoRoot>/2_configs/dist/<filename>        — dev: cloud repo dist/
 *   3. <repoRoot>/cloud-data/<filename>            — legacy c3_git_repos clone
 *   4. <repoRoot>/<filename>                       — legacy cloud repo root
 *
 * 2026-04-27: replaces the previous `getRepoRoot() + "cloud-data" + filename`
 * pattern which assumed a sibling cloud-data clone existed under the repo root.
 * The new pattern lets each container read its bundled-in-image copy.
 */
export function getCloudDataPath(filename: string): string {
  const repoRoot = (() => { try { return getRepoRoot(); } catch { return ""; } })();
  const candidates = [
    `/app/${filename}`,
    repoRoot ? join(repoRoot, "2_configs", "dist", filename) : "",
    repoRoot ? join(repoRoot, "cloud-data", filename) : "",
    repoRoot ? join(repoRoot, filename) : "",
  ].filter(Boolean) as string[];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  return candidates[0] ?? `/app/${filename}`;
}

export function getConfig(): InfraConfig {
  const now = Date.now();
  if (!_config || now - _configTimestamp > CONFIG_TTL) {
    _config = JSON.parse(readFileSync(getConfigPath(), "utf-8")) as InfraConfig;
    _configTimestamp = now;
  }
  return _config;
}

export function getVmSshAlias(vmId: string): string {
  const config = getConfig();
  const vm = config.vms[vmId];
  if (vm?.ssh_alias) return vm.ssh_alias;
  return VM_SSH_ALIASES_FALLBACK[vmId] ?? vmId;
}
