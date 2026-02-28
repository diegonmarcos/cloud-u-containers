import { readFileSync, existsSync } from "fs";
import { join } from "path";
import {
  getConfig,
  getServiceFolder,
  getServiceDir,
  getVmSshAlias,
  getServicesForVm,
  resolveVmId,
  getDriftReport,
} from "./config.js";
import { SOLUTIONS_DIR, REPOS } from "./paths.js";
import { listServices } from "./discovery.js";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface TopologyVm {
  id: string;
  alias: string;
  ip: string;
  method: string;
  services: string[];
}

export interface TopologyService {
  name: string;
  category: string;
  vm: string;
  vmAlias: string;
  domain?: string;
  description?: string;
  discovered: boolean;
  hasDistFolder: boolean;
  hasComposeFile: boolean;
}

export interface Topology {
  vms: TopologyVm[];
  services: TopologyService[];
  summary: {
    vmCount: number;
    serviceCount: number;
    discoveredCount: number;
    domainsCount: number;
  };
}

export interface TopologyDrift {
  onDiskOnly: string[];
  configOnly: string[];
  summary: string;
}

export interface SecurityTopology {
  exposedServices: { name: string; domain: string; vm: string }[];
  secretsStatus: { service: string; hasSecrets: boolean; hasSecretsFile: boolean }[];
  vms: { id: string; alias: string; ip: string; method: string }[];
  summary: string;
}

// ---------------------------------------------------------------------------
// Helpers — lightweight docker-compose.yml parsing (no YAML library)
// ---------------------------------------------------------------------------

/**
 * Parse container names from a docker-compose.yml file using line scanning.
 * Looks for `container_name:` values or service-level keys under `services:`.
 */
function parseComposeContainers(composePath: string): string[] {
  let content: string;
  try {
    content = readFileSync(composePath, "utf-8");
  } catch {
    return [];
  }

  const containers: string[] = [];
  const lines = content.split("\n");

  for (const line of lines) {
    const match = line.match(/^\s+container_name:\s*["']?([^"'\s#]+)["']?/);
    if (match) {
      containers.push(match[1]);
    }
  }

  return containers;
}

/**
 * Parse exposed ports from a docker-compose.yml file.
 * Looks for lines like `- "8080:80"` or `- 3000:3000` under `ports:`.
 */
