// gen-home-manager.ts — Generate cloud-data-home-manager.json
// Aggregates ALL data needed by home-manager modules from config.json
// Run: cd src/ && CONFIG_JSON_PATH=... GIT_BASE=... tsx gen-home-manager.ts
import { getConfig } from './shared/config.js';

const config = getConfig();

// ── VMs ──────────────────────────────────────────────────────────────
const vms: Record<string, any> = {};
for (const [vmId, vm] of Object.entries(config.vms)) {
  const v = vm as any;
  if (!v.ssh_alias) continue;

  vms[v.ssh_alias] = {
    vm_id: vmId,
    ip: v.ip,
    wg_ip: v.wg_ip,
    wg_public_key: v.wg_public_key ?? null,
    wg_port: v.wg_port ?? 51820,
    wg_role: v.wg_role ?? "spoke",
    user: v.user,
    home: v.home ?? (v.user === "root" ? "/root" : `/home/${v.user}`),
    rescue_port: v.rescue_port ?? 2200,
    specs: v.specs ?? {},
    public_ports: v.public_ports ?? [],
    idle_shutdown: v.idle_shutdown ?? null,
    containers: v.containers ?? [],
    method: v.method,
    gha: v.gha ?? null,
  };
}

// ── Owner ────────────────────────────────────────────────────────────
const rawConfig = config as any;
const owner = rawConfig.owner ?? {
  name: "Diego Marcos",
  email: "diegonmarcos@gmail.com",
  domain: "diegonmarcos.com",
  github: "diegonmarcos",
};

// ── Home Manager ─────────────────────────────────────────────────────
const homeManager = rawConfig.home_manager ?? { state_version: "24.11" };

// ── WireGuard ────────────────────────────────────────────────────────
const native = rawConfig.native ?? {};
const wgConfig = native.wireguard ?? {};
const wireguard = {
  subnet: wgConfig.subnet ?? "10.0.0.0/24",
  port: wgConfig.port ?? 51820,
  hub: wgConfig.wg_hub ?? null,
  peers: Object.entries(vms)
    .filter(([_, v]: any) => v.wg_ip && v.wg_public_key)
    .map(([alias, v]: any) => ({
      name: alias,
      wg_ip: v.wg_ip,
      public_ip: v.ip,
      wg_public_key: v.wg_public_key,
      wg_port: v.wg_port,
      role: v.wg_role,
      endpoint: v.ip,
    })),
  clients: wgConfig.clients ?? {},
};

// ── DNS ──────────────────────────────────────────────────────────────
const dns = native.dns ?? { primary: "10.0.0.1", fallback: "1.1.1.1" };

// ── Docker ───────────────────────────────────────────────────────────
const docker = native.docker ?? { subnet: "172.16.0.0/12", iptables: false };

// ── Monitoring ───────────────────────────────────────────────────────
const monitoring = native.monitoring ?? { ntfy_base: "https://rss.diegonmarcos.com" };

// ── SSH Config (generated for ~/.ssh/config) ─────────────────────────
const sshEntries = Object.entries(vms).map(([alias, v]: any) => ({
  host: alias,
  hostname: v.wg_ip ?? v.ip,
  user: v.user,
  identity_file: v.method === "gcloud" ? "~/.ssh/google_compute_engine" : "~/.ssh/vault_id_rsa",
  port: 22,
}));

// ── Output ───────────────────────────────────────────────────────────
const result = {
  _generated: new Date().toISOString(),
  _source: "config.json via gen-home-manager.ts",
  owner,
  home_manager: homeManager,
  vms,
  wireguard,
  dns,
  docker,
  monitoring,
  ssh_config: sshEntries,
};

console.log(JSON.stringify(result, null, 2));