function parseComposePorts(composePath: string): string[] {
  let content: string;
  try {
    content = readFileSync(composePath, "utf-8");
  } catch {
    return [];
  }

  const ports: string[] = [];
  const lines = content.split("\n");
  let inPorts = false;

  for (const line of lines) {
    const trimmed = line.trimStart();

    if (/^ports:\s*$/.test(trimmed) || /^ports:\s*#/.test(trimmed)) {
      inPorts = true;
      continue;
    }

    if (inPorts) {
      const portMatch = trimmed.match(/^-\s*["']?(\d[\d:./\-]+\d)["']?/);
      if (portMatch) {
        ports.push(portMatch[1]);
      } else if (/^\w/.test(trimmed) || trimmed === "") {
        // Left the ports block (new top-level key or blank line after list)
        if (/^\w/.test(trimmed)) inPorts = false;
      }
    }
  }

  return ports;
}

/**
 * Parse network names from a docker-compose.yml file.
 * Looks for top-level `networks:` section and extracts the keys.
 */
function parseComposeNetworks(composePath: string): string[] {
  let content: string;
  try {
    content = readFileSync(composePath, "utf-8");
  } catch {
    return [];
  }

  const networks: string[] = [];
  const lines = content.split("\n");
  let inTopLevelNetworks = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Top-level `networks:` (no leading whitespace)
    if (/^networks:\s*$/.test(line) || /^networks:\s*#/.test(line)) {
      inTopLevelNetworks = true;
      continue;
    }

    if (inTopLevelNetworks) {
      // A line starting with no indent means a new top-level key — stop
      if (/^\S/.test(line) && line.trim() !== "") {
        inTopLevelNetworks = false;
        continue;
      }
      // Network name: exactly 2-space or 1-tab indent, followed by `name:`-style key
      const netMatch = line.match(/^[ \t]{1,4}(\w[\w.-]*):\s*$/);
      if (netMatch) {
        networks.push(netMatch[1]);
      }
    }
  }

  return networks;
}

// ---------------------------------------------------------------------------
// 1. assembleTopology()
// ---------------------------------------------------------------------------

export function assembleTopology(): Topology {
  const config = getConfig();
  const discoveredServices = listServices();

  // Build a domain lookup from discovery module
  const domainMap = new Map<string, string>();
  for (const svc of discoveredServices) {
    if (svc.domain) {
      domainMap.set(svc.name, svc.domain);
    }
  }

  // --- VMs ---
  const vms: TopologyVm[] = [];
  for (const [vmId, vmCfg] of Object.entries(config.vms)) {
    const alias = getVmSshAlias(vmId);
    const vmServices = getServicesForVm(vmId).map(([name]) => name);

    vms.push({
      id: vmId,
      alias,
      ip: vmCfg.ip,
      method: vmCfg.method,
      services: vmServices,
    });
  }

  // --- Services ---
  const services: TopologyService[] = [];

  for (const [name, svc] of Object.entries(config.services)) {
    let vmAlias: string;
    try {
      vmAlias = svc.vm === "local" || svc.vm === "all"
        ? svc.vm
        : getVmSshAlias(svc.vm);
    } catch {
      vmAlias = svc.vm;
    }

    // Check dist/ folder and compose file
    let hasDistFolder = false;
    let hasComposeFile = false;
    try {
      const serviceDir = getServiceDir(name);
      const distDir = join(serviceDir, "dist");
      hasDistFolder = existsSync(distDir);
      hasComposeFile =
        existsSync(join(distDir, "docker-compose.yml")) ||
        existsSync(join(distDir, "docker-compose.yaml")) ||
        existsSync(join(distDir, "compose.yml")) ||
        existsSync(join(distDir, "compose.yaml"));
    } catch {
      // Service folder may not exist for config-only entries
    }

    services.push({
      name,
      category: svc.category,
      vm: svc.vm,
      vmAlias,
      domain: domainMap.get(name),
      description: svc.description,
      discovered: svc.discovered === true,
      hasDistFolder,
      hasComposeFile,
    });
  }

  // --- Summary ---
  const discoveredCount = services.filter((s) => s.discovered).length;
  const domainsCount = services.filter((s) => s.domain).length;

  return {
    vms,
    services,
    summary: {
      vmCount: vms.length,
      serviceCount: services.length,
      discoveredCount,
      domainsCount,
    },
  };
}

// ---------------------------------------------------------------------------
// 2. getTopologyDrift()
// ---------------------------------------------------------------------------

export function getTopologyDrift(): TopologyDrift {
  const drift = getDriftReport();

  const parts: string[] = [];
  if (drift.onDiskOnly.length > 0) {
    parts.push(
      `${drift.onDiskOnly.length} service(s) found on disk but missing from config.json: ${drift.onDiskOnly.join(", ")}`
    );
  }
  if (drift.configOnly.length > 0) {
    parts.push(
      `${drift.configOnly.length} service(s) in config.json but folder missing on disk: ${drift.configOnly.join(", ")}`
    );
  }
  if (parts.length === 0) {
    parts.push("No drift detected — config.json and on-disk services are in sync.");
  }

  return {
    onDiskOnly: drift.onDiskOnly,
    configOnly: drift.configOnly,
    summary: parts.join(" | "),
  };
}

// ---------------------------------------------------------------------------
// 3. getSecurityTopology()
// ---------------------------------------------------------------------------

export function getSecurityTopology(): SecurityTopology {
  const config = getConfig();
  const discoveredServices = listServices();

  // Domain lookup
  const domainMap = new Map<string, string>();
  for (const svc of discoveredServices) {
    if (svc.domain) {
      domainMap.set(svc.name, svc.domain);
    }
  }

  // --- Exposed services (those with public domains) ---
  const exposedServices: SecurityTopology["exposedServices"] = [];
  for (const [name, svc] of Object.entries(config.services)) {
    const domain = domainMap.get(name);
    if (domain) {
      exposedServices.push({ name, domain, vm: svc.vm });
    }
  }

  // --- Secrets status per service ---
  const secretsStatus: SecurityTopology["secretsStatus"] = [];
  for (const [name, svc] of Object.entries(config.services)) {
    let hasSecrets = false;
    let hasSecretsFile = false;

    try {
      const serviceDir = getServiceDir(name);
      // Source secrets (sops-encrypted)
      hasSecrets = existsSync(join(serviceDir, "src", "secrets.yaml"));
      // Decrypted secrets in dist
      hasSecretsFile =
        existsSync(join(serviceDir, "dist", ".secrets")) ||
        existsSync(join(serviceDir, "dist", ".env"));
    } catch {
      // Service folder may not exist
    }

    secretsStatus.push({ service: name, hasSecrets, hasSecretsFile });
  }

  // --- VMs ---
  const vmsList: SecurityTopology["vms"] = [];
  for (const [vmId, vmCfg] of Object.entries(config.vms)) {
    vmsList.push({
      id: vmId,
      alias: getVmSshAlias(vmId),
      ip: vmCfg.ip,
      method: vmCfg.method,
    });
  }

  // --- Summary ---
  const withSecrets = secretsStatus.filter((s) => s.hasSecrets).length;
  const withDecrypted = secretsStatus.filter((s) => s.hasSecretsFile).length;
  const summaryParts = [
    `${exposedServices.length} publicly exposed service(s)`,
    `${withSecrets} service(s) with encrypted secrets`,
    `${withDecrypted} service(s) with decrypted secrets in dist/`,
    `${vmsList.length} VM(s)`,
  ];

  return {
    exposedServices,
    secretsStatus,
    vms: vmsList,
    summary: summaryParts.join(" | "),
  };
}
